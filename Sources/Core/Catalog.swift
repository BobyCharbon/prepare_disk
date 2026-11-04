import Foundation
import Observation

/// Un installateur macOS complet proposé par Apple (`softwareupdate --list-full-installers`).
struct Installer: Identifiable, Hashable, Codable {
    let title: String      // "macOS Sequoia"
    let version: String    // "15.8.2"
    let build: String
    let sizeKiB: Int

    var id: String { version }
    /// "Sequoia", "Golden Gate"… (sans "macOS" ni numéro devant)
    var name: String {
        title.replacingOccurrences(of: "macOS ", with: "")
            .replacingOccurrences(of: #"^\d+\s+"#, with: "", options: .regularExpression)
    }
    var major: String { version.majorVersion }
    var sizeBytes: Int64 { Int64(sizeKiB) * 1024 }
    var sizeText: String { sizeBytes.fileSize }
    /// Nom donné à la partition à la fin, comme le script : "15.8.2 Sequoia"
    var volumeLabel: String { "\(version) \(name)" }
    /// Taille de partition nécessaire pour createinstallmedia (installateur + marge).
    var requiredPartitionGB: Int { Int((Double(sizeBytes) / 1_000_000_000).rounded(.up)) + 3 }
}

/// Un firmware IPSW (iPad ou Mac Apple Silicon) décrit par api.ipsw.me.
struct Firmware: Identifiable, Hashable, Codable {
    let identifier: String
    let version: String
    let buildid: String
    let url: String
    let filesize: Int64
    let sha1sum: String?
    let signed: Bool

    var id: String { identifier + "-" + buildid }
    var fileName: String { URL(string: url)?.lastPathComponent ?? "\(identifier)_\(version)_\(buildid).ipsw" }
}

/// Le paquet officiel d'un macOS (InstallAssistant.pkg) dans le catalogue d'Apple.
struct InstallerPackage: Codable, Hashable {
    let version: String
    let build: String
    let url: URL
    let size: Int64
}

/// Ce que propose Apple : installateurs macOS et IPSW.
@MainActor
@Observable
final class Catalog {
    var installers: [Installer] = []
    var isLoadingInstallers = false
    var installersError: String?

    /// Firmwares par identifiant d'appareil, du plus récent au plus ancien.
    var firmwares: [String: [Firmware]] = [:]
    var deviceNames: [String: String] = [:]
    var isLoadingFirmwares = false
    var firmwaresError: String?
    var lastCheck: Date?
    /// Paquets InstallAssistant.pkg du catalogue d'Apple, par numéro de build.
    var packages: [String: InstallerPackage] = [:]

    func loadInstallers() async {
        isLoadingInstallers = true
        defer { isLoadingInstallers = false }
        let result = await Shell.run("/usr/sbin/softwareupdate", ["--list-full-installers"])
        let regex = #/Title: (.+?), Version: ([\d.]+), Size: (\d+)KiB, Build: (\w+)/#
        let found = result.output.split(separator: "\n").compactMap { line -> Installer? in
            guard let m = line.firstMatch(of: regex) else { return nil }
            return Installer(title: String(m.1), version: String(m.2), build: String(m.4), sizeKiB: Int(m.3) ?? 0)
        }
        installersError = found.isEmpty ? "Impossible d'obtenir la liste des versions chez Apple." : nil
        if !found.isEmpty { installers = found }
        await loadPackages()
        lastCheck = Date()
    }

    /// Lit le catalogue d'Apple pour trouver le paquet officiel de chaque macOS (téléchargé directement, plus
    /// fiable que softwareupdate, qui refuse en silence les versions plus anciennes que celle du Mac).
    func loadPackages() async {
        let url = URL(string: "https://swscan.apple.com/content/catalogs/others/index-27-26-15-14-13-12-10.16-10.15-10.14-10.13-10.12-10.11-10.10-10.9-mountainlion-lion-snowleopard-leopard.merged-1.sucatalog")!
        guard let (data, _) = try? await URLSession.shared.data(from: url),
              let catalog = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
              let products = catalog["Products"] as? [String: [String: Any]] else { return }
        // Version et build sont dans la « distribution » de chaque produit (gardée en cache : elle ne change pas).
        var cache = UserDefaults.app.dictionary(forKey: "installerPackageCache") as? [String: [String]] ?? [:]
        var found: [String: InstallerPackage] = [:]
        await withTaskGroup(of: (String, [String]?).self) { group in
            for (id, product) in products {
                guard let pkg = (product["Packages"] as? [[String: Any]])?.first(where: { ($0["URL"] as? String)?.hasSuffix("InstallAssistant.pkg") == true }),
                      let pkgURL = pkg["URL"] as? String, let size = (pkg["Size"] as? NSNumber)?.int64Value else { continue }
                if let hit = cache[id], hit.count == 2 {
                    found[hit[1]] = InstallerPackage(version: hit[0], build: hit[1], url: URL(string: pkgURL)!, size: size)
                    continue
                }
                let distributions = product["Distributions"] as? [String: String] ?? [:]
                guard let dist = (distributions["English"] ?? distributions["en"] ?? distributions.values.first).flatMap(URL.init(string:)) else { continue }
                group.addTask {
                    guard let (data, _) = try? await URLSession.shared.data(from: dist) else { return (id, nil) }
                    let text = String(decoding: data, as: UTF8.self)
                    func value(_ key: String) -> String? {
                        text.firstMatch(of: try! Regex("<key>\(key)</key>\\s*<string>([^<]+)</string>")).map { String($0.output[1].substring ?? "") }
                    }
                    guard let version = value("VERSION"), let build = value("BUILD") else { return (id, nil) }
                    return (id, [version, build, pkgURL, String(size)])
                }
            }
            for await (id, info) in group {
                guard let info, let url = URL(string: info[2]), let size = Int64(info[3]) else { continue }
                cache[id] = [info[0], info[1]]
                found[info[1]] = InstallerPackage(version: info[0], build: info[1], url: url, size: size)
            }
        }
        UserDefaults.app.set(cache, forKey: "installerPackageCache")
        packages = found
    }

