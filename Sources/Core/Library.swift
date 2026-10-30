import AppKit
import Foundation
import Observation

enum SignatureState: Equatable {
    case unknown, checking, valid(String), invalid(String)
}

/// Un installateur "Install macOS….app" présent sur ce Mac.
struct LocalInstaller: Identifiable, Hashable {
    let path: String
    var name: String          // "Install macOS Sequoia"
    var version: String?
    var build: String?
    var size: Int64
    var date: Date

    var id: String { path }
    var createInstallMedia: String { path + "/Contents/Resources/createinstallmedia" }
}

/// Un fichier local (IPSW ou loops).
struct LocalFile: Identifiable, Hashable {
    let path: String
    let size: Int64
    let date: Date
    /// Pour un IPSW : lus dans son BuildManifest.plist (fiable) ; sinon déduits du nom.
    var version: String?
    var build: String?
    /// Modèles acceptés par l'IPSW (ex. ["iPad13,18", "iPad13,19"]), lus dans le BuildManifest.
    var productTypes: [String] = []
    var id: String { path }
    var name: String { (path as NSString).lastPathComponent }

    init(path: String, size: Int64, date: Date) {
        self.path = path
        self.size = size
        self.date = date
        version = (path as NSString).lastPathComponent.versionInName
        if path.lowercased().hasSuffix(".ipsw"), let manifest = ipswManifest(path, size: size, date: date) {
            version = manifest.version
            build = manifest.build
            productTypes = manifest.productTypes
        }
    }

    /// Le même firmware : même build si on le connaît (identifiant exact), sinon même version.
    func matches(_ firmware: Firmware) -> Bool {
        if !productTypes.isEmpty && !productTypes.contains(firmware.identifier) { return false }
        return build.map { $0 == firmware.buildid } ?? (version == firmware.version)
    }
}

/// Version et build d'un IPSW, lus dans son BuildManifest.plist : le nom du fichier peut mentir.
/// Mis en cache (chemin, taille, date) : la lecture prend ~0,2 s.
private func ipswManifest(_ path: String, size: Int64, date: Date) -> (version: String, build: String, productTypes: [String])? {
    let key = "\(path)|\(size)|\(date.timeIntervalSince1970)"
    var cache = UserDefaults.standard.dictionary(forKey: "ipswManifestCache3") as? [String: [String]] ?? [:]
    if let hit = cache[key], hit.count == 3 { return (hit[0], hit[1], hit[2].split(separator: " ").map(String.init)) }
    let process = Process()
    let pipe = Pipe()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/unzip")
    process.arguments = ["-p", path, "BuildManifest.plist"]
    process.standardOutput = pipe
    process.standardError = FileHandle.nullDevice
    guard (try? process.run()) != nil else { return nil }
    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    guard let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
          let version = plist["ProductVersion"] as? String,
          let build = plist["ProductBuildVersion"] as? String else { return nil }
    let types = plist["SupportedProductTypes"] as? [String] ?? []
    cache[key] = [version, build, types.joined(separator: " ")]   // les identifiants contiennent des virgules (iPad13,18)
    UserDefaults.standard.set(cache, forKey: "ipswManifestCache3")
    return (version, build, types)
}

/// Un fichier à ranger : déplacé dans son dossier et/ou renommé "Modèle - Version".
struct Suggestion: Identifiable, Hashable {
    let path: String
    let destination: String
    var id: String { path }
    var name: String { (path as NSString).lastPathComponent }
    var isRename: Bool { (path as NSString).deletingLastPathComponent == (destination as NSString).deletingLastPathComponent }
    var isInstaller: Bool { path.hasSuffix(".app") }
}

/// Ce qui est déjà téléchargé sur ce Mac.
@MainActor
@Observable
final class Library {
    private let settings: AppSettings
    private let defaults = UserDefaults.standard

