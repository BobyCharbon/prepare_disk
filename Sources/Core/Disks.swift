import Foundation
import Observation

struct Partition: Identifiable, Hashable {
    let id: String          // "disk4s2"
    let name: String
    let size: Int64
    let mountPoint: String?
    let content: String     // "Apple_HFS", "EFI"…
}

/// Un disque externe physique branché.
struct ExternalDisk: Identifiable, Hashable {
    let id: String          // "disk4"
    let name: String
    let size: Int64
    let partitions: [Partition]

    var label: String { "\(name) (\(id))" }
    var dataPartition: Partition? { partitions.first { $0.name == "DataExternalDrive" } }
    /// Disque déjà préparé par l'app ou par l'ancien script.
    var looksPrepared: Bool { dataPartition != nil }
}

/// État d'un élément trouvé sur un disque, comparé à ce qui est choisi.
enum ItemStatus: Hashable {
    case upToDate, outdated(String), unknown, notSelected

    var text: String {
        switch self {
        case .upToDate: return "À jour"
        case let .outdated(newer): return "Obsolète → \(newer)"
        case .unknown: return "Version inconnue"
        case .notSelected: return "Non choisi"
        }
    }
}

struct InspectedOS: Identifiable, Hashable {
    let partition: Partition
    let appPath: String?
    let version: String?
    let build: String?
    let bootable: Bool
    var status: ItemStatus
    var id: String { partition.id }
}

struct InspectedFile: Identifiable, Hashable {
    let category: String    // "Mac Apple Silicon", "iPad 10ème Gen", "Loops"
    let path: String
    let size: Int64
    var status: ItemStatus
    var signed: Bool?
    var id: String { path }
    var name: String { (path as NSString).lastPathComponent }
}

struct DiskInspection {
    let disk: ExternalDisk
    var systems: [InspectedOS]
    var files: [InspectedFile]
    var dataFree: Int64?

    var outdatedSystems: [InspectedOS] { systems.filter { if case .outdated = $0.status { return true }; return false } }
    var outdatedFiles: [InspectedFile] { files.filter { if case .outdated = $0.status { return true }; return false } }
    var isUpToDate: Bool { outdatedSystems.isEmpty && outdatedFiles.isEmpty }
}

/// Disques externes branchés et inspection de leur contenu.
@MainActor
@Observable
final class DiskStore {
    private let settings: AppSettings
    private let catalog: Catalog
    private let library: Library

    var disks: [ExternalDisk] = []
    var isLoading = false
    var inspections: [String: DiskInspection] = [:]
    var inspecting: Set<String> = []

    init(settings: AppSettings, catalog: Catalog, library: Library) {
        self.settings = settings
        self.catalog = catalog
        self.library = library
    }

    func load() async {
        isLoading = true
        defer { isLoading = false }
        let list = await Shell.plist("/usr/sbin/diskutil", ["list", "-plist", "external", "physical"])
        let entries = list?["AllDisksAndPartitions"] as? [[String: Any]] ?? []
        var found: [ExternalDisk] = []
        for entry in entries {
            guard let id = entry["DeviceIdentifier"] as? String else { continue }
            let info = await Shell.plist("/usr/sbin/diskutil", ["info", "-plist", id])
            let parts = (entry["Partitions"] as? [[String: Any]] ?? []).compactMap { p -> Partition? in
                guard let pid = p["DeviceIdentifier"] as? String else { return nil }
                return Partition(id: pid, name: p["VolumeName"] as? String ?? "",
                                 size: (p["Size"] as? NSNumber)?.int64Value ?? 0,
                                 mountPoint: p["MountPoint"] as? String,
                                 content: p["Content"] as? String ?? "")
            }
            found.append(ExternalDisk(id: id,
                                      name: info?["MediaName"] as? String ?? "Disque externe",
                                      size: (entry["Size"] as? NSNumber)?.int64Value ?? (info?["TotalSize"] as? NSNumber)?.int64Value ?? 0,
                                      partitions: parts))
        }
        disks = found
        inspections = inspections.filter { key, _ in found.contains { $0.id == key } }
    }

    func disk(_ id: String) -> ExternalDisk? { disks.first { $0.id == id } }

