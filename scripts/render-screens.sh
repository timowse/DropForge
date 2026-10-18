#!/bin/zsh
# Renders application screens offscreen for visual review (fixtures are generated in a temporary folder).
set -euo pipefail
ROOT=${0:A:h:h}
cd "$ROOT"
swift build --product DropForge >/dev/null
OUT=${1:-$ROOT/artifacts/screens}
rm -rf "$OUT"
.build/debug/DropForge --render-screens "$OUT" & P=$!
for i in {1..180}; do kill -0 $P 2>/dev/null || break; sleep 1; done
if kill -0 $P 2>/dev/null; then kill $P; echo "render timed out" >&2; exit 1; fi
wait $P
