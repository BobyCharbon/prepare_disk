import AppKit
import Foundation
import Observation

/// Mises à jour de l'app depuis les versions publiées sur GitHub (dépôt public).
@MainActor
@Observable
final class Updater {
    static let repository = "BobyCharbon/prepare_disk"
    /// Seule une app signée avec notre certificat est installée (et garde l'Accès complet au disque).
    /// Accepte l'app signée Developer ID (équipe GS2B6GA9JA) ou, pendant la transition, l'ancien certificat « Prepare Disk ».
    static let requirement = #"identifier "com.bobycharbon.preparedisk" and (anchor apple generic and certificate leaf[subject.OU] = "GS2B6GA9JA" or certificate root = H"2a4993ddca84b3ae2874dce2ef7cd304c3947083")"#

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
    /// Pour remplacer l'app quand on n'a pas le droit de le faire soi-même (compte standard, /Applications).
    var helper: Helper?

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
        await Self.removeLeftovers()
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

        var current = Bundle.main.bundlePath
        if !Self.replace(current, with: newApp) {
            // Pas le droit d'écrire ici : l'assistant système (sans mot de passe) s'en charge.
            if let helper, helper.isReady, await helper.run(["update", newApp, current]).status == 0 {
            } else if let copy = Self.installForUser(newApp) {
                // Pas d'administrateur : la nouvelle version va dans ~/Applications, et l'ancienne y renvoie.
                current = copy
            } else {
                return fail("impossible de remplacer l'app (droits insuffisants). Faites la « Configuration unique », ou installez la nouvelle version à la main.")
            }
        }
        await Self.removeLeftovers()
        guard relaunch else { return }   // agent : la nouvelle version servira au prochain lancement
        Self.relaunch(current)
    }

    /// Relance l'app une fois cette instance fermée.
    static func relaunch(_ path: String = Bundle.main.bundlePath) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", "sleep 1; /usr/bin/open \(Shell.quote(path))"]
        try? process.run()
        NSApp.terminate(nil)
    }

    /// Supprime les versions téléchargées restées dans le dossier temporaire (une par essai raté) et les retire
    /// de la liste des apps de macOS : sinon elles s'empilent dans le Launchpad et « Ouvrir avec ».
    private static func removeLeftovers() async {
        let tmp = FileManager.default.temporaryDirectory
        let folders = (try? FileManager.default.contentsOfDirectory(atPath: tmp.path))?.filter { $0.hasPrefix("PrepareDisk-update-") } ?? []
        for name in folders {
            let folder = tmp.appendingPathComponent(name).path
            for app in (try? FileManager.default.contentsOfDirectory(atPath: folder)) ?? [] where app.hasSuffix(".app") {
                _ = await Shell.run("/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister",
                                    ["-u", folder + "/" + app])
            }
            try? FileManager.default.removeItem(atPath: folder)
        }
    }

    /// Remplace l'app sur place ; l'ancienne version est supprimée (pas mise à la corbeille). Remise en place si échec.
    private static func replace(_ current: String, with newApp: String) -> Bool {
        let fm = FileManager.default
        let old = (current as NSString).deletingLastPathComponent + "/.Prepare Disk.old.app"
        try? fm.removeItem(atPath: old)
        do {
            try fm.moveItem(atPath: current, toPath: old)
        } catch {
            return false
        }
        do {
            try fm.moveItem(atPath: newApp, toPath: current)
            try? fm.removeItem(atPath: old)
            return true
        } catch {
            try? fm.moveItem(atPath: old, toPath: current)
            return false
        }
    }

    /// Copie de l'app dans le dossier Applications de l'utilisateur, toujours modifiable sans mot de passe.
    nonisolated static let userCopy = NSHomeDirectory() + "/Applications/Prepare Disk.app"

    private static func installForUser(_ newApp: String) -> String? {
        let fm = FileManager.default
        guard Bundle.main.bundlePath != userCopy else { return nil }
        try? fm.createDirectory(atPath: (userCopy as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
        try? fm.removeItem(atPath: userCopy)
        return (try? fm.moveItem(atPath: newApp, toPath: userCopy)) != nil ? userCopy : nil
    }

    /// Une version plus récente attend dans ~/Applications (mise à jour faite sans administrateur).
    nonisolated static var newerUserCopy: String? {
        guard Bundle.main.bundlePath != userCopy,
              let version = Bundle(path: userCopy)?.infoDictionary?["CFBundleShortVersionString"] as? String,
              let mine = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String,
              version.isNewerVersion(than: mine) else { return nil }
        return userCopy
    }

    private func fail(_ reason: String) {
        state = .failed("Mise à jour impossible : \(reason)")
    }
}
