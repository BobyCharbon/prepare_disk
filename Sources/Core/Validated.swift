import Foundation
import Observation
import CryptoKit
import IOKit

/// Versions validées, publiées dans le dépôt (validated-versions.json) et suivies par tous les Mac.
/// "" = automatique : la version du macOS pour l'IPSW Mac, la dernière signée pour un iPad.
struct ValidatedVersions: Codable, Equatable {
    var updated: String
    var macOS: [String]
    var macIPSW: [String]
    var iPad: [String: String]   // identifiant (ex. iPad13,18) → version

    /// Les versions actuellement réglées sur ce Mac.
    @MainActor
    init(from settings: AppSettings) {
        let day = DateFormatter()
        day.dateFormat = "yyyy-MM-dd"
        updated = day.string(from: Date())
        macOS = settings.selected
        macIPSW = settings.macIPSWVersions
        iPad = Dictionary(settings.devices.map { ($0.identifier, $0.version ?? "") }, uniquingKeysWith: { a, _ in a })
    }

    /// Mêmes versions (la date ne compte pas).
    func sameVersions(as other: ValidatedVersions) -> Bool {
        macOS == other.macOS && macIPSW == other.macIPSW && iPad == other.iPad
    }
}

/// Lit la liste publiée, l'applique à ce Mac et, en mode administrateur, la publie.
@MainActor
@Observable
final class ValidatedStore {
    static let path = "validated-versions.json"
    private let defaults = UserDefaults.app

    /// Dernière liste publiée connue (gardée hors connexion).
    var published: ValidatedVersions? {
        didSet { defaults.set(try? JSONEncoder().encode(published), forKey: "validatedVersions") }
    }
    var lastCheck: Date?
    var error: String?
    var isPublishing = false
    /// Un jeton GitHub avec droit d'écriture est enregistré dans le trousseau.
    var hasToken: Bool { didSet { defaults.set(hasToken, forKey: "adminHasToken") } }
    /// Interrupteur du mode administrateur (en un clic, une fois le jeton enregistré).
    var adminMode: Bool { didSet { defaults.set(adminMode, forKey: "adminMode") } }
    /// Mode administrateur : on choisit librement ses versions, et on peut les publier pour tous.
    var isAdmin: Bool { hasToken && adminMode }

    init() {
        published = defaults.data(forKey: "validatedVersions").flatMap { try? JSONDecoder().decode(ValidatedVersions.self, from: $0) }
        // Pas de lecture du trousseau au démarrage (macOS demanderait le mot de passe de session) :
        // on retient seulement qu'un jeton est enregistré, il n'est lu qu'au moment de publier.
        hasToken = Keychain.read() != nil
        adminMode = defaults.bool(forKey: "adminMode")
    }

