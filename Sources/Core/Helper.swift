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
    static let version = "1"

    var isReady = false
    var isInstalling = false
    var error: String?

    /// L'assistant est installé, à jour, et utilisable sans mot de passe.
    func check() async {
        let result = await Shell.run("/usr/bin/sudo", ["-n", Self.path, "version"])
        isReady = result.status == 0 && result.output.trimmingCharacters(in: .whitespacesAndNewlines) == Self.version
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
    nonisolated static let script = #"""
    #!/bin/bash
    # Assistant de Prepare Disk : seules ces opérations sont permises en root, sans mot de passe.
    set -u
    PATH=/usr/bin:/bin:/usr/sbin:/sbin
    refuse() { echo "Assistant : refusé ($*)" >&2; exit 2; }
    # Disque ou volume externe et physique uniquement (jamais le disque interne).
    external() {
        local info
        info=$(diskutil info -plist "$1" 2>/dev/null) || return 1
        [ "$(plutil -extract Internal raw -o - - <<<"$info" 2>/dev/null)" = "false" ]
    }
    # Installateur macOS dont createinstallmedia est signé par Apple.
    installer() {
        [[ "$(basename "$1")" == Install\ macOS*.app ]] || return 1
        codesign --verify -R="anchor apple" "$1/Contents/Resources/createinstallmedia" 2>/dev/null
    }

    case "${1:-}" in
        version)
            echo 1 ;;
        erase)
            disk="${2:-}"
            [[ "$disk" =~ ^disk[0-9]+$ ]] && external "$disk" || refuse "disque $disk"
            shift 2
            diskutil unmountDisk force "/dev/$disk"
            exec diskutil partitionDisk "/dev/$disk" GPT "$@" ;;
        createinstallmedia)
            app="${2:-}"; volume="${3:-}"
            installer "$app" || refuse "installateur $app"
            [[ "$volume" == /Volumes/* ]] && external "$volume" || refuse "volume $volume"
            exec "$app/Contents/Resources/createinstallmedia" --volume "$volume" --nointeraction ;;
        rename)
            part="${2:-}"
            [[ "$part" =~ ^disk[0-9]+s[0-9]+$ ]] && external "$part" || refuse "partition $part"
            exec diskutil rename "$part" "${3:-}" ;;
        move)
            src="${2:-}"; dst="${3:-}"
            [[ "$(basename "$src")" == Install\ macOS*.app && "$(basename "$dst")" == Install\ macOS*.app ]] || refuse "déplacement"
            [[ "$src" == /Applications/* || "$src" == /Users/* ]] && [[ "$dst" == /Users/* ]] || refuse "déplacement"
            mkdir -p "$(dirname "$dst")"
            exec mv -n "$src" "$dst" ;;
        *)
            refuse "commande ${1:-}" ;;
    esac
    """#
}
