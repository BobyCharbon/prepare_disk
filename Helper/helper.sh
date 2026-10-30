#!/bin/bash
# Assistant de Prepare Disk : seules ces opérations sont permises en root, sans mot de passe.
# Installé une fois (mot de passe administrateur), il se met ensuite à jour tout seul depuis l'app signée.
HELPER_VERSION=3
HELPER=/Library/PrivilegedHelperTools/com.bobycharbon.preparedisk.helper
TEAM='identifier "com.bobycharbon.preparedisk" and anchor apple generic and certificate leaf[subject.OU] = "GS2B6GA9JA"'
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
        echo "$HELPER_VERSION" ;;
    selfupdate)
        # Nouvelle version de l'assistant, prise dans une app signée par l'équipe : copiée d'abord (root),
        # puis l'app est vérifiée, puis la copie doit être identique au fichier signé.
        app="${2:-}"
        [[ "$(basename "$app")" == "Prepare Disk.app" ]] || refuse "app $app"
        tmp=$(mktemp /tmp/preparedisk-helper.XXXXXX) || refuse "copie"
        cp "$app/Contents/Resources/helper.sh" "$tmp" || { rm -f "$tmp"; refuse "copie"; }
        codesign --verify --deep --strict -R="$TEAM" "$app" || { rm -f "$tmp"; refuse "signature"; }
        cmp -s "$tmp" "$app/Contents/Resources/helper.sh" || { rm -f "$tmp"; refuse "fichier modifié"; }
        install -o root -g wheel -m 755 "$tmp" "$HELPER"; rm -f "$tmp"
        exec "$HELPER" version ;;
    update)
        # Remplace l'app par sa nouvelle version, seulement si elle est signée par l'équipe de l'app.
        new="${2:-}"; dest="${3:-}"
        [[ "$(basename "$new")" == "Prepare Disk.app" && "$(basename "$dest")" == "Prepare Disk.app" ]] || refuse "mise à jour"
        [[ "$dest" == /Applications/* || "$dest" == /Users/* ]] || refuse "mise à jour"
        codesign --verify --deep --strict -R="$TEAM" "$new" || refuse "signature"
        rm -rf "$dest.old"
        [ -e "$dest" ] && mv "$dest" "$dest.old"
        if ditto "$new" "$dest"; then rm -rf "$dest.old"; else rm -rf "$dest"; mv "$dest.old" "$dest"; refuse "copie"; fi ;;
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