    private func request(_ method: String = "GET", accept: String = "application/vnd.github+json") -> URLRequest {
        var request = URLRequest(url: URL(string: "https://api.github.com/repos/\(Updater.repository)/contents/\(Self.path)")!)
        request.httpMethod = method
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.setValue(accept, forHTTPHeaderField: "Accept")
        if method != "GET", let token = Keychain.read() { request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
        return request
    }

    /// Relit la liste publiée. Renvoie true si elle a changé.
    @discardableResult
    func fetch() async -> Bool {
        // Fichier public (pas l'API GitHub, limitée par adresse IP) ; jeton inutile pour lire.
        var get = URLRequest(url: URL(string: "https://raw.githubusercontent.com/\(Updater.repository)/main/\(Self.path)")!)
        get.cachePolicy = .reloadIgnoringLocalCacheData
        guard let (data, response) = try? await URLSession.shared.data(for: get),
              (response as? HTTPURLResponse)?.statusCode == 200,
              let list = try? JSONDecoder().decode(ValidatedVersions.self, from: data) else {
            error = "Impossible de lire les versions validées (hors ligne ?)."
            return false
        }
        error = nil
        lastCheck = Date()
        let changed = published.map { !$0.sameVersions(as: list) } ?? true
        published = list
        return changed
    }

    /// Applique la liste publiée aux réglages de ce Mac.
    func apply(to settings: AppSettings) {
        guard let list = published else { return }
        settings.selected = Array((list.macOS + ["", "", ""]).prefix(3))
        settings.macIPSWVersions = Array((list.macIPSW + ["", "", ""]).prefix(3))
        for index in settings.devices.indices {
            if let version = list.iPad[settings.devices[index].identifier] {
                settings.devices[index].version = version.isEmpty ? nil : version
            }
        }
    }

    // MARK: Administration

    /// Vérifie le jeton (droit d'écriture sur le dépôt) et l'enregistre dans le trousseau.
    func enableAdmin(token: String) async -> String? {
        var check = URLRequest(url: URL(string: "https://api.github.com/repos/\(Updater.repository)")!)
        check.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        struct Repo: Decodable { struct Permissions: Decodable { let push: Bool }; let permissions: Permissions? }
        guard let (data, _) = try? await URLSession.shared.data(for: check),
              let repo = try? JSONDecoder().decode(Repo.self, from: data) else { return "GitHub injoignable ou jeton invalide." }
        guard repo.permissions?.push == true else { return "Ce jeton n'a pas le droit de modifier le dépôt." }
        Keychain.save(token)
        hasToken = true
        adminMode = true
        return nil
    }

    /// Oublie le jeton (ce Mac ne pourra plus publier).
    func forgetToken() {
        Keychain.delete()
        hasToken = false
        adminMode = false
    }

    /// Publie les versions réglées sur ce Mac pour tous les Mac.
    func publish(_ list: ValidatedVersions) async -> String? {
        isPublishing = true
        defer { isPublishing = false }
        // SHA du fichier actuel (obligatoire pour le remplacer).
        struct Current: Decodable { let sha: String }
        var sha: String?
        if let (data, response) = try? await URLSession.shared.data(for: request()),
           (response as? HTTPURLResponse)?.statusCode == 200 {
            sha = (try? JSONDecoder().decode(Current.self, from: data))?.sha
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let json = try? encoder.encode(list) else { return "Liste illisible." }
        var body: [String: Any] = ["message": "Versions validées du \(list.updated)", "content": json.base64EncodedString(), "branch": "main"]
        if let sha { body["sha"] = sha }
        var put = request("PUT")
        put.httpBody = try? JSONSerialization.data(withJSONObject: body)
        guard let (_, response) = try? await URLSession.shared.data(for: put),
              let status = (response as? HTTPURLResponse)?.statusCode, (200...201).contains(status) else {
            return "La publication a échoué (jeton expiré ?)."
        }
        published = list
        return nil
    }
}

/// Le jeton GitHub de l'administrateur, chiffré (AES-GCM) dans un fichier caché, lisible par ce compte seulement.
/// Pas de trousseau : macOS y redemandait le mot de passe de session après chaque mise à jour de l'app.
/// La clé vient de l'identifiant matériel de ce Mac : le fichier copié ailleurs est illisible.
enum Keychain {
    private static let file = URL(fileURLWithPath: NSHomeDirectory() + "/Library/Application Support/PrepareDisk/.admin-token")

    private static var key: SymmetricKey {
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("IOPlatformExpertDevice"))
        defer { IOObjectRelease(service) }
        let uuid = IORegistryEntryCreateCFProperty(service, "IOPlatformUUID" as CFString, kCFAllocatorDefault, 0)?
            .takeRetainedValue() as? String ?? ""
        return SymmetricKey(data: SHA256.hash(data: Data((uuid + "|com.bobycharbon.preparedisk").utf8)))
    }

    static func read() -> String? {
        guard let data = try? Data(contentsOf: file),
              let box = try? AES.GCM.SealedBox(combined: data),
              let plain = try? AES.GCM.open(box, using: key) else { return nil }
        return String(data: plain, encoding: .utf8)
    }

    static func save(_ token: String) {
        guard let sealed = try? AES.GCM.seal(Data(token.utf8), using: key).combined else { return }
        try? FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? sealed.write(to: file, options: [.atomic, .completeFileProtection])
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
    }

    static func delete() {
        try? FileManager.default.removeItem(at: file)
    }
}
