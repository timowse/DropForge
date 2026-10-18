#!/bin/zsh
# Produces Sparkle-signed release assets without publishing them.
set -euo pipefail
ROOT=${0:A:h:h}
cd "$ROOT"
VERSION=${VERSION:-1.0.0}
KEY=${SPARKLE_PRIVATE_KEY:-$HOME/.config/dropforge/sparkle_ed25519_private_key}
APP="$ROOT/dist/DropForge.app"
ZIP="$ROOT/dist/DropForge-$VERSION-arm64.zip"
DMG="$ROOT/dist/DropForge-$VERSION-arm64.dmg"
FEED="$ROOT/dist/appcast.xml"
[[ -d "$APP" ]] || { print -u2 "build the app first"; exit 1; }
[[ -f "$KEY" ]] || { print -u2 "missing Sparkle private key"; exit 1; }
[[ $(stat -f %Lp "$KEY") == 600 ]] || { print -u2 "Sparkle private key must have mode 0600"; exit 1; }
rm -f "$ZIP" "$FEED" "$ROOT/dist/checksums.sha256"
ditto -c -k --sequesterRsrc --keepParent "$APP" "$ZIP"
SIGNATURE=$(Vendor/Sparkle/bin/sign_update --ed-key-file "$KEY" "$ZIP")
ED=$(print -r -- "$SIGNATURE" | sed -n 's/.*sparkle:edSignature="\([^"]*\)".*/\1/p')
LEN=$(print -r -- "$SIGNATURE" | sed -n 's/.*length="\([0-9]*\)".*/\1/p')
[[ -n "$ED" && -n "$LEN" ]] || { print -u2 "could not parse Sparkle signature"; exit 1; }
cat > "$FEED" <<EOF
<?xml version="1.0" encoding="utf-8"?>
<rss version="2.0" xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle">
  <channel>
    <title>DropForge Updates</title>
    <link>https://github.com/timowse/DropForge/releases/latest/download/appcast.xml</link>
    <description>Signed DropForge releases</description>
    <language>en</language>
    <item>
      <title>DropForge $VERSION</title>
      <pubDate>$(LC_ALL=C date -R)</pubDate>
      <sparkle:version>$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$APP/Contents/Info.plist")</sparkle:version>
      <sparkle:shortVersionString>$VERSION</sparkle:shortVersionString>
      <description><![CDATA[Initial DropForge release.]]></description>
      <enclosure url="https://github.com/timowse/DropForge/releases/download/v$VERSION/DropForge-$VERSION-arm64.zip"
        length="$LEN" type="application/octet-stream" sparkle:edSignature="$ED" />
    </item>
  </channel>
</rss>
EOF
Vendor/Sparkle/bin/sign_update --ed-key-file "$KEY" "$FEED" >/dev/null
Vendor/Sparkle/bin/sign_update --verify --ed-key-file "$KEY" "$ZIP" "$ED"
Vendor/Sparkle/bin/sign_update --verify --ed-key-file "$KEY" "$FEED"
[[ -f "$DMG" ]] || VERSION="$VERSION" scripts/make-dmg.sh
(cd dist && shasum -a 256 "DropForge-$VERSION-arm64.zip" "DropForge-$VERSION-arm64.dmg" appcast.xml > checksums.sha256)
print "created signed release assets in $ROOT/dist"
