#!/bin/zsh
# Builds dist/DropForge.app (arm64, release) with bundled helpers, Sparkle, icon, licences and an ad-hoc signature.
set -euo pipefail
ROOT=${0:A:h:h}
cd "$ROOT"
VERSION=${VERSION:-1.0.0}
BUILD=${BUILD:-$(git rev-list --count HEAD 2>/dev/null || echo 1)}
APP="$ROOT/dist/DropForge.app"
C="$APP/Contents"

echo "==> swift build (release, arm64)"
swift build -c release --arch arm64 --product DropForge
BIN=$(swift build -c release --arch arm64 --show-bin-path)/DropForge
lipo -archs "$BIN" | grep -qx arm64

echo "==> assembling bundle"
rm -rf "$APP"
mkdir -p "$C/MacOS" "$C/Resources/Licenses" "$C/Helpers" "$C/Frameworks"
cp "$BIN" "$C/MacOS/DropForge"
ditto Vendor/Sparkle/Sparkle.xcframework/macos-arm64_x86_64/Sparkle.framework "$C/Frameworks/Sparkle.framework"
install_name_tool -add_rpath @executable_path/../Frameworks "$C/MacOS/DropForge"
sed -e "s/__VERSION__/$VERSION/" -e "s/__BUILD__/$BUILD/" Resources/Info.plist > "$C/Info.plist"
plutil -lint "$C/Info.plist" >/dev/null
printf 'APPL????' > "$C/PkgInfo"
cp Resources/THIRD_PARTY_NOTICES.md "$C/Resources/"

echo "==> icon"
ICONSET=$(mktemp -d)/AppIcon.iconset
swift scripts/make_icon.swift "$ICONSET" >/dev/null
iconutil -c icns "$ICONSET" -o "$C/Resources/AppIcon.icns"

echo "==> helpers"
FF=${FFMPEG:-/opt/homebrew/bin/ffmpeg}; FP=${FFPROBE:-/opt/homebrew/bin/ffprobe}; CW=${CWEBP:-/opt/homebrew/bin/cwebp}
/usr/bin/python3 -I scripts/bundle_helpers.py "$C/Helpers" "$C/Resources/Licenses" "$FF" "$FP" "$CW"
env -i "$C/Helpers/ffmpeg" -hide_banner -version | head -1
env -i "$C/Helpers/ffprobe" -hide_banner -version | head -1
env -i "$C/Helpers/cwebp" -version

echo "==> signing (ad-hoc, nested code inside-out)"
# Do not enable hardened-runtime library validation for an ad-hoc build: separate
# ad-hoc CodeDirectories have no common Team ID. Developer ID releases should
# sign every component with the same real identity and may enable the runtime.
SPARKLE="$C/Frameworks/Sparkle.framework/Versions/B"
codesign --force --sign - --timestamp=none "$SPARKLE/XPCServices/Downloader.xpc"
codesign --force --sign - --timestamp=none "$SPARKLE/XPCServices/Installer.xpc"
codesign --force --sign - --timestamp=none "$SPARKLE/Updater.app"
codesign --force --sign - --timestamp=none "$SPARKLE/Autoupdate"
codesign --force --sign - --timestamp=none "$C/Frameworks/Sparkle.framework"
codesign --force --sign - --timestamp=none "$APP"
codesign --verify --deep --strict --verbose=2 "$APP" 2>&1 | tail -2
if find "$APP" -iname '*tangerine*' -o -iname '*reel*' -o -iname '*contact-sheet*' | grep -q .; then
  echo "reference material leaked into bundle" >&2; exit 1
fi
du -sh "$APP"
echo "built $APP"
