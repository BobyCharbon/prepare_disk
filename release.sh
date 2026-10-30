#!/bin/bash
# Publie une nouvelle version : ./release.sh 1.2.0
# GitHub compile et publie l'app ; chaque Mac l'installe à son prochain lancement.
set -e
cd "$(dirname "$0")"
VERSION="$1"
[[ "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || { echo "Usage : ./release.sh 1.2.0"; exit 1; }
grep -q "^## $VERSION " CHANGELOG.md || { echo "Ajoute d'abord dans CHANGELOG.md : ## $VERSION — date, puis ce qui change."; exit 1; }
echo "$VERSION" > VERSION
git add VERSION CHANGELOG.md
git commit -m "Version $VERSION"
git tag "v$VERSION"
git push origin HEAD "v$VERSION"
echo "Version $VERSION envoyée : https://github.com/BobyCharbon/prepare_disk/actions"
