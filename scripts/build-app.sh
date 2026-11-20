#!/bin/bash
# Builds the replay window (app/) against mbui (libs/mbui) and still.fail's component library (libs/sf-ui, @sf)
# via libs/mbui/scripts/win.sh. Run in Git Bash with MSVC's environment (scripts/build.ps1 sets it up) and MoonBit on
# PATH or in MBUI_TOOLS (a directory holding moon/).
set -e -o pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
MODE=${MODE:-release}
# (a Windows path would break PATH at its drive colon: env.sh puts it there)
[ -z "${MBUI_TOOLS:-}" ] || export MBUI_TOOLS="$(cygpath -u "$MBUI_TOOLS")"
"$ROOT/scripts/fetch-stillfail.sh"

APPMOD="$ROOT/out/appmod"
rm -rf "$APPMOD"
mkdir -p "$APPMOD/src/replay"
cat > "$APPMOD/moon.mod" << 'EOF'
name = "screenreplay"
version = "0.1.0"
source = "src"
preferred_target = "native"
warnings = "@a-33-79-29"

import {
  "mbui@0.1.0",
  "stillfail/sf@0.1.0",
}
EOF
cat > "$APPMOD/moon.work" << 'EOF'
members = [
  ".",
  "../../deps/stillfail/libs/mbui",
  "../../deps/stillfail/libs/sf-ui",
]
EOF
cp "$ROOT"/app/* "$APPMOD/src/replay/"

cd "$ROOT/deps/stillfail/libs/mbui"
# the window's icon (assets/replay.rc) compiled to a .res for its link
RES="$ROOT/out/replay.res"
mkdir -p "$ROOT/out"
(cd "$ROOT/assets" && rc.exe -nologo -fo "$(cygpath -w "$RES")" replay.rc)
rm -f "out/win/app/_build/native/$MODE/build/screenreplay/replay/replay.exe"
set +e
MBUI_WIN_RES="$RES" MODE=$MODE MBUI_APP_MOD="$APPMOD" APP=replay scripts/win.sh build > "$ROOT/out/build-app.log" 2>&1
code=$?
set -e
grep -v "mbc: as is" "$ROOT/out/build-app.log" | grep -E "error|Error|E[0-9]{4}]|linked|mbc: " | grep -v "Warning" | tail -20 || true
if [ $code -ne 0 ]; then
  echo "build-app.sh: FAILED ($code), full log in out/build-app.log" >&2
  exit $code
fi
cp "out/win/app/_build/native/$MODE/build/screenreplay/replay/replay.exe" "$ROOT/out/ScreenReplayViewer.exe"
(cd "$ROOT" && git rev-parse --short HEAD > out/build.txt)
echo "build-app.sh: $ROOT/out/ScreenReplayViewer.exe"