    var installers: [LocalInstaller] = []
    var signatures: [String: SignatureState] = [:]
    var macIPSWs: [LocalFile] = []
    var iPadIPSWs: [String: [LocalFile]] = [:]   // nom de l'appareil → fichiers
    var loops: [LocalFile] = []
    var isScanning = false
    /// Fichiers hors de leur dossier ou mal nommés : on propose de les ranger, l'utilisateur décide.
    var suggestions: [Suggestion] = []
    var moveError: String?
    /// Pour reconnaître un IPSW au nom d'origine d'Apple.
    weak var catalog: Catalog?

    /// Fichiers que l'utilisateur a choisi de laisser où ils sont.
    private var dismissed: Set<String> {
        didSet { defaults.set(Array(dismissed), forKey: "dismissedSuggestions") }
    }

    /// Versions détectées : "chemin|date" → [version, build]
    private var versionCache: [String: [String]] {
        didSet { defaults.set(versionCache, forKey: "installerVersionCache") }
    }

    init(settings: AppSettings) {
        self.settings = settings
        versionCache = defaults.dictionary(forKey: "installerVersionCache") as? [String: [String]] ?? [:]
        dismissed = Set(defaults.stringArray(forKey: "dismissedSuggestions") ?? [])
    }

    // MARK: Analyse

