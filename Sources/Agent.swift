import AppKit
import SwiftUI

/// Point d'entrée : l'app normale, ou l'agent (« --agent ») lancé par macOS à l'ouverture de session.
@main
enum Launcher {
    static func main() {
        let agent = CommandLine.arguments.contains("--agent")
        // Ancienne copie (ex. /Applications sans droit d'écriture) : on passe la main à la version à jour
        // dans ~/Applications. Pour l'agent, l'app s'ouvre cachée et réinstalle l'agent depuis la nouvelle copie.
        if let newer = Updater.newerUserCopy {
            let open = Process()
            open.executableURL = URL(fileURLWithPath: "/usr/bin/open")
            open.arguments = (agent ? ["-g", "-j"] : []) + [newer]
            try? open.run()
            open.waitUntilExit()
            exit(0)
        }
        // L'agent a sa propre petite app (Contents/Library/LoginItems), avec sa propre identité : sinon macOS
        // le confond avec l'app (clic sur l'app envoyé à l'agent, « Quitter » qui arrête l'agent, icône cachée).
        // macOS lance toujours le programme de l'app avec « --agent » : on passe la main à celui de l'agent.
        if agent && !Agent.isAgent {
            let inner = Bundle.main.bundlePath + "/" + Agent.innerPath + "/Contents/MacOS/PrepareDisk"
            // Pendant une mise à jour, l'app peut être encore en cours de copie : on lui laisse quelques secondes.
            for _ in 0..<10 where !FileManager.default.isExecutableFile(atPath: inner) { sleep(1) }
            if FileManager.default.isExecutableFile(atPath: inner) {
                let args = [inner] + CommandLine.arguments.dropFirst()
                var cArgs = args.map { strdup($0) } + [nil]
                execv(inner, &cArgs)   // ne revient qu'en cas d'échec : l'agent tourne alors comme avant
            }
        }
        // Une seule fenêtre Prepare Disk : un deuxième lancement ramène celle déjà ouverte.
        if !agent, let other = NSRunningApplication.runningApplications(withBundleIdentifier: Agent.appID)
            .first(where: { $0.processIdentifier != getpid() && $0.activationPolicy == .regular }) {
            other.activate()
            exit(0)
        }
        if agent {
            AgentApp.main()   // LSUIElement : jamais dans le Dock
        } else {
            // L'app est déclarée LSUIElement (pour que l'agent n'apparaisse pas dans le Dock) : la fenêtre
            // principale, elle, s'y affiche.
            NSApplication.shared.setActivationPolicy(.regular)
            PrepareDiskApp.main()
        }
    }
}

/// L'agent : une icône dans la barre des menus, toujours là (même app fermée), qui montre si les versions validées
/// sont sur ce Mac et les télécharge toutes seules si le téléchargement automatique est activé.
struct AgentApp: App {
    @NSApplicationDelegateAdaptor private var delegate: AgentDelegate
    @State private var agent = AgentModel()

    var body: some Scene {
        MenuBarExtra {
            AgentPanel(agent: agent)
        } label: {
            Image(systemName: agent.symbol).font(.system(size: 15, weight: .semibold))
        }
        .menuBarExtraStyle(.window)
    }
}

final class AgentDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)   // pas d'icône dans le Dock
    }

    /// Double-clic sur l'app pendant que l'agent tourne : macOS s'adresse à l'agent, qui ouvre la vraie fenêtre.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        Agent.openApp()
        return false
    }
}

@MainActor
enum Agent {
    static let plist = "com.bobycharbon.preparedisk.agent.plist"
    nonisolated static let appID = "com.bobycharbon.preparedisk"
    nonisolated static let innerPath = "Contents/Library/LoginItems/Prepare Disk Agent.app"
    /// Ce processus est l'agent, dans sa propre app.
    nonisolated static var isAgent: Bool { Bundle.main.bundleIdentifier == appID + ".agent" }
    /// L'app Prepare Disk (pour l'agent : celle qui le contient).
    nonisolated static let appBundle: Bundle = isAgent
        ? Bundle(url: Bundle.main.bundleURL.deletingLastPathComponent().deletingLastPathComponent()
                    .deletingLastPathComponent().deletingLastPathComponent()) ?? .main
        : .main
    private static let lock = URL(fileURLWithPath: NSHomeDirectory() + "/Library/Application Support/PrepareDisk/agent.pid")

    /// L'agent est en train de télécharger : l'app ouverte lui laisse alors les téléchargements.
    static var isDownloading: Bool {
        guard let text = try? String(contentsOf: lock, encoding: .utf8), let pid = Int32(text) else { return false }
        return pid != getpid() && kill(pid, 0) == 0
    }

