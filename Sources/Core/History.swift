import Foundation
import Observation

struct CheckResult: Codable, Hashable, Identifiable {
    var id = UUID()
    let label: String
    let ok: Bool
    let detail: String
}

struct HistoryEntry: Codable, Identifiable, Hashable {
    var id = UUID()
    let date: Date
    let kind: String            // "Création" ou "Mise à jour"
    let disks: [String]
    let versions: [String]
    let extras: [String]
    let duration: TimeInterval
    let success: Bool
    let checks: [CheckResult]
    let logFile: String
}

/// Historique des disques préparés, enregistré dans Application Support.
@MainActor
@Observable
final class HistoryStore {
    var entries: [HistoryEntry] = []

    private let folder: URL = {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("PrepareDisk", isDirectory: true)
    }()
    private var file: URL { folder.appendingPathComponent("history.json") }

    init() {
        try? FileManager.default.createDirectory(at: folder.appendingPathComponent("logs"), withIntermediateDirectories: true)
        if let data = try? Data(contentsOf: file) {
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            entries = (try? decoder.decode([HistoryEntry].self, from: data)) ?? []
        }
    }

    /// Enregistre une préparation et son journal.
    func add(kind: String, disks: [String], versions: [String], extras: [String],
             duration: TimeInterval, success: Bool, checks: [CheckResult], log: String) {
        let id = UUID()
        let logURL = folder.appendingPathComponent("logs/\(id.uuidString).log")
        try? log.write(to: logURL, atomically: true, encoding: .utf8)
        entries.insert(HistoryEntry(id: id, date: Date(), kind: kind, disks: disks, versions: versions, extras: extras,
                                    duration: duration, success: success, checks: checks, logFile: logURL.path), at: 0)
        save()
    }

    func remove(_ entry: HistoryEntry) {
        try? FileManager.default.removeItem(atPath: entry.logFile)
        entries.removeAll { $0.id == entry.id }
        save()
    }

    func log(of entry: HistoryEntry) -> String {
        (try? String(contentsOfFile: entry.logFile, encoding: .utf8)) ?? "Journal introuvable."
    }

    /// Durée moyenne de création d'une partition macOS (pour estimer le temps restant).
    var averageSecondsPerSystem: TimeInterval {
        let done = entries.filter { $0.success && $0.kind == "Création" && !$0.versions.isEmpty }
        guard !done.isEmpty else { return 8 * 60 }
        let total = done.reduce(0.0) { $0 + $1.duration / Double($1.versions.count * max($1.disks.count, 1)) }
        return total / Double(done.count)
    }

    private func save() {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = .prettyPrinted
        try? encoder.encode(entries).write(to: file)
    }
}
