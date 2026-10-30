import AppKit
import ServiceManagement
import UserNotifications
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
    let validated = ValidatedStore()
    let helper = Helper()

    /// Disques cochés dans l'assistant.
    var selectedDisks: Set<String> = []
    /// Nouvelles versions trouvées par rapport à la sélection.
    var updateNotices: [String] = []
    var page: Page = .versions   // l'app démarre toujours sur Versions validées
    /// Étape en cours de l'assistant « Préparer un disque ».
    var wizardStep = 0
    /// Sans « Accès complet au disque », createinstallmedia échoue (« The bless of the installer disk failed »).
    var hasFullDiskAccess = AppModel.checkFullDiskAccess()

    init() {
        let settings = AppSettings()
        self.settings = settings
        library = Library(settings: settings)
        library.catalog = catalog
        library.helper = helper
        notifier = Notifier(settings: settings)
        downloads = DownloadManager(settings: settings, library: library, notifier: notifier)
        downloads.catalog = catalog
        disks = DiskStore(settings: settings, catalog: catalog, library: library)
        preparer = Preparer(settings: settings, catalog: catalog, library: library, downloads: downloads,
                            disks: disks, history: history, log: log, notifier: notifier)
        downloads.onFinished = { [weak self] in await self?.removeOldVersions() }
        preparer.helper = helper
    }

    func start() async {
        // L'app doit toujours être à jour : au lancement rien n'est en cours, on installe tout de suite.
        await updater.check(silently: true)
        if updater.state == .available { await updater.install() }
        await helper.check()
        await registerAgent()
        await refreshSetup()
        // Puis les versions validées publiées par l'administrateur.
        await syncValidated(notify: false)
        notifier.requestAuthorization()
        watchDisks()
        async let scan: Void = library.scan()
        async let list: Void = disks.load()
        async let firmwares: Void = refreshFirmwares()
        await catalog.loadInstallers()
        if settings.selected.allSatisfy(\.isEmpty) && validated.published == nil {
            let picks = catalog.latestMajors(3).map(\.version)
            settings.selected = Array((picks + ["", "", ""]).prefix(3))
        }
        _ = await (scan, list, firmwares)
        autoRefresh()
        // Téléchargements faits par l'icône de la barre des menus : affichés ici en direct.
        Task { @MainActor [weak self] in
            while let self {
                self.downloads.external = SharedDownloads.others()
                try? await Task.sleep(for: .seconds(2))
            }
        }
        await library.scan()   // reconnaît les IPSW au nom d'Apple, maintenant que la liste est chargée
        if settings.checkUpdatesAtLaunch { checkForUpdates(notify: true) }
        autoDownloadTick()
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
        // Suppression définitive : seulement si chaque remplaçante est certifiée intacte.
        let certified = { (path: String) in self.library.certification(path) == .certified }
        if !chosen.isEmpty, chosen.allSatisfy({ v in intel.contains { $0.version == v && certified($0.path) } }) {
            old += intel.filter { !chosen.contains($0.version ?? "") }.map(\.path)
        }
        // IPSW Mac : ceux du dossier Silicon qui ne correspondent à aucun macOS coché.
        if settings.includeMacIPSW {
            let wanted = settings.selected.indices.compactMap { slot -> Firmware? in
                guard !settings.selected[slot].isEmpty, settings.macIPSWSlots[slot] else { return nil }
                return catalog.macFirmware(identifier: settings.macIdentifier, version: settings.selected[slot],
                                           pinned: settings.macIPSWVersions[slot])
            }
            let silicon = library.macIPSWs.filter { $0.path.hasPrefix(settings.siliconFolder + "/") }
            if !wanted.isEmpty, wanted.allSatisfy({ fw in silicon.contains { $0.matches(fw) && certified($0.path) } }) {
                old += silicon.filter { file in !wanted.contains { file.matches($0) } }.map(\.path)
            }
        }
        // IPSW iPad : dans le dossier de chaque iPad coché, tout sauf la version validée.
        if settings.includeIPadIPSW {
            for device in settings.enabledDevices {
                guard let fw = catalog.iPadFirmware(device) else { continue }
                let files = (library.iPadIPSWs[device.name] ?? []).filter { $0.path.hasPrefix(settings.folder(for: device) + "/") }
                if files.contains(where: { $0.matches(fw) && certified($0.path) }) {
                    old += files.filter { !$0.matches(fw) }.map(\.path)
                }
            }
        }
        return old
    }

    /// Supprime définitivement les anciennes versions remplacées, si le réglage est activé.
    func removeOldVersions() async {
        guard settings.removeOldVersions, !preparer.isRunning else { return }
        let old = obsoleteFiles()
        guard !old.isEmpty else { return }
        let names = old.map { ($0 as NSString).lastPathComponent }
        await library.delete(old)
        log.add("Anciennes versions supprimées : " + names.joined(separator: ", "))
        notifier.notify("Anciennes versions supprimées", names.joined(separator: "\n"))
    }

    // MARK: Réglages Système à faire (bandeau rouge en haut de l'app)

    /// État de l'agent (icône de la barre des menus, téléchargements app fermée).
    var agentStatus: SMAppService.Status = .notRegistered
    var notificationsDenied = false

    /// L'agent est installé d'office : l'icône de la barre des menus doit être là sur chaque Mac.
    /// Si l'app a été déplacée (ou remplacée ailleurs), on le réenregistre, sinon macOS cherche l'ancienne copie.
    func registerAgent() async {
        let agent = SMAppService.agent(plistName: Agent.plist)
        let path = Bundle.main.bundlePath
        if UserDefaults.standard.string(forKey: "agentRegisteredPath") != path {
            try? await agent.unregister()
        }
        if agent.status != .enabled {
            do {
                try agent.register()
                UserDefaults.standard.set(path, forKey: "agentRegisteredPath")
            } catch {
                log.add("ATTENTION : agent de la barre des menus non installé : \(error.localizedDescription)")
            }
        }
        agentStatus = agent.status
    }

    /// Revérifie tout ce que l'utilisateur doit autoriser ; le bandeau disparaît dès que c'est fait.
    func refreshSetup() async {
        hasFullDiskAccess = Self.checkFullDiskAccess()
        agentStatus = SMAppService.agent(plistName: Agent.plist).status
        notificationsDenied = await UNUserNotificationCenter.current().notificationSettings().authorizationStatus == .denied
        if !helper.isReady && !helper.isInstalling { await helper.check() }
    }

    func openLoginItemsSettings() { SMAppService.openSystemSettingsLoginItems() }

    func openNotificationSettings() {
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.Notifications-Settings.extension?id=\(Bundle.main.bundleIdentifier ?? "")")!)
    }

    // MARK: Accès complet au disque

    /// Le fichier TCC.db n'est lisible qu'avec l'accès complet au disque.
    static func checkFullDiskAccess() -> Bool {
        FileHandle(forReadingAtPath: NSHomeDirectory() + "/Library/Application Support/com.apple.TCC/TCC.db") != nil
    }

    func openFullDiskAccessSettings() {
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles")!)
    }

    // MARK: Versions validées

    /// Les versions ne se changent que si on est administrateur (ou si aucune liste n'est encore publiée).
    var canEditVersions: Bool { validated.isAdmin || validated.published == nil }

    /// Les versions réglées ici diffèrent de celles publiées (l'administrateur a des changements à publier).
    var hasUnpublishedVersions: Bool {
        guard let published = validated.published else { return true }
        return !ValidatedVersions(from: settings).sameVersions(as: published)
    }

    /// Relit la liste publiée et l'applique (sauf chez l'administrateur, qui prépare la suivante).
    func syncValidated(notify: Bool) async {
        let changed = await validated.fetch()
        guard !validated.isAdmin, let list = validated.published else { return }
        let before = ValidatedVersions(from: settings)
        validated.apply(to: settings)
        if !before.sameVersions(as: ValidatedVersions(from: settings)) {
            log.add("Nouvelles versions validées appliquées (liste du \(list.updated)).")
            if notify || changed {
                notifier.notify("Nouvelles versions validées",
                                "macOS " + list.macOS.filter { !$0.isEmpty }.joined(separator: ", ") + ". Ouvrez Versions validées pour les télécharger.")
            }
            checkForUpdates(notify: false)
            autoDownloadTick()
        }
    }

    /// Active ou coupe le mode administrateur. En le coupant, ce Mac revient à la liste publiée.
    func setAdminMode(_ on: Bool) {
        validated.adminMode = on
        if !on { Task { await syncValidated(notify: false) } }
    }

    func publishValidated() async -> String? {
        await validated.publish(ValidatedVersions(from: settings))
    }

    // MARK: Bilan des versions validées

    /// Un élément validé et coché : sur ce Mac au bon endroit, sur ce Mac ailleurs, ou à télécharger.
    struct Needed: Identifiable {
        enum State { case ok, misplaced, missing, verifying, corrupted }
        let label: String
        let state: State
        var download: DownloadJob.Kind?
        var id: String { label }
    }

    func validatedChecklist() -> [Needed] {
        // « ok » seulement si le fichier est certifié intact (et bien rangé).
        func inFolder(_ path: String?, _ folder: String) -> Needed.State {
            guard let path else { return .missing }
            switch library.certification(path) {
            case .corrupted: return .corrupted
            case .checking, .unknown: return .verifying
            case .certified: return path.hasPrefix(folder + "/") ? .ok : .misplaced
            }
        }
        var items: [Needed] = []
        for version in settings.selected where !version.isEmpty {
            let state = inFolder(library.installer(for: version, build: catalog.installer(version: version)?.build)?.path, settings.intelFolder)
            items.append(Needed(label: "macOS \(version)", state: state,
                                download: state == .missing || state == .corrupted ? catalog.installer(version: version).map { .macOS($0) } : nil))
        }
        if settings.includeMacIPSW {
            for (slot, version) in settings.selected.enumerated() where !version.isEmpty && settings.macIPSWSlots[slot] {
                guard let fw = catalog.macFirmware(identifier: settings.macIdentifier, version: version,
                                                   pinned: settings.macIPSWVersions[slot]), fw.signed else { continue }
                let state = inFolder(library.ipsw(fw, device: nil)?.path, settings.siliconFolder)
                items.append(Needed(label: "IPSW Mac \(fw.version)", state: state,
                                    download: state == .missing || state == .corrupted ? .ipsw(fw, destination: settings.macIPSWPath(fw.version)) : nil))
            }
        }
        if settings.includeIPadIPSW {
            for device in settings.enabledDevices {
                guard let fw = catalog.iPadFirmware(device), fw.signed else { continue }
                let local = library.ipsw(fw, device: device)
                let state = inFolder(local?.path, settings.folder(for: device))
                items.append(Needed(label: "\(device.name) \(fw.version)", state: state,
                                    download: state == .missing || state == .corrupted ? .ipsw(fw, destination: settings.ipswPath(device, fw.version)) : nil))
            }
        }
        if settings.includeLoops {
            items.append(Needed(label: "Loops GarageBand", state: library.loops.isEmpty ? .missing : .ok))
        }
        return items
    }

    // MARK: Téléchargement automatique

    /// Dernier lancement automatique de chaque téléchargement et nombre d'échecs d'affilée
    /// (pour ne jamais relancer en boucle un téléchargement qui échoue).
    private var autoAttempts: [String: (date: Date, failures: Int)] = [:]
    /// Attente avant de relancer après 1, 2, 3… échecs : 5 min, 30 min, 2 h, puis 6 h.
    private static let backoff: [TimeInterval] = [5 * 60, 30 * 60, 2 * 3600, 6 * 3600]
    func setAutoDownload(_ on: Bool) {
        settings.autoDownload = on
        if on { autoDownloadTick() }
    }

    /// Met en téléchargement tout ce qui manque. Un échec est retenté de plus en plus tard, sans fin mais sans inonder.
    func autoDownloadTick() {
        // Pendant que l'agent d'arrière-plan travaille, c'est lui qui télécharge.
        guard settings.autoDownload, !preparer.isRunning, !Agent.isDownloading else { return }
        for kind in validatedChecklist().compactMap(\.download) {
            let key = DownloadJob(kind: kind).key
            if downloads.active.contains(where: { $0.key == key }) { continue }
            var failures = autoAttempts[key]?.failures ?? 0
            // Annulé à la main : on ne le relance pas derrière le dos de l'utilisateur.
            if downloads.jobs.last(where: { $0.key == key })?.state == .cancelled { continue }
            // Déjà en cours dans un autre processus (l'app ou l'icône).
            if SharedDownloads.others().contains(where: { $0.key == key }) { continue }
            if let last = downloads.jobs.last(where: { $0.key == key }), case .failed = last.state { failures += 1 }
            if let previous = autoAttempts[key], failures > 0 {
                let wait = Self.backoff[min(failures, Self.backoff.count) - 1]
                guard Date().timeIntervalSince(previous.date) >= wait else { continue }
                if failures == 1 {
                    notifier.notify("Téléchargement en échec", "\(DownloadJob(kind: kind).title) : nouvel essai automatique plus tard.", isError: true)
                }
            }
            downloads.jobs.removeAll { $0.key == key && $0.isFinished }   // l'échec est compté, on garde la liste propre
            autoAttempts[key] = (Date(), failures)
            downloads.enqueue(kind)
        }
    }

    // MARK: Actualisation automatique

    /// Personne n'appuie sur « Actualiser » : les fichiers sont relus toutes les 15 s quand l'app est au premier plan
    /// (et à chaque retour dans l'app), les versions d'Apple toutes les 3 heures.
    private func autoRefresh() {
        Task { @MainActor [weak self] in
            var lastApple = Date(), lastValidated = Date(), lastAppUpdate = Date()
            while let self {
                try? await Task.sleep(for: .seconds(15))
                guard !self.preparer.isRunning else { continue }
                // Mise à jour de l'app : toutes les heures, installée dès que rien n'est en cours.
                if Date().timeIntervalSince(lastAppUpdate) > 3600 {
                    lastAppUpdate = Date()
                    await self.updater.check(silently: true)
                    if self.updater.state == .available && self.downloads.active.isEmpty { await self.updater.install() }
                }
                if Date().timeIntervalSince(lastValidated) > 5 * 60 {
                    lastValidated = Date()
                    await self.syncValidated(notify: true)
                }
                if Date().timeIntervalSince(lastApple) > 3 * 3600 {
                    lastApple = Date()
                    await self.catalog.loadInstallers()
                    await self.refreshFirmwares()
                    self.checkForUpdates(notify: true)
                }
                await self.refreshSetup()
                // Même fenêtre en arrière-plan (Mac de production) : la page reste à jour toute seule.
                if !self.library.isScanning { await self.library.scan() }
                self.autoDownloadTick()
            }
        }
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
        // Au retour dans l'app (Réglages Système, Finder…) : on revérifie l'autorisation et on relit les fichiers,
        // pour voir tout de suite un IPSW déplacé ou supprimé à la main.
        NotificationCenter.default.addObserver(forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                await self.refreshSetup()
                if !self.library.isScanning && !self.preparer.isRunning { await self.library.scan() }
            }
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