    static func setDownloading(_ on: Bool) {
        if on {
            try? FileManager.default.createDirectory(at: lock.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? String(getpid()).write(to: lock, atomically: true, encoding: .utf8)
        } else {
            try? FileManager.default.removeItem(at: lock)
        }
    }

    /// La fenêtre de Prepare Disk est ouverte (un autre processus du même programme, avec une icône dans le Dock).
    static var appIsOpen: Bool {
        NSRunningApplication.runningApplications(withBundleIdentifier: appID)
            .contains { $0.processIdentifier != getpid() && $0.activationPolicy == .regular }
    }

    static func openApp() {
        NSWorkspace.shared.openApplication(at: appBundle.bundleURL, configuration: NSWorkspace.OpenConfiguration())
    }
}

/// Le travail de l'agent : relit les fichiers toutes les 15 secondes, les versions validées toutes les 5 minutes,
/// suit en direct les téléchargements de l'app, et télécharge lui-même quand l'app est fermée (si c'est activé).
@MainActor
@Observable
final class AgentModel {
    let model: AppModel
    var items: [AppModel.Needed] = []
    /// Téléchargements de l'app ouverte, relus toutes les 2 secondes.
    var external: [SharedDownload] = []
    var lastCheck: Date?
    /// Fin de la pause du téléchargement automatique (nil : pas en pause).
    var pausedUntil = AppSettings.autoDownloadPausedUntil
    private let loadedVersion = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String

    init() {
        Shell.interactive = false   // jamais de fenêtre de mot de passe : l'assistant système ou rien
        model = AppModel()
        model.notifier.requestAuthorization()   // l'agent a sa propre autorisation (demandée une fois)
        Task { await loop() }
        Task { await follow() }
    }

    /// Tous les téléchargements en cours : ceux de l'agent et ceux de l'app.
    var downloading: [SharedDownload] {
        model.downloads.active.map { SharedDownload(key: $0.key, title: $0.title, progress: $0.progress, verifying: $0.state == .verifying) }
            + external
    }
    var missing: Int { items.filter { $0.state != .ok }.count }
    /// Grand symbole plein, lisible d'un coup d'œil dans la barre des menus.
    var symbol: String {
        if !downloading.isEmpty { return "arrow.down.circle.fill" }
        if items.isEmpty { return "externaldrive" }
        return missing == 0 ? "checkmark.circle.fill" : "exclamationmark.circle.fill"
    }
    var symbolColor: Color {
        if !downloading.isEmpty { return .blue }
        if items.isEmpty { return .secondary }
        return missing == 0 ? .green : .orange
    }

    /// Suit les téléchargements de l'app ; quand l'un se termine, la liste est relue tout de suite.
    private func follow() async {
        while true {
            let now = SharedDownloads.others()
            let finished = Set(external.map(\.key)).subtracting(now.map(\.key))
            external = now
            if !finished.isEmpty { await check(download: false) }
            // Fin de la pause (au bout d'une heure) : le bouton repasse sur « pause » et les téléchargements reprennent.
            let paused = AppSettings.autoDownloadPausedUntil
            if pausedUntil != nil && paused == nil {
                pausedUntil = nil
                model.downloads.resumeAfterPause()
                await check(download: !Agent.appIsOpen)
            }
            pausedUntil = paused
            try? await Task.sleep(for: .seconds(2))
        }
    }

    private func loop() async {
        var lastValidated = Date.distantPast, lastApple = Date.distantPast, lastUpdate = Date.distantPast
        await model.helper.check()
        while true {
            // L'app a été mise à jour sur le disque : on redémarre (macOS relance l'agent avec la nouvelle version).
            let info = NSDictionary(contentsOfFile: Bundle.main.bundlePath + "/Contents/Info.plist")
            if let onDisk = info?["CFBundleShortVersionString"] as? String, onDisk != loadedVersion { exit(0) }
            // L'app a été déplacée ou remplacée pendant une mise à jour : on redémarre depuis sa nouvelle place.
            if !FileManager.default.fileExists(atPath: Bundle.main.bundlePath) { exit(0) }

            model.settings.reload()
            let appOpen = Agent.appIsOpen
            if !appOpen && model.downloads.active.isEmpty && Date().timeIntervalSince(lastUpdate) > 3600 {
                lastUpdate = Date()
                await model.updater.check(silently: true)
                if model.updater.state == .available { await model.updater.install(relaunch: false); exit(0) }
            }
            if Date().timeIntervalSince(lastValidated) > 5 * 60 {
                lastValidated = Date()
                await model.syncValidated(notify: !appOpen)
            }
            if Date().timeIntervalSince(lastApple) > 3 * 3600 {
                lastApple = Date()
                await model.catalog.loadInstallers()
                await model.refreshFirmwares()
            }
            await check(download: !appOpen)
            try? await Task.sleep(for: .seconds(15))
        }
    }

    /// Relit les fichiers et, si permis, lance les téléchargements manquants.
    func check(download: Bool) async {
        model.refreshFreeSpace()
        await model.library.scan()
        items = model.validatedChecklist()
        lastCheck = Date()
        if download { model.autoDownloadTick() }
        Agent.setDownloading(!model.downloads.active.isEmpty)
    }

