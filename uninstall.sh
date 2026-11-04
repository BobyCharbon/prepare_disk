#!/bin/bash
# Désinstallation complète de Prepare Disk : toutes les copies de l'app, l'agent de la barre des menus,
# l'assistant système, les réglages, les autorisations et les icônes du Dock.
# Les fichiers téléchargés (~/prepare_disk) sont gardés, sauf avec --all.
#   bash uninstall.sh [--all]
set -u
ID=com.bobycharbon.preparedisk
HELPER=/Library/PrivilegedHelperTools/$ID.helper
LSREGISTER=/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister
ALL=0; [ "${1:-}" = "--all" ] && ALL=1
ok() { echo "✓ $*"; }

echo "Désinstallation de Prepare Disk…"

# 1. L'agent ne doit plus être relancé, puis l'app et l'agent sont arrêtés.
launchctl bootout "gui/$(id -u)/$ID.agent" 2>/dev/null
pkill -x PrepareDisk; sleep 1; pkill -9 -x PrepareDisk
ok "agent et app arrêtés"

# 2. Toutes les copies de l'app : Applications, Téléchargements, ~/Applications, dossier temporaire…
apps=$( { mdfind "kMDItemCFBundleIdentifier == '$ID'" 2>/dev/null
          ls -d "/Applications/Prepare Disk.app" "$HOME/Applications/Prepare Disk.app" "$HOME/Downloads/Prepare Disk.app" \
                "${TMPDIR:-/tmp}"/PrepareDisk-update-*/*.app 2>/dev/null; } | sort -u)
while IFS= read -r app; do
    [ -n "$app" ] && [ -e "$app" ] || continue
    "$LSREGISTER" -u "$app/Contents/Library/LoginItems/Prepare Disk Agent.app" 2>/dev/null
    "$LSREGISTER" -u "$app" 2>/dev/null
    rm -rf "$app" 2>/dev/null && ok "supprimé : $app"
done <<< "$apps"
rm -rf "${TMPDIR:-/tmp}"/PrepareDisk-update-* "$HOME"/Downloads/PrepareDisk*.zip 2>/dev/null

# 3. Partie administrateur : par l'assistant (sans mot de passe), sinon avec sudo depuis le Terminal.
if sudo -n "$HELPER" uninstall 2>/dev/null; then
    ok "assistant système, autorisations et app de /Applications supprimés"
elif [ -e "/Applications/Prepare Disk.app" ] || [ -e "$HELPER" ] || [ -e /etc/sudoers.d/preparedisk ]; then
    if [ -t 0 ] && id -Gn | grep -qw admin; then
        echo "Mot de passe administrateur pour finir :"
        sudo /bin/sh -c "rm -rf '/Applications/Prepare Disk.app' '$HELPER' /etc/sudoers.d/preparedisk; tccutil reset All $ID" \
            && ok "assistant système, autorisations et app de /Applications supprimés"
    else
        echo "⚠ Il faut un administrateur pour supprimer : /Applications/Prepare Disk.app, $HELPER, /etc/sudoers.d/preparedisk"
    fi
fi

# 4. Réglages, caches, état des téléchargements, jeton administrateur, autorisations de l'utilisateur.
defaults delete "$ID" 2>/dev/null
defaults delete "$ID.agent" 2>/dev/null   # l'agent a ses propres préférences
rm -rf "$HOME/Library/Application Support/PrepareDisk" \
       "$HOME/Library/Preferences/$ID.plist" "$HOME/Library/Preferences/$ID.agent.plist" \
       "$HOME/Library/Caches/$ID" \
       "$HOME/Library/HTTPStorages/$ID" \
       "$HOME/Library/Saved Application State/$ID.savedState"
tccutil reset All "$ID" >/dev/null 2>&1
tccutil reset All "$ID.agent" >/dev/null 2>&1
killall cfprefsd 2>/dev/null
ok "réglages et autorisations supprimés"

# 5. Icônes du Dock.
dock="$HOME/Library/Preferences/com.apple.dock.plist"
count=$(/usr/libexec/PlistBuddy -c "Print :persistent-apps" "$dock" 2>/dev/null | grep -c "tile-data")
removed=0
for ((i = count - 1; i >= 0; i--)); do
    if [ "$(/usr/libexec/PlistBuddy -c "Print :persistent-apps:$i:tile-data:bundle-identifier" "$dock" 2>/dev/null)" = "$ID" ]; then
        /usr/libexec/PlistBuddy -c "Delete :persistent-apps:$i" "$dock" && removed=1
    fi
done
[ $removed = 1 ] && killall Dock && ok "icône retirée du Dock"

# 6. Fichiers téléchargés, seulement sur demande.
if [ $ALL = 1 ]; then
    rm -rf "$HOME/prepare_disk" && ok "fichiers téléchargés supprimés (~/prepare_disk)"
else
    echo "Les fichiers téléchargés sont gardés dans ~/prepare_disk (relancer avec --all pour les supprimer)."
fi
echo "Prepare Disk est désinstallé."
