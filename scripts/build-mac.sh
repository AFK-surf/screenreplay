#!/bin/bash
# Builds the complete macOS ScreenReplay.app bundle:
#   - ScreenReplayViewer (Pion + Invar Metal/VideoToolbox + native/replay_*_mac.mm)
#   - ScreenReplay (Swift menu bar host & launcher)
#   - ScreenReplay Helper.app (standalone TCC-responsible ScreenCaptureKit + PermissionFlow helper)
set -euo pipefail

unset SDKROOT
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
MODE="${MODE:-release}"
RUN_TESTS="${RUN_TESTS:-0}"
for arg in "$@"; do
  case "$arg" in
    --test) RUN_TESTS=1 ;;
    *) echo "build-mac.sh: unknown option '$arg'" >&2; exit 1 ;;
  esac
done
VERSION="${VERSION:-$(sed -n 's/^let app_version : String = "\(.*\)"$/\1/p' "$ROOT/src/about.pion")}"
BUILD_NUM="${BUILD_NUM:-${VERSION##*.}}"

PIONC="${PIONC:-pionc}"
if ! command -v "$PIONC" >/dev/null 2>&1 && [ ! -x "$PIONC" ]; then
  echo "build-mac.sh: pionc not found (set PIONC or add pionc to PATH)" >&2
  exit 1
fi

OUT="$ROOT/out/mac"
mkdir -p "$OUT"
SHORT_SHA="$(git -C "$ROOT" rev-parse --short HEAD 2>/dev/null || echo dev)"
printf '%s\n' "$SHORT_SHA" > "$OUT/build.txt"

# 1-3. Run independent builds in parallel: AppIcon.icns, ScreenReplayViewer (Pion), and Swift Helper/Host
ICNS="$OUT/AppIcon.icns"
SWIFT_CFG="release"
if [ "$MODE" = "debug" ]; then
  SWIFT_CFG="debug"
fi

(
  if [ ! -f "$ICNS" ]; then
    ICONSET="$OUT/AppIcon.iconset"
    rm -rf "$ICONSET"
    mkdir -p "$ICONSET"
    swift - "$ROOT/assets/svg/icon-rec.svg" "$ROOT/site/img/icon.png" "$ICONSET" << 'SWIFT_EOF'
import AppKit
import Foundation

let svgPath = CommandLine.arguments[1]
let pngFallback = CommandLine.arguments[2]
let outDir = CommandLine.arguments[3]

guard let src = NSImage(contentsOfFile: svgPath) ?? NSImage(contentsOfFile: pngFallback) else {
  fputs("Failed to load icon source\n", stderr)
  exit(1)
}

let entries: [(String, Int)] = [
  ("icon_16x16.png", 16),
  ("icon_16x16@2x.png", 32),
  ("icon_32x32.png", 32),
  ("icon_32x32@2x.png", 64),
  ("icon_128x128.png", 128),
  ("icon_128x128@2x.png", 256),
  ("icon_256x256.png", 256),
  ("icon_256x256@2x.png", 512),
  ("icon_512x512.png", 512),
  ("icon_512x512@2x.png", 1024),
]

for (name, px) in entries {
  guard let rep = NSBitmapImageRep(
    bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px,
    bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
    colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
  ) else { exit(1) }
  NSGraphicsContext.saveGraphicsState()
  NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
  NSGraphicsContext.current?.imageInterpolation = .high
  src.draw(in: NSRect(x: 0, y: 0, width: px, height: px), from: .zero, operation: .copy, fraction: 1.0)
  NSGraphicsContext.restoreGraphicsState()
  guard let data = rep.representation(using: .png, properties: [:]) else { exit(1) }
  try data.write(to: URL(fileURLWithPath: "\(outDir)/\(name)"))
}
SWIFT_EOF
    iconutil -c icns "$ICONSET" -o "$ICNS"
    rm -rf "$ICONSET"
  fi
) &
PID_ICON=$!