    func loadFirmwares(for identifiers: [String]) async {
        isLoadingFirmwares = true
        defer { isLoadingFirmwares = false }
        var errors: [String] = []
        await withTaskGroup(of: (String, String?, [Firmware]?).self) { group in
            for id in Set(identifiers) {
                group.addTask { await Self.fetchFirmwares(identifier: id) }
            }
            for await (id, name, list) in group {
                if let list { firmwares[id] = list; deviceNames[id] = name } else { errors.append(id) }
            }
        }
        firmwaresError = errors.isEmpty ? nil : "IPSW introuvables pour : \(errors.sorted().joined(separator: ", "))"
    }

    private nonisolated static func fetchFirmwares(identifier: String) async -> (String, String?, [Firmware]?) {
        struct Response: Decodable {
            let name: String
            let firmwares: [Item]
            struct Item: Decodable {
                let version, buildid, url: String
                let filesize: Int64
                let sha1sum: String?
                let signed: Bool
            }
        }
        guard let url = URL(string: "https://api.ipsw.me/v4/device/\(identifier)?type=ipsw"),
              let (data, _) = try? await URLSession.shared.data(from: url),
              let response = try? JSONDecoder().decode(Response.self, from: data) else {
            return (identifier, nil, nil)
        }
        let list = response.firmwares.map {
            Firmware(identifier: identifier, version: $0.version, buildid: $0.buildid, url: $0.url,
                     filesize: $0.filesize, sha1sum: $0.sha1sum, signed: $0.signed)
        }
        return (identifier, response.name, list.sorted { $0.version.isNewerVersion(than: $1.version) })
    }

    // MARK: Recherches

    func installer(version: String) -> Installer? { installers.first { $0.version == version } }

    /// Dernière version proposée par Apple pour ce macOS majeur.
    func latestInstaller(major: String) -> Installer? {
        installers.filter { $0.major == major }.max { $1.version.isNewerVersion(than: $0.version) }
    }

    /// La dernière version des n derniers macOS (le choix par défaut).
    func latestMajors(_ count: Int) -> [Installer] {
        var majors: [String] = []
        for i in installers where !majors.contains(i.major) { majors.append(i.major) }
        return majors.prefix(count).compactMap { latestInstaller(major: $0) }
    }

    func latestSigned(identifier: String) -> Firmware? {
        firmwares[identifier]?.first { $0.signed }
    }

    func signedFirmwares(identifier: String) -> [Firmware] {
        firmwares[identifier]?.filter(\.signed) ?? []
    }

    /// IPSW Mac pour un emplacement : la version choisie si `pinned` est rempli (même si elle n'est
    /// plus signée, pour pouvoir le signaler), sinon la même version que le macOS, sinon la plus
    /// récente signée du même macOS.
    func macFirmware(identifier: String, version: String, pinned: String = "") -> Firmware? {
        if !pinned.isEmpty && pinned.majorVersion == version.majorVersion { return firmware(identifier: identifier, version: pinned) }
        let list = signedFirmwares(identifier: identifier)
        return list.first { $0.version == version }
            ?? list.first { $0.version.majorVersion == version.majorVersion }
    }

    /// IPSW iPad choisi : la version demandée, sinon la dernière signée.
    func iPadFirmware(_ device: Device) -> Firmware? {
        guard let version = device.version, !version.isEmpty else { return latestSigned(identifier: device.identifier) }
        return firmware(identifier: device.identifier, version: version)
    }

    /// Le firmware connu pour une version donnée (pour savoir s'il est encore signé).
    func firmware(identifier: String, version: String) -> Firmware? {
        firmwares[identifier]?.first { $0.version == version }
    }
}
