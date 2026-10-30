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
# Certificat fixe : macOS garde l'Accès complet au disque d'une version à l'autre.
# Sans lui (autre Mac), signature ad hoc : l'autorisation est à redonner après chaque build.
IDENTITY="Prepare Disk"
if security find-identity -p codesigning | grep -q "\"$IDENTITY\""; then
    codesign --force --sign "$IDENTITY" "$APP"
else
    echo "ATTENTION : certificat « $IDENTITY » absent du trousseau, signature ad hoc."
    codesign --force --sign - "$APP"
fi
# Toujours une copie zippée, prête à distribuer (c'est elle que publie GitHub).
# PrepareDisk.zip (lien fixe « dernière version ») et PrepareDisk-<version>.zip.
rm -f PrepareDisk*.zip
ditto -c -k --keepParent "$APP" PrepareDisk.zip
cp PrepareDisk.zip "PrepareDisk-$VERSION.zip"
echo "OK : $(pwd)/$APP (v$VERSION)"
echo "OK : $(pwd)/PrepareDisk.zip et PrepareDisk-$VERSION.zip"