    func scan() async {
        isScanning = true
        defer { isScanning = false }
        createSourceFolders()
        let elsewhere = await findElsewhere()
        var proposals: [Suggestion] = []
        func suggest(_ path: String, _ destination: String) {
            guard path != destination, !dismissed.contains(path),
                  !FileManager.default.fileExists(atPath: destination),
                  !proposals.contains(where: { $0.destination == destination }) else { return }   // doublon : une seule copie à ranger
            proposals.append(Suggestion(path: path, destination: destination))
        }

        var found: [LocalInstaller] = []
        for app in ["/Applications", settings.intelFolder].flatMap(apps(in:)) + elsewhere.installers {
            var item = LocalInstaller(path: app, name: ((app as NSString).lastPathComponent as NSString).deletingPathExtension,
                                      version: nil, build: nil, size: 0, date: modificationDate(app))
            if let (version, build) = await detectVersion(app) {
                item.version = version
                item.build = build
            } else {
                item.version = item.name.versionInName
            }
            item.size = await Task.detached { itemSize(app) }.value
            found.append(item)
            if let version = item.version {
                let name = item.name.replacingOccurrences(of: "Install macOS ", with: "")
                    .replacingOccurrences(of: #"\s*\d+(\.\d+)*$"#, with: "", options: .regularExpression)
                suggest(app, settings.installerPath(name: name, version: version))
            }
        }
        installers = found.sorted { ($0.version ?? "").isNewerVersion(than: $1.version ?? "") }

        // Chaque IPSW est attribué d'après les modèles qu'il contient (BuildManifest), pas d'après son nom
        // ou son dossier : un IPSW d'iPad 11 posé dans le dossier de l'iPad 10 est proposé au rangement.
        var mac: [LocalFile] = []
        var ipads: [String: [LocalFile]] = [:]
        var candidates: [(LocalFile, Owner?)] = files(in: settings.siliconFolder, extensions: ["ipsw", "zip"]).map { ($0, .mac) }
        for device in settings.devices {
            candidates += files(in: settings.folder(for: device), extensions: ["ipsw", "zip"]).map { ($0, Owner.device(device)) }
        }
        candidates += elsewhere.ipsws.map { path in (LocalFile(path: path, size: itemSize(path), date: modificationDate(path)), nil) }
        for (file, folder) in candidates {
            switch owner(of: file, folder: folder) {
            case .mac: mac.append(file)
            case let .device(device): ipads[device.name, default: []].append(file)
            case nil: break
            }
        }
        for file in mac where file.path.hasSuffix(".ipsw") { if let v = file.version { suggest(file.path, settings.macIPSWPath(v)) } }
        for device in settings.devices {
            for file in ipads[device.name] ?? [] where file.path.hasSuffix(".ipsw") { if let v = file.version { suggest(file.path, settings.ipswPath(device, v)) } }
        }
        let newestFirst: (LocalFile, LocalFile) -> Bool = { ($0.version ?? "").isNewerVersion(than: $1.version ?? "") }
        macIPSWs = mac.sorted(by: newestFirst)
        iPadIPSWs = ipads.mapValues { $0.sorted(by: newestFirst) }
        loops = files(in: settings.othersFolder, extensions: ["zip", "dmg", "pkg"])
            .filter { $0.name.localizedCaseInsensitiveContains("loop") }
        suggestions = proposals
    }

    private enum Owner { case mac, device(Device) }

    /// À quel appareil appartient un IPSW : d'après les modèles de son BuildManifest ; à défaut (fichier illisible),
    /// d'après son dossier, notre nom ("iPad 10ème Gen - …") ou le nom d'origine d'Apple.
    private func owner(of file: LocalFile, folder: Owner?) -> Owner? {
        if !file.productTypes.isEmpty {
            if file.productTypes.contains(settings.macIdentifier) { return .mac }
            let matches = settings.devices.filter { file.productTypes.contains($0.identifier) }
            if case let .device(current)? = folder, matches.contains(where: { $0.id == current.id }) { return folder }
            return (matches.first(where: \.enabled) ?? matches.first).map { .device($0) }
        }
        if let folder { return folder }
        let name = file.name
        if name.hasPrefix(settings.macIPSWPrefix) { return .mac }
        if let device = settings.devices.first(where: { name.hasPrefix($0.name) }) { return .device(device) }
        guard let catalog else { return nil }
        func known(_ identifier: String) -> Bool { catalog.firmwares[identifier]?.contains { $0.fileName == name } == true }
        if known(settings.macIdentifier) { return .mac }
        let matches = settings.devices.filter { known($0.identifier) }
        return (matches.first(where: \.enabled) ?? matches.first).map { .device($0) }
    }

    /// Installateurs et IPSW ailleurs sur ce Mac (Spotlight, plus le dossier Téléchargements si Spotlight est coupé).
    private func findElsewhere() async -> (installers: [String], ipsws: [String]) {
        let query = "kMDItemFSName == '*.ipsw'c || (kMDItemFSName == 'Install macOS*' && kMDItemContentType == 'com.apple.application-bundle')"
        var paths = Set(await Shell.run("/usr/bin/mdfind", [query]).output.split(separator: "\n").map(String.init))
        let downloads = NSHomeDirectory() + "/Downloads"
        for name in (try? FileManager.default.contentsOfDirectory(atPath: downloads)) ?? [] { paths.insert(downloads + "/" + name) }

        let home = NSHomeDirectory()
        let skipped = ["/Volumes/", "/private/", "/System/", "/Library/", home + "/Library/", home + "/.Trash/", settings.dataFolder + "/"]
        let candidates = paths.filter { path in
            !skipped.contains { path.hasPrefix($0) } && !path.contains(".app/")
                && (path as NSString).deletingLastPathComponent != "/Applications"
        }
        let name = { (path: String) in (path as NSString).lastPathComponent }
        return (candidates.filter { name($0).hasPrefix("Install macOS") && $0.hasSuffix(".app")
                                    && FileManager.default.fileExists(atPath: $0 + "/Contents/Resources/createinstallmedia") }.sorted(),
                candidates.filter { ($0 as NSString).pathExtension.lowercased() == "ipsw" }.sorted())
    }

    /// Crée les dossiers sources s'ils manquent (comme l'ancien script).
    private func createSourceFolders() {
        let fm = FileManager.default
        var folders = [settings.intelFolder, settings.siliconFolder, settings.othersFolder]
        folders += settings.devices.map { settings.folder(for: $0) }
        for folder in folders where !fm.fileExists(atPath: folder) {
            try? fm.createDirectory(atPath: folder, withIntermediateDirectories: true)
        }
    }

    private func apps(in folder: String) -> [String] {
        ((try? FileManager.default.contentsOfDirectory(atPath: folder)) ?? [])
            .filter { $0.hasPrefix("Install macOS") && $0.hasSuffix(".app") }
            .map { folder + "/" + $0 }
            .filter { FileManager.default.fileExists(atPath: $0 + "/Contents/Resources/createinstallmedia") }
    }

    func files(in folder: String, extensions: [String]) -> [LocalFile] {
        let fm = FileManager.default
        return ((try? fm.contentsOfDirectory(atPath: folder)) ?? [])
            .filter { !$0.hasPrefix(".") && extensions.contains(($0 as NSString).pathExtension.lowercased()) }
            .map { folder + "/" + $0 }
            .map { LocalFile(path: $0, size: itemSize($0), date: modificationDate($0)) }
            .sorted { ($0.version ?? "").isNewerVersion(than: $1.version ?? "") }
    }

    private func modificationDate(_ path: String) -> Date {
        (try? FileManager.default.attributesOfItem(atPath: path)[.modificationDate] as? Date) ?? .distantPast
    }

    /// Lit la version dans SharedSupport.dmg (monté en lecture seule, sans l'afficher).
    func detectVersion(_ app: String) async -> (String, String)? {
        let key = app + "|" + String(modificationDate(app).timeIntervalSince1970)
        if let cached = versionCache[key], cached.count == 2 { return (cached[0], cached[1]) }
        let dmg = app + "/Contents/SharedSupport/SharedSupport.dmg"
        guard FileManager.default.fileExists(atPath: dmg),
              let info = await Shell.plist("/usr/bin/hdiutil", ["attach", dmg, "-readonly", "-nobrowse", "-noverify", "-plist"]),
              let entities = info["system-entities"] as? [[String: Any]],
              let mount = entities.compactMap({ $0["mount-point"] as? String }).first else { return nil }
        let xml = mount + "/com_apple_MobileAsset_MacSoftwareUpdate/com_apple_MobileAsset_MacSoftwareUpdate.xml"
        let plist = NSDictionary(contentsOfFile: xml)
        _ = await Shell.run("/usr/bin/hdiutil", ["detach", mount, "-force"])
        guard let plist,
              let asset = (plist["Assets"] as? [[String: Any]])?.first,
              let version = asset["OSVersion"] as? String else { return nil }
        let build = asset["Build"] as? String ?? ""
        versionCache[key] = [version, build]
        return (version, build)
    }

    // MARK: Recherches

    /// Installateur local de cette version ; avec `build`, il doit aussi avoir ce build (s'il est connu).
    func installer(for version: String, build: String? = nil) -> LocalInstaller? {
        let same = installers.filter { $0.version == version && (build == nil || $0.build == nil || $0.build == build) }
        // De préférence celui qui est déjà rangé dans le dossier Intel.
        return same.first { $0.path.hasPrefix(settings.intelFolder + "/") } ?? same.first
    }

    func installer(matching installer: Installer) -> LocalInstaller? {
        self.installer(for: installer.version, build: installer.build)
    }

    func macIPSW(version: String) -> LocalFile? {
        macIPSWs.first { $0.version == version }
    }

    /// IPSW local de ce firmware (même build, même modèle), de préférence celui qui est déjà bien rangé.
    func ipsw(_ firmware: Firmware, device: Device?) -> LocalFile? {
        let list = device.map { iPadIPSWs[$0.name] ?? [] } ?? macIPSWs
        let folder = device.map(settings.folder(for:)) ?? settings.siliconFolder
        let same = list.filter { $0.matches(firmware) }
        return same.first { $0.path.hasPrefix(folder + "/") } ?? same.first
    }

    func latestIPadIPSW(_ device: Device) -> LocalFile? {
        iPadIPSWs[device.name]?.first
    }

    // MARK: Actions

    func verifySignature(_ item: LocalInstaller) async {
        signatures[item.path] = .checking
        let details = await Shell.run("/usr/bin/codesign", ["-dvv", item.path])
        let authority = details.output.split(separator: "\n")
            .first { $0.hasPrefix("Authority=") }?.replacingOccurrences(of: "Authority=", with: "") ?? ""
        let verify = await Shell.run("/usr/bin/codesign", ["--verify", "--strict", item.path])
        if verify.status == 0 && authority.contains("Apple") {
            signatures[item.path] = .valid(authority)
        } else {
            let reason = verify.output.trimmingCharacters(in: .whitespacesAndNewlines)
            signatures[item.path] = .invalid(reason.isEmpty ? "Signature non Apple : \(authority)" : reason)
        }
    }

    func reveal(_ path: String) {
        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
    }

    /// Met à la corbeille (macOS demande le mot de passe si besoin).
    func trash(_ paths: [String]) async {
        let urls = paths.map { URL(fileURLWithPath: $0) }
        _ = try? await NSWorkspace.shared.recycle(urls)
        await scan()
    }

    /// Range des fichiers à leur place (déplacés et renommés), puis réanalyse.
    func organize(_ items: [Suggestion]) async {
        await moveAll(items.map { ($0.path, $0.destination) })
        await scan()
    }

    /// Laisse ce fichier où il est : on ne le propose plus (il reste utilisé).
    func dismiss(_ item: Suggestion) {
        dismissed.insert(item.path)
        suggestions.removeAll { $0.id == item.id }
    }

    /// Déplace un fichier ; demande le mot de passe administrateur si le dossier d'origine est protégé (/Applications).
    @discardableResult
    func move(_ path: String, to destination: String) async -> Bool {
        await moveAll([(path, destination)])
    }

    /// Déplace des fichiers. Ceux qu'on ne peut pas déplacer soi-même (installateurs de /Applications, à root)
    /// sont déplacés ensemble en administrateur : un seul mot de passe pour tout.
    @discardableResult
    func moveAll(_ moves: [(path: String, destination: String)]) async -> Bool {
        moveError = nil
        var protected: [(path: String, destination: String)] = []
        var errors: [String] = []
        for (path, destination) in moves {
            guard !FileManager.default.fileExists(atPath: destination) else {
                errors.append("« \((destination as NSString).lastPathComponent) » existe déjà")
                continue
            }
            do {
                try await Task.detached {
                    try FileManager.default.createDirectory(atPath: (destination as NSString).deletingLastPathComponent,
                                                            withIntermediateDirectories: true)
                    try FileManager.default.moveItem(atPath: path, toPath: destination)
                }.value
            } catch {
                protected.append((path, destination))
            }
        }
        if !protected.isEmpty {
            let command = protected.map { "/bin/mv -n \(Shell.quote($0.path)) \(Shell.quote($0.destination))" }.joined(separator: " ; ")
            let result = await Shell.runAsAdmin(command)
            for (path, destination) in protected where !FileManager.default.fileExists(atPath: destination) {
                errors.append(result.cancelled ? "« \((path as NSString).lastPathComponent) » : mot de passe refusé"
                                               : "impossible de ranger « \((path as NSString).lastPathComponent) »")
            }
        }
        if !errors.isEmpty { moveError = errors.joined(separator: " · ") }
        return errors.isEmpty
    }

    /// Copie un fichier de loops choisi dans le dossier Others.
    func importLoops(from url: URL) async throws {
        let dest = URL(fileURLWithPath: settings.othersFolder).appendingPathComponent(url.lastPathComponent)
        try? FileManager.default.createDirectory(atPath: settings.othersFolder, withIntermediateDirectories: true)
        if FileManager.default.fileExists(atPath: dest.path) { try FileManager.default.removeItem(at: dest) }
        try await Task.detached { try FileManager.default.copyItem(at: url, to: dest) }.value
        await scan()
    }
}
