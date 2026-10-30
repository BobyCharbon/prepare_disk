import AppKit
import Foundation
import Observation

/// Relie tous les modules de l'app.
@MainActor
@Observable
final class AppModel {
    var settings: AppSettings
    let catalog = Catalog()
    let log = LogStore()
    let history = HistoryStore()
    let library: Library
    let notifier: Notifier
    let downloads: DownloadManager
    let disks: DiskStore
    let preparer: Preparer
    let updater = Updater()

    /// Disques cochés dans l'assistant.
    var selectedDisks: Set<String> = []
    /// Nouvelles versions trouvées par rapport à la sélection.
    var updateNotices: [String] = []
    var page: Page = .prepare
    /// Étape en cours de l'assistant « Préparer un disque ».
    var wizardStep = 0
    /// Sans « Accès complet au disque », createinstallmedia échoue (« The bless of the installer disk failed »).
    var hasFullDiskAccess = AppModel.checkFullDiskAccess()

    init() {
        let settings = AppSettings()
        self.settings = settings
        library = Library(settings: settings)
        library.catalog = catalog
        notifier = Notifier(settings: settings)
        downloads = DownloadManager(settings: settings, library: library, notifier: notifier)
        disks = DiskStore(settings: settings, catalog: catalog, library: library)
        preparer = Preparer(settings: settings, catalog: catalog, library: library, downloads: downloads,
                            disks: disks, history: history, log: log, notifier: notifier)
        downloads.onFinished = { [weak self] in await self?.removeOldVersions() }
    }

    func start() async {
        // Au lancement rien n'est en cours : on peut installer une mise à jour tout de suite.
        if settings.autoUpdate {
            await updater.check(silently: true)
            if updater.state == .available { await updater.install() }
        }
        notifier.requestAuthorization()
        watchDisks()
        async let scan: Void = library.scan()
        async let list: Void = disks.load()
        async let firmwares: Void = refreshFirmwares()
        await catalog.loadInstallers()
        if settings.selected.allSatisfy(\.isEmpty) {
            let picks = catalog.latestMajors(3).map(\.version)
            settings.selected = Array((picks + ["", "", ""]).prefix(3))
        }
        _ = await (scan, list, firmwares)
        await library.scan()   // reconnaît les IPSW au nom d'Apple, maintenant que la liste est chargée
        if settings.checkUpdatesAtLaunch { checkForUpdates(notify: true) }
    }

    func refreshAll() async {
        async let a: Void = catalog.loadInstallers()
        async let b: Void = refreshFirmwares()
        async let c: Void = library.scan()
        async let d: Void = disks.load()
        _ = await (a, b, c, d)
        checkForUpdates(notify: false)
    }

    func refreshFirmwares() async {
        await catalog.loadFirmwares(for: settings.devices.map(\.identifier) + [settings.macIdentifier])
    }

    // MARK: Nouvelles versions

    func checkForUpdates(notify: Bool) {
        var notices: [String] = []
        for version in settings.selected where !version.isEmpty {
            if let latest = catalog.latestInstaller(major: version.majorVersion), latest.version.isNewerVersion(than: version) {
                notices.append("macOS \(latest.name) \(latest.version) est disponible (vous avez choisi \(version)).")
            }
        }
        for device in settings.enabledDevices {
            guard let latest = catalog.latestSigned(identifier: device.identifier) else { continue }
            let local = library.latestIPadIPSW(device)?.version
            if let local, latest.version.isNewerVersion(than: local) {
                notices.append("\(device.name) : iPadOS \(latest.version) est disponible (local : \(local)).")
            }
        }
        if notify, !notices.isEmpty, notices != updateNotices {
            notifier.notify("Nouvelles versions disponibles", notices.joined(separator: "\n"))
        }
        updateNotices = notices
    }

    /// Remplace chaque version choisie par la plus récente du même macOS.
    func useLatestVersions() {
        settings.selected = settings.selected.map { version in
            version.isEmpty ? "" : (catalog.latestInstaller(major: version.majorVersion)?.version ?? version)
        }
        checkForUpdates(notify: false)
    }

    // MARK: Anciennes versions

