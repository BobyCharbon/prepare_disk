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
        return Self.notes(in: text, version: currentVersion)
    }

    /// Les lignes de la section « ## version — date » d'un CHANGELOG.
    static func notes(in changelog: String, version: String) -> String {
        var lines: [String] = [], inSection = false
        for line in changelog.components(separatedBy: "\n") {
            if line.hasPrefix("## ") { inSection = line.dropFirst(3).hasPrefix(version + " ") || line == "## " + version; continue }
            if inSection, !line.isEmpty { lines.append(line) }
        }
        return lines.joined(separator: "\n")
    }

    /// Regarde la dernière version publiée. `silently` : pas d'erreur affichée (vérification au lancement).
    func check(silently: Bool = false) async {
        state = .checking
        // Liens publics de GitHub (pas l'API, limitée à 60 requêtes par heure pour tous les Mac d'un même réseau) :
        // « releases/latest » redirige vers la page de la dernière version, dont l'adresse finit par « v1.2.3 ».
        var head = URLRequest(url: URL(string: "https://github.com/\(Self.repository)/releases/latest")!)
        head.httpMethod = "HEAD"
        head.cachePolicy = .reloadIgnoringLocalCacheData
        guard let (_, response) = try? await URLSession.shared.data(for: head),
              let tag = response.url?.lastPathComponent, tag.hasPrefix("v"),
              let download = URL(string: "https://github.com/\(Self.repository)/releases/download/\(tag)/PrepareDisk.zip") else {
            state = silently ? .idle : .failed("Impossible de lire les versions sur GitHub.")
            return
        }
        let version = String(tag.dropFirst())
        guard version.isNewerVersion(than: currentVersion) else {
            release = nil
            state = silently ? .idle : .upToDate
            return
        }
        // Les nouveautés : la section de cette version dans le CHANGELOG publié.
        var notes = ""
        if let url = URL(string: "https://raw.githubusercontent.com/\(Self.repository)/main/CHANGELOG.md"),
           let (data, _) = try? await URLSession.shared.data(from: url) {
            notes = Self.notes(in: String(decoding: data, as: UTF8.self), version: version)
        }
        release = Release(version: version, notes: notes, download: download)
        state = .available
    }

    /// Télécharge la nouvelle version, vérifie sa signature, remplace l'app et la relance.
    func install(relaunch: Bool = true) async {
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
        guard relaunch else { return }   // agent : la nouvelle version servira au prochain lancement
        // Relance une fois cette instance fermée.
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", "sleep 1; /usr/bin/open \(Shell.quote(current))"]
        try? process.run()
        NSApp.terminate(nil)
    }

    private func fail(_ reason: String) {
        state = .failed("Mise à jour impossible : \(reason)")
    }
}
