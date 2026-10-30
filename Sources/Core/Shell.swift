import AppKit
import Foundation

/// Petites aides pour lancer des commandes système.
enum Shell {
    /// Lance une commande et renvoie son code de sortie et toute sa sortie.
    static func run(_ path: String, _ args: [String]) async -> (status: Int32, output: String) {
        var output = ""
        let status = await stream(path, args) { output += $0 }
        return (status, output)
    }

    /// Lance une commande et transmet sa sortie au fur et à mesure.
    /// `onStart` reçoit le processus, pour pouvoir l'arrêter.
    static func stream(_ path: String, _ args: [String],
                       onStart: ((Process) -> Void)? = nil,
                       onOutput: @escaping (String) -> Void) async -> Int32 {
        await withCheckedContinuation { continuation in
            let process = Process()
            let pipe = Pipe()
            process.executableURL = URL(fileURLWithPath: path)
            process.arguments = args
            process.standardOutput = pipe
            process.standardError = pipe
            let lock = NSLock()
            pipe.fileHandleForReading.readabilityHandler = { handle in
                let data = handle.availableData
                guard !data.isEmpty, let text = String(data: data, encoding: .utf8) else { return }
                lock.lock(); onOutput(text); lock.unlock()
            }
            process.terminationHandler = { process in
                pipe.fileHandleForReading.readabilityHandler = nil
                let rest = pipe.fileHandleForReading.readDataToEndOfFile()
                if let text = String(data: rest, encoding: .utf8), !text.isEmpty {
                    lock.lock(); onOutput(text); lock.unlock()
                }
                continuation.resume(returning: process.terminationStatus)
            }
            do {
                try process.run()
                onStart?(process)
            } catch {
                onOutput("Impossible de lancer \(path) : \(error.localizedDescription)\n")
                continuation.resume(returning: -1)
            }
        }
    }

    /// Lit un plist renvoyé par une commande (ex. `diskutil info -plist`).
    static func plist(_ path: String, _ args: [String]) async -> [String: Any]? {
        let result = await run(path, args)
        guard result.status == 0, let data = result.output.data(using: .utf8) else { return nil }
        return try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any]
    }

    /// Met une chaîne entre guillemets simples pour bash.
    static func quote(_ s: String) -> String {
        "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    /// Lance une commande bash en administrateur, avec sudo (comme l'ancien script dans Terminal).
    /// sudo garde Prepare Disk comme « app responsable » : son Accès complet au disque s'applique au script root.
    /// (Avec osascript « with administrator privileges », le script root en était privé : écriture refusée sur les disques externes.)
    /// Renvoie cancelled = true si l'utilisateur a annulé la demande.
    @MainActor
    static func runAsAdmin(_ command: String) async -> (cancelled: Bool, output: String) {
        var message = "Prepare Disk a besoin de votre mot de passe administrateur pour écrire sur le disque."
        while true {
            guard let password = askPassword(message) else { return (true, "") }
            if await sudo(["-v"], password: password).status == 0 {
                return (false, await sudo(["/bin/bash", "-c", command], password: password).output)
            }
            message = "Mot de passe incorrect. Réessayez."
        }
    }

    private static func sudo(_ args: [String], password: String) async -> (status: Int32, output: String) {
        await withCheckedContinuation { continuation in
            let process = Process()
            let input = Pipe(), output = Pipe()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/sudo")
            process.arguments = ["-S", "-k", "-p", ""] + args   // -S : mot de passe lu sur l'entrée standard
            process.standardInput = input
            process.standardOutput = output
            process.standardError = output
            process.terminationHandler = { process in
                let text = String(data: output.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
                continuation.resume(returning: (process.terminationStatus, text))
            }
            do {
                try process.run()
                input.fileHandleForWriting.write(Data((password + "\n").utf8))
                try? input.fileHandleForWriting.close()
            } catch {
                continuation.resume(returning: (-1, error.localizedDescription))
            }
        }
    }

    @MainActor
    private static func askPassword(_ message: String) -> String? {
        let alert = NSAlert()
        alert.messageText = "Mot de passe administrateur"
        alert.informativeText = message
        alert.addButton(withTitle: "OK")
        alert.addButton(withTitle: "Annuler")
        let field = NSSecureTextField(frame: NSRect(x: 0, y: 0, width: 240, height: 24))
        alert.accessoryView = field
        alert.window.initialFirstResponder = field
        NSApp.activate(ignoringOtherApps: true)
        return alert.runModal() == .alertFirstButtonReturn ? field.stringValue : nil
    }
}

// MARK: - Formats

extension Int64 {
    var fileSize: String { ByteCountFormatter.string(fromByteCount: self, countStyle: .file) }
}

extension String {
    /// Compare deux versions ("15.8.2" < "15.10").
    func isNewerVersion(than other: String) -> Bool {
        compare(other, options: .numeric) == .orderedDescending
    }
    var majorVersion: String { String(split(separator: ".").first ?? "") }
    /// Première version trouvée dans un nom de fichier ("iPad_Fall_2025_27.2_24B119_Restore.ipsw" → "27.2").
    var versionInName: String? {
        firstMatch(of: #/(\d+\.\d+(?:\.\d+)?)/#).map { String($0.1) }
    }
}

func formatDuration(_ seconds: TimeInterval) -> String {
    let f = DateComponentsFormatter()
    f.allowedUnits = seconds >= 3600 ? [.hour, .minute] : [.minute, .second]
    f.unitsStyle = .abbreviated
    return f.string(from: max(0, seconds)) ?? "–"
}

/// Taille totale d'un fichier ou d'un dossier.
func itemSize(_ path: String) -> Int64 {
    let fm = FileManager.default
    var isDir: ObjCBool = false
    guard fm.fileExists(atPath: path, isDirectory: &isDir) else { return 0 }
    if !isDir.boolValue {
        return (try? fm.attributesOfItem(atPath: path)[.size] as? Int64) ?? 0
    }
    var total: Int64 = 0
    let enumerator = fm.enumerator(at: URL(fileURLWithPath: path), includingPropertiesForKeys: [.totalFileAllocatedSizeKey])
    while let url = enumerator?.nextObject() as? URL {
        total += Int64((try? url.resourceValues(forKeys: [.totalFileAllocatedSizeKey]).totalFileAllocatedSize) ?? 0)
    }
    return total
}
