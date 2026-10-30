import Foundation
import Observation

enum LogLevel: String, CaseIterable, Identifiable {
    case step = "Étapes", info = "Infos", success = "Réussites", warning = "Avertissements", error = "Erreurs"
    var id: String { rawValue }
}

struct LogLine: Identifiable, Hashable {
    let id = UUID()
    let date: Date
    let text: String
    let level: LogLevel
}

/// Journal de l'app : lignes datées, classées par niveau, exportables.
@MainActor
@Observable
final class LogStore {
    var lines: [LogLine] = []
    private var partial = ""

    /// Ajoute du texte brut (peut contenir plusieurs lignes ou une ligne incomplète).
    func ingest(_ text: String) {
        let combined = partial + text.replacingOccurrences(of: "\r", with: "\n")
        var parts = combined.components(separatedBy: "\n")
        partial = parts.removeLast()
        for part in parts where !part.trimmingCharacters(in: .whitespaces).isEmpty {
            add(part)
        }
    }

    func add(_ text: String, level: LogLevel? = nil) {
        if text.hasPrefix("@@") { return }   // repères internes du script
        lines.append(LogLine(date: Date(), text: text, level: level ?? Self.level(of: text)))
        if lines.count > 20_000 { lines.removeFirst(5_000) }
    }

    func clear() { lines = []; partial = "" }

    static func level(of text: String) -> LogLevel {
        let lower = text.lowercased()
        if text.hasPrefix("==>") { return .step }
        if lower.contains("erreur") || lower.contains("error") || lower.contains("failed") || lower.contains("échec") { return .error }
        if lower.contains("attention") || lower.contains("warning") { return .warning }
        if text.hasPrefix("✓") || lower.contains("terminé") || lower.contains("now available") || lower.contains("succès") { return .success }
        return .info
    }

    func text(of lines: [LogLine]? = nil) -> String {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return (lines ?? self.lines).map { "[\(f.string(from: $0.date))] \($0.text)" }.joined(separator: "\n")
    }
}
