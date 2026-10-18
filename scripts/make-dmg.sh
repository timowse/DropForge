#!/bin/zsh
# Packs dist/DropForge.app into dist/DropForge-<version>.dmg (compressed, with an Applications link).
set -euo pipefail
ROOT=${0:A:h:h}
VERSION=${VERSION:-1.0.0}
APP="$ROOT/dist/DropForge.app"
DMG="$ROOT/dist/DropForge-$VERSION-arm64.dmg"
[[ -d "$APP" ]] || { echo "build the app first" >&2; exit 1; }
STAGE=$(mktemp -d)/DropForge
mkdir -p "$STAGE"
ditto "$APP" "$STAGE/DropForge.app"
ln -s /Applications "$STAGE/Applications"
cp "$ROOT/Resources/THIRD_PARTY_NOTICES.md" "$STAGE/"
rm -f "$DMG"
hdiutil create -volname "DropForge" -srcfolder "$STAGE" -fs HFS+ -format UDZO -imagekey zlib-level=9 -ov "$DMG" >/dev/null
hdiutil verify "$DMG" >/dev/null && echo "verified $DMG"
shasum -a 256 "$DMG"
