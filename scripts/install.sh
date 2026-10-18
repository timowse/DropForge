#!/bin/zsh
# Installs dist/DropForge.app into /Applications (replacing an older DropForge only). Not added to login items.
set -euo pipefail
ROOT=${0:A:h:h}
SRC="$ROOT/dist/DropForge.app"
DST=/Applications/DropForge.app
[[ -d "$SRC" ]] || { echo "build the app first" >&2; exit 1; }
if [[ -d "$DST" ]]; then
  ID=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$DST/Contents/Info.plist" 2>/dev/null || true)
  [[ "$ID" == "local.timo.DropForge" ]] || { echo "refusing to replace a different app at $DST ($ID)" >&2; exit 1; }
  pkill -x DropForge 2>/dev/null || true
  sleep 1
  rm -rf "$DST"
fi
ditto "$SRC" "$DST"
codesign --verify --strict "$DST"
/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -f "$DST"
/System/Library/CoreServices/pbs -update
echo "installed $DST"
