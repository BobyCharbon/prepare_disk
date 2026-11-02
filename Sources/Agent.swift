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
        // Une seule fenêtre Prepare Disk : un deuxième lancement ramène celle déjà ouverte.
        // L'agent se note par son numéro de processus : vu d'ailleurs, il passe pour une app normale.
        let agentPid = NSHomeDirectory() + "/Library/Application Support/PrepareDisk/agent-process.pid"
        if agent {
            try? FileManager.default.createDirectory(atPath: (agentPid as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
            try? String(getpid()).write(toFile: agentPid, atomically: true, encoding: .utf8)
        } else {
            let agentProcess = (try? String(contentsOfFile: agentPid, encoding: .utf8)).flatMap { Int32($0) }
            if let other = NSRunningApplication.runningApplications(withBundleIdentifier: Bundle.main.bundleIdentifier ?? "")
                .first(where: { $0.processIdentifier != getpid() && $0.processIdentifier != agentProcess && $0.activationPolicy == .regular }) {
                other.activate()
                exit(0)
            }
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
        NSRunningApplication.runningApplications(withBundleIdentifier: Bundle.main.bundleIdentifier ?? "")
            .contains { $0.processIdentifier != getpid() && $0.activationPolicy == .regular }
    }

    static func openApp() {
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.createsNewApplicationInstance = !appIsOpen   // l'agent est déjà une « instance » de l'app
        NSWorkspace.shared.openApplication(at: Bundle.main.bundleURL, configuration: configuration)
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
    private let loadedVersion = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String

    init() {
        Shell.interactive = false   // jamais de fenêtre de mot de passe : l'assistant système ou rien
        model = AppModel()
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
            Label(model.settings.autoDownload ? "Téléchargement automatique activé" : "Téléchargement automatique désactivé",
                  systemImage: model.settings.autoDownload ? "arrow.triangle.2.circlepath" : "pause.circle")
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