(
  if [ "$RUN_TESTS" = "1" ]; then
    echo "build-mac.sh: running viewer regression tests..."
    (cd "$ROOT" && "$PIONC" test .)
  fi
  echo "build-mac.sh: building ScreenReplayViewer ($MODE)..."
  if [ "$MODE" = "release" ]; then
    (cd "$ROOT" && "$PIONC" build --release . -o "$OUT/ScreenReplayViewer")
  else
    (cd "$ROOT" && "$PIONC" build . -o "$OUT/ScreenReplayViewer")
  fi
  chmod +x "$OUT/ScreenReplayViewer"
) &
PID_VIEWER=$!

(
  echo "build-mac.sh: building Swift ScreenReplayHelper & ScreenReplayMac ($MODE)..."
  swift build -c "$SWIFT_CFG" --package-path "$ROOT/mac"
) &
PID_SWIFT=$!

FAIL=0
wait "$PID_ICON"   || { echo "build-mac.sh: AppIcon generation failed" >&2; FAIL=1; }
wait "$PID_VIEWER" || { echo "build-mac.sh: ScreenReplayViewer build failed" >&2; FAIL=1; }
wait "$PID_SWIFT"  || { echo "build-mac.sh: Swift build failed" >&2; FAIL=1; }
[ "$FAIL" -eq 0 ] || exit 1

SWIFT_BIN_DIR="$(swift build -c "$SWIFT_CFG" --package-path "$ROOT/mac" --show-bin-path)"

# 4. Assemble ScreenReplay.app with nested ScreenReplay Helper.app
APP_BUNDLE="$OUT/ScreenReplay.app"
HELPER_BUNDLE="$APP_BUNDLE/Contents/Helpers/ScreenReplay Helper.app"
rm -rf "$APP_BUNDLE"
mkdir -p \
  "$APP_BUNDLE/Contents/MacOS" \
  "$APP_BUNDLE/Contents/Resources/config" \
  "$HELPER_BUNDLE/Contents/MacOS" \
  "$HELPER_BUNDLE/Contents/Resources"

# Nested ScreenReplay Helper.app
cp "$SWIFT_BIN_DIR/ScreenReplayHelper" "$HELPER_BUNDLE/Contents/MacOS/ScreenReplayHelper"
chmod +x "$HELPER_BUNDLE/Contents/MacOS/ScreenReplayHelper"
[ "$MODE" = "release" ] && strip -S -x "$HELPER_BUNDLE/Contents/MacOS/ScreenReplayHelper" || true
cp "$ICNS" "$HELPER_BUNDLE/Contents/Resources/AppIcon.icns"

cat > "$HELPER_BUNDLE/Contents/Info.plist" << EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleDevelopmentRegion</key>
  <string>en</string>
  <key>CFBundleDisplayName</key>
  <string>ScreenReplay Helper</string>
  <key>CFBundleExecutable</key>
  <string>ScreenReplayHelper</string>
  <key>CFBundleIconFile</key>
  <string>AppIcon</string>
  <key>CFBundleIdentifier</key>
  <string>dev.pengx17.screenreplay.helper</string>
  <key>CFBundleInfoDictionaryVersion</key>
  <string>6.0</string>
  <key>CFBundleName</key>
  <string>ScreenReplay Helper</string>
  <key>CFBundlePackageType</key>
  <string>APPL</string>
  <key>CFBundleShortVersionString</key>
  <string>${VERSION}</string>
  <key>CFBundleVersion</key>
  <string>${BUILD_NUM}</string>
  <key>LSMinimumSystemVersion</key>
  <string>14.0</string>
  <key>LSUIElement</key>
  <true/>
  <key>NSHighResolutionCapable</key>
  <true/>
  <key>NSSupportsAutomaticGraphicsSwitching</key>
  <true/>
  <key>NSScreenCaptureUsageDescription</key>
  <string>ScreenReplay Helper captures your display and system audio into rolling local replay segments on this Mac.</string>
  <key>NSMicrophoneUsageDescription</key>
  <string>ScreenReplay Helper optionally mixes your microphone into replay segments when microphone recording is enabled.</string>
</dict>
</plist>
EOF

