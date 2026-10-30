#!/bin/bash
# Compile l'app et crée "Prepare Disk.app" à côté de ce script.
set -e
cd "$(dirname "$0")"
VERSION="${1:-$(cat VERSION)}"   # ./build_app.sh 1.2 ou le fichier VERSION
swift build -c release
APP="Prepare Disk.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
cp .build/release/PrepareDisk "$APP/Contents/MacOS/PrepareDisk"
mkdir -p "$APP/Contents/Resources" "$APP/Contents/Library/LaunchAgents"
cp LaunchAgents/*.plist "$APP/Contents/Library/LaunchAgents/"   # agent d'arrière-plan (téléchargement automatique)
cp CHANGELOG.md "$APP/Contents/Resources/CHANGELOG.md"
cp Helper/helper.sh "$APP/Contents/Resources/helper.sh"   # assistant système (se met à jour tout seul)
cp Icon/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"   # régénérer : swift Icon/make_icon.swift Icon/AppIcon.png
cat > "$APP/Contents/Info.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key><string>Prepare Disk</string>
    <key>CFBundleDisplayName</key><string>Prepare Disk</string>
    <key>CFBundleIdentifier</key><string>com.bobycharbon.preparedisk</string>
    <key>CFBundleExecutable</key><string>PrepareDisk</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>$VERSION</string>
    <key>CFBundleVersion</key><string>$VERSION</string>
    <key>LSMinimumSystemVersion</key><string>14.0</string>
    <key>NSHighResolutionCapable</key><true/>
    <key>NSRemovableVolumesUsageDescription</key><string>Prepare Disk écrit les installateurs macOS et les IPSW sur le disque externe.</string>
    <key>NSDownloadsFolderUsageDescription</key><string>Prepare Disk cherche les installateurs et IPSW déjà téléchargés.</string>
    <key>CFBundleDevelopmentRegion</key><string>fr</string>
    <key>CFBundleIconFile</key><string>AppIcon</string>
</dict>
</plist>
EOF
# Signature : Developer ID (app reconnue par macOS partout, notarisable), sinon le certificat « Prepare Disk »,
# sinon ad hoc. Un certificat fixe garde l'Accès complet au disque d'une version à l'autre.
DEVELOPER_ID=$(security find-identity -v -p codesigning | grep -o '"Developer ID Application: [^"]*"' | head -1 | tr -d '"')
if [ -n "$DEVELOPER_ID" ]; then
    # Runtime renforcé + horodatage : obligatoires pour la notarisation d'Apple.
    codesign --force --options runtime --timestamp --sign "$DEVELOPER_ID" "$APP"
elif security find-identity -p codesigning | grep -q '"Prepare Disk"'; then
    codesign --force --sign "Prepare Disk" "$APP"
else
    echo "ATTENTION : aucun certificat dans le trousseau, signature ad hoc."
    codesign --force --sign - "$APP"
fi
# Notarisation par Apple : une app téléchargée s'ouvre sans avertissement, et macOS accepte de lancer l'agent
# de la barre des menus (sinon il le tue : OS_REASON_CODESIGNING). Faite dès que la clé d'API est disponible
# (variables NOTARY_*, ou fichiers de ~/PrepareDisk_signing) ; NOTARIZE=0 pour s'en passer.
if [ -z "${NOTARIZE:-}" ] && ls ~/PrepareDisk_signing/AuthKey_*.p8 >/dev/null 2>&1; then NOTARIZE=1; fi
if [ "${NOTARIZE:-0}" = 1 ] && [ -n "$DEVELOPER_ID" ]; then
    KEY="${NOTARY_KEY_PATH:-$(ls ~/PrepareDisk_signing/AuthKey_*.p8 2>/dev/null | head -1)}"
    KEY_ID="${NOTARY_KEY_ID:-$(cat ~/PrepareDisk_signing/notary-key-id.txt 2>/dev/null)}"
    ISSUER="${NOTARY_ISSUER:-$(cat ~/PrepareDisk_signing/notary-issuer.txt 2>/dev/null)}"
    ditto -c -k --keepParent "$APP" notarize.zip
    xcrun notarytool submit notarize.zip --key "$KEY" --key-id "$KEY_ID" --issuer "$ISSUER" --wait | tee notarize.log
    rm -f notarize.zip
    grep -q "status: Accepted" notarize.log || { echo "ERREUR : notarisation refusée par Apple"; rm -f notarize.log; exit 1; }
    rm -f notarize.log
    # Le ticket met parfois quelques secondes à être disponible chez Apple : plusieurs essais.
    for i in 1 2 3 4 5; do xcrun stapler staple "$APP" && break; [ $i = 5 ] && exit 1; sleep 20; done
fi

# Toujours une copie zippée, prête à distribuer (c'est elle que publie GitHub).
# PrepareDisk.zip (lien fixe « dernière version ») et PrepareDisk-<version>.zip.
rm -f PrepareDisk*.zip
ditto -c -k --keepParent "$APP" PrepareDisk.zip
cp PrepareDisk.zip "PrepareDisk-$VERSION.zip"
echo "OK : $(pwd)/$APP (v$VERSION)"
echo "OK : $(pwd)/PrepareDisk.zip et PrepareDisk-$VERSION.zip"