    /// Fichiers de ~/prepare_disk remplacés par une version validée déjà sur ce Mac.
    /// Une catégorie n'est nettoyée que si toutes ses versions validées sont présentes : on ne supprime jamais
    /// la seule version disponible.
    func obsoleteFiles() -> [String] {
        var old: [String] = []
        // macOS : installateurs du dossier Intel qui ne sont plus choisis.
        let chosen = settings.selected.filter { !$0.isEmpty }
        let intel = library.installers.filter { $0.path.hasPrefix(settings.intelFolder + "/") }
        if !chosen.isEmpty, chosen.allSatisfy({ v in intel.contains { $0.version == v } }) {
            old += intel.filter { !chosen.contains($0.version ?? "") }.map(\.path)
        }
        // IPSW Mac : ceux du dossier Silicon qui ne correspondent à aucun macOS coché.
        if settings.includeMacIPSW {
            let wanted = settings.selected.indices.compactMap { slot -> String? in
                guard !settings.selected[slot].isEmpty, settings.macIPSWSlots[slot] else { return nil }
                return catalog.macFirmware(identifier: settings.macIdentifier, version: settings.selected[slot],
                                           pinned: settings.macIPSWVersions[slot])?.version
            }
            let silicon = library.macIPSWs.filter { $0.path.hasPrefix(settings.siliconFolder + "/") }
            if !wanted.isEmpty, wanted.allSatisfy({ v in silicon.contains { $0.version == v } }) {
                old += silicon.filter { !wanted.contains($0.version ?? "") }.map(\.path)
            }
        }
        // IPSW iPad : dans le dossier de chaque iPad coché, tout sauf la version validée.
        if settings.includeIPadIPSW {
            for device in settings.enabledDevices {
                guard let version = catalog.iPadFirmware(device)?.version else { continue }
                let files = (library.iPadIPSWs[device.name] ?? []).filter { $0.path.hasPrefix(settings.folder(for: device) + "/") }
                if files.contains(where: { $0.version == version }) {
                    old += files.filter { $0.version != version }.map(\.path)
                }
            }
        }
        return old
    }

    /// Met les anciennes versions à la corbeille (récupérables), si le réglage est activé.
    func removeOldVersions() async {
        guard settings.removeOldVersions, !preparer.isRunning else { return }
        let old = obsoleteFiles()
        guard !old.isEmpty else { return }
        let names = old.map { ($0 as NSString).lastPathComponent }
        await library.trash(old)
        log.add("Anciennes versions mises à la corbeille : " + names.joined(separator: ", "))
        notifier.notify("Anciennes versions supprimées", names.joined(separator: "\n"))
    }

    // MARK: Accès complet au disque

    /// Le fichier TCC.db n'est lisible qu'avec l'accès complet au disque.
    static func checkFullDiskAccess() -> Bool {
        FileHandle(forReadingAtPath: NSHomeDirectory() + "/Library/Application Support/com.apple.TCC/TCC.db") != nil
    }

    func openFullDiskAccessSettings() {
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles")!)
    }

    // MARK: Disques

    /// Actualise la liste dès qu'un disque est branché ou éjecté.
    private func watchDisks() {
        let center = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.didMountNotification, NSWorkspace.didUnmountNotification] {
            center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor in
                    guard let self, !self.preparer.isRunning else { return }
                    await self.disks.load()
                    self.selectedDisks = self.selectedDisks.filter { id in self.disks.disks.contains { $0.id == id } }
                }
            }
        }
        // Au retour des Réglages Système, on revérifie l'autorisation.
        NotificationCenter.default.addObserver(forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.hasFullDiskAccess = AppModel.checkFullDiskAccess() }
        }
    }
}

enum Page: String, CaseIterable, Identifiable {
    case prepare, versions, library, ipsw, disks, downloads, history, log
    var id: String { rawValue }

    var title: String {
        switch self {
        case .prepare: return "Préparer un disque"
        case .versions: return "Versions validées"
        case .library: return "Installateurs macOS"
        case .ipsw: return "IPSW et loops"
        case .disks: return "Disques"
        case .downloads: return "Téléchargements"
        case .history: return "Historique"
        case .log: return "Journal"
        }
    }

    var icon: String {
        switch self {
        case .prepare: return "externaldrive.badge.plus"
        case .versions: return "checkmark.seal"
        case .library: return "shippingbox"
        case .ipsw: return "ipad.and.iphone"
        case .disks: return "externaldrive"
        case .downloads: return "arrow.down.circle"
        case .history: return "clock.arrow.circlepath"
        case .log: return "text.alignleft"
        }
    }
}
