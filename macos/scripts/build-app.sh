#!/bin/sh
# Build "build/Voicestack.app" from the SwiftPM package in app/ and sign it ad hoc.
# Leaves the bundle in build/; installs nothing. Optional output must be a NEW
# direct child of this snapshot's build/ area. Never replaces an existing bundle.
set -eu
ROOT=$(cd "$(dirname "$0")/.." && pwd -P)
APP=$(python3 "$ROOT/scripts/reserve-build-output.py" "$ROOT" "${1:-$ROOT/build/Voicestack.app}")
VERSION=0.1.0

cd "$ROOT/app"
swift build -c release --product FloatingVoice
BIN="$(swift build -c release --show-bin-path)/FloatingVoice"

mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/Voicestack"
cat > "$APP/Contents/Info.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>Voicestack</string>
  <key>CFBundleDisplayName</key><string>Voicestack</string>
  <key>CFBundleIdentifier</key><string>local.floating-voice</string>
  <key>CFBundleExecutable</key><string>Voicestack</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>$VERSION</string>
  <key>CFBundleVersion</key><string>$VERSION</string>
  <key>CFBundleInfoDictionaryVersion</key><string>6.0</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>NSHighResolutionCapable</key><true/>
  <key>NSMicrophoneUsageDescription</key><string>Voicestack listens so you can talk to your chief of staff.</string>
</dict>
</plist>
EOF

# The app icon (pick one with scripts/set-icon.sh N). With Xcode's actool, the Icon Composer document
# app/Icon/AppIcon.icon is compiled into Assets.car (the native icon on macOS 26+, with its dark and tinted looks) plus
# an AppIcon.icns for older systems, and CFBundleIconName is added. actool comes from the active developer directory
# or, if that is only the Command Line Tools, from /Applications/Xcode.app (via DEVELOPER_DIR, for this step only;
# xcode-select is left alone). Without Xcode (or with FV_NO_ACTOOL=1), app/Icon/AppIcon-1024.png is packed into AppIcon.icns with iconutil.
ICON_DIR="$ROOT/app/Icon"
RES="$APP/Contents/Resources"
ICON_TMP=$(mktemp -d)
ACTOOL_DEV=""
if [ -n "${FV_NO_ACTOOL:-}" ]; then
  :  # force the iconutil fallback (to test it)
elif xcrun --find actool >/dev/null 2>&1; then
  ACTOOL_DEV="${DEVELOPER_DIR:-$(xcode-select -p)}"
elif [ -d /Applications/Xcode.app/Contents/Developer ] && DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcrun --find actool >/dev/null 2>&1; then
  ACTOOL_DEV=/Applications/Xcode.app/Contents/Developer
fi
if [ -n "$ACTOOL_DEV" ] && [ -d "$ICON_DIR/AppIcon.icon" ]; then
  echo "App icon: actool ($ACTOOL_DEV) from app/Icon/AppIcon.icon"
  DEVELOPER_DIR="$ACTOOL_DEV" xcrun actool "$ICON_DIR/AppIcon.icon" --compile "$RES" \
    --platform macosx --target-device mac --minimum-deployment-target 14.0 \
    --app-icon AppIcon --include-all-app-icons --output-partial-info-plist "$ICON_TMP/icon.plist" \
    --output-format human-readable-text --notices --warnings --errors > "$ICON_TMP/actool.log" 2>&1 || { cat "$ICON_TMP/actool.log"; exit 1; }
  # actool lists its results; anything else it prints is a notice, warning or error.
  if grep -v -e '^/\* com.apple.actool.compilation-results \*/$' -e "^$RES/" -e "^$ICON_TMP/" -e '^$' "$ICON_TMP/actool.log"; then
    echo "actool reported the above"; exit 1
  fi
  [ -f "$RES/Assets.car" ] && [ -f "$RES/AppIcon.icns" ] || { echo "actool did not write Assets.car and AppIcon.icns"; exit 1; }
  /usr/libexec/PlistBuddy -c "Merge $ICON_TMP/icon.plist" "$APP/Contents/Info.plist" >/dev/null
elif [ -f "$ICON_DIR/AppIcon-1024.png" ]; then
  echo "App icon: iconutil from app/Icon/AppIcon-1024.png (no Xcode actool; no Assets.car)"
  ICONSET="$ICON_TMP/AppIcon.iconset"
  mkdir -p "$ICONSET"
  for s in 16 32 128 256 512; do
    sips -z $s $s "$ICON_DIR/AppIcon-1024.png" --out "$ICONSET/icon_${s}x${s}.png" >/dev/null
    sips -z $((s * 2)) $((s * 2)) "$ICON_DIR/AppIcon-1024.png" --out "$ICONSET/icon_${s}x${s}@2x.png" >/dev/null
  done
  iconutil -c icns "$ICONSET" -o "$RES/AppIcon.icns"
else
  echo "No app icon in app/Icon; building without one"
fi
rm -rf "$ICON_TMP"

# Ad hoc, with an explicit designated requirement on the bundle id, so macOS's privacy database (TCC) keeps the
# microphone permission across rebuilds instead of keying it on each build's code hash. No certificate or keychain.
codesign --force --sign - --identifier local.floating-voice -r='designated => identifier "local.floating-voice"' "$APP"
codesign --verify --strict --verbose=2 "$APP"
codesign -dr - "$APP"
echo "Built $APP"
