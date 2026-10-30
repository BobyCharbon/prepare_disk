import AppKit
import Foundation
import Observation

/// Mises à jour de l'app depuis les versions publiées sur GitHub (dépôt public).
@MainActor
@Observable
final class Updater {
    static let repository = "BobyCharbon/prepare_disk"
    /// Seule une app signée avec notre certificat est installée (et garde l'Accès complet au disque).
    static let requirement = #"identifier "com.bobycharbon.preparedisk" and certificate root = H"2a4993ddca84b3ae2874dce2ef7cd304c3947083""#

    struct Release: Equatable {
        let version: String
        let notes: String
        let download: URL
    }

    enum State: Equatable {
        case idle, checking, upToDate, available, downloading(Double), installing, failed(String)
    }

    var state: State = .idle
    var release: Release?

    var currentVersion: String { Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0" }

    /// Nouveautés de la version installée, lues dans le CHANGELOG.md copié dans l'app.
    var currentNotes: String {
        guard let url = Bundle.main.url(forResource: "CHANGELOG", withExtension: "md"),
              let text = try? String(contentsOf: url, encoding: .utf8) else { return "" }
        var lines: [String] = [], inSection = false
        for line in text.components(separatedBy: "\n") {
            if line.hasPrefix("## ") { inSection = line.dropFirst(3).hasPrefix(currentVersion + " ") || line == "## " + currentVersion; continue }
            if inSection, !line.isEmpty { lines.append(line) }
        }
        return lines.joined(separator: "\n")
    }

    /// Regarde la dernière version publiée. `silently` : pas d'erreur affichée (vérification au lancement).
    func check(silently: Bool = false) async {
        state = .checking
        struct Response: Decodable {
            let tag_name: String
            let body: String?
            let assets: [Asset]
            struct Asset: Decodable { let name: String; let browser_download_url: URL }
        }
        guard let url = URL(string: "https://api.github.com/repos/\(Self.repository)/releases/latest"),
              let (data, _) = try? await URLSession.shared.data(from: url),
              let response = try? JSONDecoder().decode(Response.self, from: data),
              let asset = response.assets.first(where: { $0.name.hasSuffix(".zip") }) else {
            state = silently ? .idle : .failed("Impossible de lire les versions sur GitHub.")
            return
        }
        let version = response.tag_name.trimmingCharacters(in: CharacterSet(charactersIn: "vV"))
        guard version.isNewerVersion(than: currentVersion) else {
            release = nil
            state = silently ? .idle : .upToDate
            return
        }
        release = Release(version: version, notes: response.body ?? "", download: asset.browser_download_url)
        state = .available
    }

    /// Télécharge la nouvelle version, vérifie sa signature, remplace l'app et la relance.
    func install() async {
        guard let release else { return }
        state = .downloading(0)
        let result = await FileDownloader().download(release.download) { written, total in
            Task { @MainActor in if total > 0 { self.state = .downloading(Double(written) / Double(total)) } }
        }
        guard case let .success(zip) = result else { return fail("le téléchargement a échoué.") }

        state = .installing
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("PrepareDisk-update-\(UUID().uuidString)").path
        guard await Shell.run("/usr/bin/ditto", ["-x", "-k", zip.path, folder]).status == 0,
              let name = (try? FileManager.default.contentsOfDirectory(atPath: folder))?.first(where: { $0.hasSuffix(".app") }) else {
            return fail("l'archive est illisible.")
        }
        let newApp = folder + "/" + name
        // "-R=…" : exigence écrite en toutes lettres (le "=" initial).
        guard await Shell.run("/usr/bin/codesign", ["--verify", "--deep", "--strict", "-R=" + Self.requirement, newApp]).status == 0 else {
            return fail("la signature de la nouvelle version n'est pas la bonne.")
        }

        let current = Bundle.main.bundlePath
        do {
            _ = try await NSWorkspace.shared.recycle([URL(fileURLWithPath: current)])
            try FileManager.default.moveItem(atPath: newApp, toPath: current)
        } catch {
            return fail("impossible de remplacer l'app (\(error.localizedDescription)).")
        }
        // Relance une fois cette instance fermée.
        let relaunch = Process()
        relaunch.executableURL = URL(fileURLWithPath: "/bin/sh")
        relaunch.arguments = ["-c", "sleep 1; /usr/bin/open \(Shell.quote(current))"]
        try? relaunch.run()
        NSApp.terminate(nil)
    }

    private func fail(_ reason: String) {
        state = .failed("Mise à jour impossible : \(reason)")
    }
}