# Resolve code-signing identity: explicit MAC_SIGN_IDENTITY, else reuse installed Helper's signing identity if in Keychain, else ad-hoc "-"
SIGN_ID="${MAC_SIGN_IDENTITY:-}"
if [ -z "$SIGN_ID" ]; then
  INSTALLED_HELPER="$HOME/Library/Application Support/ScreenReplay/helper/ScreenReplay Helper.app"
  if [ -d "$INSTALLED_HELPER" ]; then
    INSTALLED_AUTH="$(codesign -dvvv "$INSTALLED_HELPER" 2>&1 | sed -n 's/^Authority=//p' | head -n 1 || true)"
    if [ -n "$INSTALLED_AUTH" ]; then
      DETECTED_ID="$(security find-identity -v -p codesigning 2>/dev/null | grep -F "\"$INSTALLED_AUTH\"" | head -n 1 | awk '{print $2}' || true)"
      SIGN_ID="${DETECTED_ID:-}"
    fi
  fi
  SIGN_ID="${SIGN_ID:--}"
fi
SIGN_OPTS=()
[ "$SIGN_ID" != "-" ] && SIGN_OPTS+=(--options runtime)
echo "build-mac.sh: signing with identity '$SIGN_ID' ${SIGN_OPTS[*]+"${SIGN_OPTS[*]}"}"

codesign --force --sign "$SIGN_ID" ${SIGN_OPTS[@]+"${SIGN_OPTS[@]}"} --timestamp=none "$HELPER_BUNDLE"

# Outer ScreenReplay.app
cp "$SWIFT_BIN_DIR/ScreenReplayMac" "$APP_BUNDLE/Contents/MacOS/ScreenReplay"
cp "$OUT/ScreenReplayViewer" "$APP_BUNDLE/Contents/MacOS/ScreenReplayViewer"
cp "$OUT/build.txt" "$APP_BUNDLE/Contents/Resources/build.txt"
chmod +x "$APP_BUNDLE/Contents/MacOS/ScreenReplay" "$APP_BUNDLE/Contents/MacOS/ScreenReplayViewer"
if [ "$MODE" = "release" ]; then
  strip -S -x "$APP_BUNDLE/Contents/MacOS/ScreenReplay" || true
  strip -S -x "$APP_BUNDLE/Contents/MacOS/ScreenReplayViewer" || true
fi
cp "$ICNS" "$APP_BUNDLE/Contents/Resources/AppIcon.icns"
[ -f "$ROOT/config/analytics.json" ] && cp "$ROOT/config/analytics.json" "$APP_BUNDLE/Contents/Resources/config/analytics.json"

cat > "$APP_BUNDLE/Contents/Info.plist" << EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleDevelopmentRegion</key>
  <string>en</string>
  <key>CFBundleDisplayName</key>
  <string>ScreenReplay</string>
  <key>CFBundleExecutable</key>
  <string>ScreenReplay</string>
  <key>CFBundleIconFile</key>
  <string>AppIcon</string>
  <key>CFBundleIdentifier</key>
  <string>dev.pengx17.screenreplay</string>
  <key>CFBundleInfoDictionaryVersion</key>
  <string>6.0</string>
  <key>CFBundleName</key>
  <string>ScreenReplay</string>
  <key>CFBundlePackageType</key>
  <string>APPL</string>
  <key>CFBundleShortVersionString</key>
  <string>${VERSION}</string>
  <key>CFBundleVersion</key>
  <string>${BUILD_NUM}</string>
  <key>LSMinimumSystemVersion</key>
  <string>14.0</string>
  <key>LSUIElement</key>
  <true/>
  <key>NSHighResolutionCapable</key>
  <true/>
  <key>NSSupportsAutomaticGraphicsSwitching</key>
  <true/>
</dict>
</plist>
EOF

codesign --force --sign "$SIGN_ID" ${SIGN_OPTS[@]+"${SIGN_OPTS[@]}"} --timestamp=none "$APP_BUNDLE/Contents/MacOS/ScreenReplayViewer"
codesign --force --sign "$SIGN_ID" ${SIGN_OPTS[@]+"${SIGN_OPTS[@]}"} --timestamp=none "$APP_BUNDLE"

ZIP="$OUT/ScreenReplay-mac.zip"
rm -f "$ZIP"
(cd "$OUT" && ditto -c -k --sequesterRsrc --keepParent "ScreenReplay.app" "$(basename "$ZIP")")

echo "build-mac.sh: built $APP_BUNDLE and $ZIP"
ls -lh "$APP_BUNDLE/Contents/MacOS" "$HELPER_BUNDLE/Contents/MacOS" "$ZIP"
