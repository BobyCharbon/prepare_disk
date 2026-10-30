import AppKit
import Foundation

/// Point d'entrée : l'app normale, ou l'agent invisible lancé par macOS (« --agent ») quand l'app est fermée.
@main
enum Launcher {
    static func main() {
        if CommandLine.arguments.contains("--agent") {
            NSApplication.shared.setActivationPolicy(.prohibited)   // ni fenêtre ni icône dans le Dock
            Task { @MainActor in
                await Agent.run()
                exit(0)
            }
            dispatchMain()
        } else {
            PrepareDiskApp.main()
        }
    }
}

/// Un passage de l'agent : mise à jour de l'app, versions validées, téléchargements, rangement. Puis il s'arrête
/// (macOS le relance 15 minutes plus tard).
@MainActor
enum Agent {
    static let label = "com.bobycharbon.preparedisk.agent"
    static let plist = label + ".plist"
    private static let lock = URL(fileURLWithPath: NSHomeDirectory() + "/Library/Application Support/PrepareDisk/agent.pid")

    /// L'agent est en train de travailler (l'app ouverte lui laisse alors les téléchargements).
    static var isRunning: Bool {
        guard let text = try? String(contentsOf: lock, encoding: .utf8), let pid = Int32(text) else { return false }
        return pid != getpid() && kill(pid, 0) == 0
    }

    static func run() async {
        // L'app est ouverte : c'est elle qui s'en occupe.
        let me = getpid()
        if NSRunningApplication.runningApplications(withBundleIdentifier: Bundle.main.bundleIdentifier ?? "")
            .contains(where: { $0.processIdentifier != me && $0.activationPolicy == .regular }) { return }
        try? FileManager.default.createDirectory(at: lock.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? String(me).write(to: lock, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: lock) }

        Shell.interactive = false   // personne pour taper un mot de passe : l'assistant système ou rien
        let model = AppModel()
        guard model.settings.autoDownload else { return }
        model.log.add("==> Agent : vérification en arrière-plan")

        // 1. L'app elle-même (remplacée sans être relancée : la prochaine ouverture sera la nouvelle version).
        await model.updater.check(silently: true)
        if model.updater.state == .available { await model.updater.install(relaunch: false) }

        // 2. Versions validées, catalogue Apple, fichiers présents.
        await model.helper.check()
        await model.syncValidated(notify: true)
        await model.catalog.loadInstallers()
        await model.refreshFirmwares()
        await model.library.scan()

        // 3. Tout ce qui manque, en attendant la fin (les échecs sont retentés au passage suivant).
        model.autoDownloadTick()
        _ = await model.downloads.wait(for: model.downloads.jobs)
        await model.library.scan()
        await model.removeOldVersions()
        model.log.add("Agent : terminé")
    }
}