    /// Pause d'une heure des téléchargements (automatiques ou non), ou reprise.
    func togglePause() {
        if pausedUntil != nil {
            AppSettings.autoDownloadPausedUntil = nil
            pausedUntil = nil
            model.downloads.resumeAfterPause()
            Task { await check(download: !Agent.appIsOpen) }
        } else {
            let until = Date().addingTimeInterval(AppSettings.pauseDuration)
            AppSettings.autoDownloadPausedUntil = until
            pausedUntil = until
            model.downloads.stopForPause()   // l'app ouverte arrête les siens d'elle-même dans la seconde
            Agent.setDownloading(!model.downloads.active.isEmpty)
        }
    }

    func downloadAll() {
        for kind in items.compactMap(\.download) { model.downloads.enqueue(kind) }
        Agent.setDownloading(true)
    }
}

/// Le panneau qui s'ouvre en cliquant sur l'icône.
struct AgentPanel: View {
    @Bindable var agent: AgentModel

    var body: some View {
        let model = agent.model
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                Image(systemName: agent.symbol).font(.system(size: 34)).foregroundStyle(agent.symbolColor)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Prepare Disk").font(.headline)
                    Text(summary).font(.caption).foregroundStyle(.secondary)
                }
            }
            Divider()
            if agent.items.isEmpty {
                Text("Lecture en cours…").foregroundStyle(.secondary)
            }
            ForEach(agent.items) { item in
                HStack {
                    row(item)
                    Text(item.label)
                    Spacer()
                    if let job = job(for: item) {
                        Text(job.verifying ? "vérification" : "\(Int(job.progress * 100)) %")
                            .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                    }
                }
                .font(.callout)
            }
            // Téléchargements qui ne sont pas dans la liste des versions validées.
            ForEach(agent.downloading.filter { d in !agent.items.contains { job(for: $0)?.key == d.key } }) { d in
                HStack {
                    ProgressView(value: d.progress).progressViewStyle(.circular).controlSize(.mini)
                    Text(d.title).lineLimit(1)
                    Spacer()
                    Text("\(Int(d.progress * 100)) %").font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                }
                .font(.callout)
            }
            Divider()
            DiskSpaceLabel(model: model)
            HStack {
                if let until = agent.pausedUntil {
                    Label("Téléchargements en pause jusqu'à \(until.formatted(date: .omitted, time: .shortened))",
                          systemImage: "pause.circle")
                } else if model.settings.autoDownload {
                    Label("Téléchargement automatique activé", systemImage: "arrow.triangle.2.circlepath")
                } else {
                    Label("Téléchargement automatique désactivé", systemImage: "pause.circle")
                }
                Spacer()
                Button { agent.togglePause() } label: {
                    Image(systemName: agent.pausedUntil == nil ? "pause.fill" : "play.fill")
                }
                .help(agent.pausedUntil == nil ? "Mettre les téléchargements en pause pendant 1 heure" : "Reprendre maintenant")
            }
            .font(.caption).foregroundStyle(.secondary)
            if let date = agent.lastCheck {
                Text("Vérifié \(date.formatted(.relative(presentation: .named)))").font(.caption2).foregroundStyle(.tertiary)
            }
            HStack {
                Button("Ouvrir Prepare Disk") { Agent.openApp() }
                Spacer()
                if agent.items.contains(where: { $0.download != nil }) && agent.downloading.isEmpty {
                    Button("Tout télécharger") { agent.downloadAll() }.buttonStyle(.borderedProminent)
                }
            }
        }
        .padding(14)
        .frame(width: 340)
    }

    private func job(for item: AppModel.Needed) -> SharedDownload? {
        guard let kind = item.download else { return nil }
        let key = DownloadJob(kind: kind).key
        return agent.downloading.first { $0.key == key }
    }

    private var summary: String {
        if !agent.downloading.isEmpty { return "\(agent.downloading.count) téléchargement(s) en cours" }
        if agent.items.isEmpty { return "Vérification…" }
        if agent.items.contains(where: { $0.state == .verifying }) { return "Vérification des fichiers…" }
        return agent.missing == 0 ? "Toutes les versions validées sont sur ce Mac et vérifiées"
                                  : "\(agent.missing) version(s) validée(s) à télécharger ou à vérifier"
    }

    @ViewBuilder
    private func row(_ item: AppModel.Needed) -> some View {
        if let job = job(for: item) {
            ProgressView(value: job.progress).progressViewStyle(.circular).controlSize(.mini)
        } else {
            switch item.state {
            case .ok: Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
            case .misplaced: Image(systemName: "tray.and.arrow.down.fill").foregroundStyle(.orange)
            case .missing: Image(systemName: "xmark.circle.fill").foregroundStyle(.red)
            case .verifying: ProgressView().controlSize(.mini)
            case .corrupted: Image(systemName: "exclamationmark.octagon.fill").foregroundStyle(.red)
            }
        }
    }
}