    func eject(_ id: String) async -> Bool {
        let ok = await Shell.run("/usr/sbin/diskutil", ["eject", id]).status == 0
        await load()
        return ok
    }

    /// Regarde ce que contient un disque et le compare aux versions choisies.
    @discardableResult
    func inspect(_ id: String) async -> DiskInspection? {
        await load()
        guard let disk = disk(id) else { return nil }
        inspecting.insert(id)
        defer { inspecting.remove(id) }

        let chosen = settings.selected.filter { !$0.isEmpty }
        var systems: [InspectedOS] = []
        for part in disk.partitions {
            guard let mount = part.mountPoint, part.name != "DataExternalDrive" else { continue }
            // N'importe quel .app à la racine : l'ancien script le renommait ("Tahoe 26.1.app").
            let apps = ((try? FileManager.default.contentsOfDirectory(atPath: mount)) ?? [])
                .filter { $0.hasSuffix(".app") && !$0.hasPrefix(".") }
            guard let app = apps.first.map({ mount + "/" + $0 }) else { continue }
            var version = part.name.versionInName
            var build: String?
            if let detected = await library.detectVersion(app) { version = detected.0; build = detected.1 }
            let bootable = FileManager.default.fileExists(atPath: mount + "/System/Library/CoreServices/boot.efi")
            systems.append(InspectedOS(partition: part, appPath: app, version: version, build: build,
                                       bootable: bootable, status: status(of: version, among: chosen)))
        }

        var files: [InspectedFile] = []
        var free: Int64?
        if let data = disk.dataPartition, let mount = data.mountPoint {
            free = (try? URL(fileURLWithPath: mount).resourceValues(forKeys: [.volumeAvailableCapacityKey]))
                .flatMap { $0.volumeAvailableCapacity }.map(Int64.init)
            // Versions IPSW Mac attendues : celles choisies, sinon celle de chaque macOS.
            let macVersions = settings.selected.indices.compactMap { slot -> String? in
                let version = settings.selected[slot]
                guard !version.isEmpty, settings.macIPSWSlots[slot] else { return nil }
                let pinned = settings.macIPSWVersions[slot]
                return catalog.macFirmware(identifier: settings.macIdentifier, version: version, pinned: pinned)?.version
                    ?? (pinned.isEmpty ? version : pinned)
            }
            for file in library.files(in: mount + "/OS/MacOS/Silicon", extensions: ["ipsw", "zip"]) {
                let fw = file.version.flatMap { catalog.firmware(identifier: settings.macIdentifier, version: $0) }
                files.append(InspectedFile(category: "Mac Apple Silicon", path: file.path, size: file.size,
                                           status: status(of: file.version, among: macVersions), signed: fw?.signed))
            }
            for device in settings.devices {
                for file in library.files(in: mount + "/OS/iOS/" + device.name, extensions: ["ipsw", "zip"]) {
                    let latest = catalog.iPadFirmware(device)
                    let fw = file.version.flatMap { catalog.firmware(identifier: device.identifier, version: $0) }
                    var st = ItemStatus.unknown
                    if let latest, let v = file.version {
                        st = v == latest.version ? .upToDate
                            : latest.version.isNewerVersion(than: v) ? .outdated(latest.version) : .notSelected
                    }
                    files.append(InspectedFile(category: device.name, path: file.path, size: file.size, status: st, signed: fw?.signed))
                }
            }
            for file in library.files(in: mount + "/Others", extensions: ["zip", "dmg", "pkg"]) {
                files.append(InspectedFile(category: "Others", path: file.path, size: file.size, status: .upToDate, signed: nil))
            }
        }
        let result = DiskInspection(disk: disk, systems: systems, files: files, dataFree: free)
        inspections[id] = result
        return result
    }

    /// À jour si la version est choisie ; obsolète si une version plus récente du même macOS est choisie.
    private func status(of version: String?, among chosen: [String]) -> ItemStatus {
        guard let version else { return .unknown }
        if chosen.contains(version) { return .upToDate }
        if let newer = chosen.first(where: { $0.majorVersion == version.majorVersion && $0.isNewerVersion(than: version) }) {
            return .outdated(newer)
        }
        return .notSelected
    }
}
