import Foundation
import Observation

/// Assistant système : un petit script appartenant à root, que l'utilisateur peut lancer sans mot de passe
/// (règle sudoers limitée à ce seul fichier). Installé une fois, avec le mot de passe administrateur.
/// Il ne fait que des opérations vérifiées : disques externes seulement, createinstallmedia signé par Apple.
@MainActor
@Observable
final class Helper {
    nonisolated static let path = "/Library/PrivilegedHelperTools/com.bobycharbon.preparedisk.helper"
    /// Les fichiers de /etc/sudoers.d contenant un point sont ignorés par sudo.
    static let sudoersPath = "/etc/sudoers.d/preparedisk"

    var isReady = false
    var isInstalling = false
    var error: String?

    /// L'assistant est installé, à jour, et utilisable sans mot de passe. Une version plus ancienne se met
    /// à jour toute seule depuis cette app (signée) : pas de nouvelle demande de mot de passe.
    func check() async {
        var installed = await installedVersion()
        if let current = installed, current != Self.version, Int(current) ?? 0 >= 3 {
            _ = await run(["selfupdate", Agent.appBundle.bundlePath])
            installed = await installedVersion()
        }
        isReady = installed == Self.version
    }

    private func installedVersion() async -> String? {
        let result = await Shell.run("/usr/bin/sudo", ["-n", Self.path, "version"])
        return result.status == 0 ? result.output.trimmingCharacters(in: .whitespacesAndNewlines) : nil
    }

    /// Installation unique (demande le mot de passe administrateur une fois).
    func install() async {
        isInstalling = true
        defer { isInstalling = false }
        error = nil
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("PrepareDisk-helper-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let script = folder.appendingPathComponent("helper"), rule = folder.appendingPathComponent("sudoers")
        do {
            try Self.script.write(to: script, atomically: true, encoding: .utf8)
            try "\(NSUserName()) ALL=(root) NOPASSWD: \(Self.path)\n".write(to: rule, atomically: true, encoding: .utf8)
        } catch {
            self.error = "Impossible de préparer l'assistant."
            return
        }
        let command = [
            "/bin/mkdir -p /Library/PrivilegedHelperTools",
            "/usr/bin/install -o root -g wheel -m 755 \(Shell.quote(script.path)) \(Shell.quote(Self.path))",
            "/usr/sbin/visudo -cf \(Shell.quote(rule.path))",
            "/usr/bin/install -o root -g wheel -m 440 \(Shell.quote(rule.path)) \(Self.sudoersPath)",
        ].joined(separator: " && ")
        let result = await Shell.runAsAdmin(command)
        try? FileManager.default.removeItem(at: folder)
        await check()
        if !isReady { error = result.cancelled ? "Configuration annulée." : "La configuration a échoué : \(result.output)" }
    }

    /// Lance une opération de l'assistant, sans mot de passe.
    func run(_ args: [String]) async -> (status: Int32, output: String) {
        await Shell.run("/usr/bin/sudo", ["-n", Self.path] + args)
    }

    /// Le script de l'assistant (bash, exécuté en root). Chaque commande vérifie ce qu'on lui demande.
    /// Le script de l'assistant (bash, exécuté en root), livré dans l'app signée (Resources/helper.sh).
    nonisolated static var script: String {
        Agent.appBundle.url(forResource: "helper", withExtension: "sh").flatMap { try? String(contentsOf: $0, encoding: .utf8) } ?? ""
    }

    /// Version de l'assistant livrée avec cette app (ligne HELPER_VERSION=… du script).
    nonisolated static var version: String {
        script.firstMatch(of: #/HELPER_VERSION=(\d+)/#).map { String($0.1) } ?? "0"
    }

}
