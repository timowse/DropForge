#!/bin/zsh
# Runs the Swift Testing suites with the Command Line Tools toolchain (no Xcode licence needed).
set -euo pipefail
ROOT=${0:A:h:h}
cd "$ROOT"
D=/Library/Developer/CommandLineTools/Library/Developer
swift test -Xswiftc -F$D/Frameworks -Xlinker -F$D/Frameworks -Xlinker -rpath -Xlinker $D/Frameworks \
  -Xlinker -rpath -Xlinker $D/usr/lib "$@"
