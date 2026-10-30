import Foundation
import Observation

/// Un appareil dont on garde l'IPSW (iPad) : le nom sert aussi de dossier dans OS/iOS.
struct Device: Codable, Hashable, Identifiable {
    var id = UUID()
    var name: String        // "iPad 10ème Gen"
    var identifier: String  // "iPad13,18"
    var enabled = true
    /// Version IPSW validée (nil = dernière version signée).
    var version: String?

    static let defaults: [Device] = [
        Device(name: "iPad 11ème Gen", identifier: "iPad15,7"),
        Device(name: "iPad 10ème Gen", identifier: "iPad13,18"),
        Device(name: "iPad 9ème Gen", identifier: "iPad12,1"),
        Device(name: "iPad 8ème Gen", identifier: "iPad11,6"),
        Device(name: "iPad 7ème Gen", identifier: "iPad7,11"),
        Device(name: "iPad 6ème Gen", identifier: "iPad7,5"),
    ]
}

/// Tous les réglages, enregistrés dans les préférences.
@MainActor
@Observable
final class AppSettings {
    private let defaults = UserDefaults.standard

    /// Les 3 versions macOS choisies ("" = emplacement vide).
    var selected: [String] {
        didSet {
            defaults.set(selected, forKey: "selectedVersions")
            clearStalePins()
        }
    }
    /// Taille minimale d'une partition macOS (agrandie si l'installateur est plus gros).
    var partitionSizeGB: Int { didSet { defaults.set(partitionSizeGB, forKey: "partitionSizeGB") } }
    /// Dossier prepare_disk : OS/MacOS/Intel, OS/MacOS/Silicon, OS/iOS, Others.
    var dataFolder: String { didSet { defaults.set(dataFolder, forKey: "dataFolder") } }

    // Contenu de DataExternalDrive
    var includeMacIPSW: Bool { didSet { defaults.set(includeMacIPSW, forKey: "includeMacIPSW") } }
    /// Pour quels emplacements macOS on copie aussi l'IPSW Apple Silicon.
    var macIPSWSlots: [Bool] { didSet { defaults.set(macIPSWSlots, forKey: "macIPSWSlots") } }
    /// Version IPSW Apple Silicon choisie par emplacement ("" = automatique, celle du macOS).
    var macIPSWVersions: [String] { didSet { defaults.set(macIPSWVersions, forKey: "macIPSWVersions") } }
    var macIdentifier: String { didSet { defaults.set(macIdentifier, forKey: "macIdentifier") } }
    var macIPSWPrefix: String { didSet { defaults.set(macIPSWPrefix, forKey: "macIPSWPrefix") } }
    var includeIPadIPSW: Bool { didSet { defaults.set(includeIPadIPSW, forKey: "includeIPadIPSW") } }
    var devices: [Device] { didSet { defaults.set(try? JSONEncoder().encode(devices), forKey: "devices") } }
    var includeLoops: Bool { didSet { defaults.set(includeLoops, forKey: "includeLoops") } }

    // Général
    var checkUpdatesAtLaunch: Bool { didSet { defaults.set(checkUpdatesAtLaunch, forKey: "checkUpdatesAtLaunch") } }
    var notificationsEnabled: Bool { didSet { defaults.set(notificationsEnabled, forKey: "notificationsEnabled") } }
    var verifyChecksums: Bool { didSet { defaults.set(verifyChecksums, forKey: "verifyChecksums") } }
    var removeOldOnUpdate: Bool { didSet { defaults.set(removeOldOnUpdate, forKey: "removeOldOnUpdate") } }
    /// Après un téléchargement, met à la corbeille les anciennes versions remplacées dans ~/prepare_disk.
    var removeOldVersions: Bool { didSet { defaults.set(removeOldVersions, forKey: "removeOldVersions") } }
    /// Télécharge tout seul les versions validées (Mac de production).
    var autoDownload: Bool { didSet { defaults.set(autoDownload, forKey: "autoDownload") } }

    init() {
        let d = UserDefaults.standard
        func bool(_ key: String, _ fallback: Bool) -> Bool { d.object(forKey: key) as? Bool ?? fallback }
        selected = Array(((d.stringArray(forKey: "selectedVersions") ?? []) + ["", "", ""]).prefix(3))
        partitionSizeGB = d.object(forKey: "partitionSizeGB") as? Int ?? 20
        dataFolder = d.string(forKey: "dataFolder") ?? NSHomeDirectory() + "/prepare_disk"
        includeMacIPSW = bool("includeMacIPSW", true)
        macIPSWSlots = Array(((d.array(forKey: "macIPSWSlots") as? [Bool]) ?? [true, true, false]).prefix(3))
        macIPSWVersions = Array(((d.stringArray(forKey: "macIPSWVersions") ?? []) + ["", "", ""]).prefix(3))
        macIdentifier = d.string(forKey: "macIdentifier") ?? "MacBookAir10,1"
        macIPSWPrefix = d.string(forKey: "macIPSWPrefix") ?? "MacBook Air SILICON"
        includeIPadIPSW = bool("includeIPadIPSW", true)
        devices = (d.data(forKey: "devices")).flatMap { try? JSONDecoder().decode([Device].self, from: $0) } ?? Device.defaults
        includeLoops = bool("includeLoops", false)
        checkUpdatesAtLaunch = bool("checkUpdatesAtLaunch", true)
        notificationsEnabled = bool("notificationsEnabled", true)
        verifyChecksums = bool("verifyChecksums", true)
        removeOldOnUpdate = bool("removeOldOnUpdate", true)
        removeOldVersions = bool("removeOldVersions", true)
        autoDownload = bool("autoDownload", false)
        clearStalePins()
    }

    /// Une version IPSW Mac fixée pour un autre macOS (ex. 26.6.2 alors que l'emplacement est passé à 27.2) ne vaut plus rien.
    private func clearStalePins() {
        for slot in 0..<3 where !macIPSWVersions[slot].isEmpty
            && macIPSWVersions[slot].majorVersion != selected[slot].majorVersion {
            macIPSWVersions[slot] = ""
        }
    }

    // Dossiers sources
    var intelFolder: String { dataFolder + "/OS/MacOS/Intel" }
    var siliconFolder: String { dataFolder + "/OS/MacOS/Silicon" }
    var iosFolder: String { dataFolder + "/OS/iOS" }
    var othersFolder: String { dataFolder + "/Others" }
    func folder(for device: Device) -> String { iosFolder + "/" + device.name }

    // Noms rangés : "Modèle - Version"
    func macIPSWPath(_ version: String) -> String { siliconFolder + "/\(macIPSWPrefix) - \(version).ipsw" }
    func ipswPath(_ device: Device, _ version: String) -> String { folder(for: device) + "/\(device.name) - \(version).ipsw" }
    /// "Install macOS Tahoe 26.6.2.app" : la version dans le nom, comme l'ancien script.
    func installerPath(name: String, version: String) -> String { intelFolder + "/Install macOS \(name) \(version).app" }

    var enabledDevices: [Device] { devices.filter(\.enabled) }
}
