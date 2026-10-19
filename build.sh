#!/bin/zsh
# Builds "Claude Eye.app" into ./build.
#
#   ./build.sh            build only
#   ./build.sh --install  build and copy to ~/Applications
#   ./build.sh --open     build, install and launch
set -euo pipefail
cd "$(dirname "$0")"

VERSION="1.0.0"
NAME="Claude Eye"
BUNDLE_ID="local.claudeeye"
OUT="build"
APP="$OUT/$NAME.app"
INSTALL=false; OPEN=false
for arg in "$@"; do
  case $arg in
    --install) INSTALL=true ;;
    --open) INSTALL=true; OPEN=true ;;
    *) echo "Unknown option: $arg"; exit 1 ;;
  esac
done

command -v swiftc >/dev/null || { echo "swiftc not found. Install the tools with: xcode-select --install"; exit 1; }

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

SWIFTC=(swiftc -O -swift-version 5)

# Some Command Line Tools installs keep a stale module.modulemap next to the newer
# bridging.modulemap, which breaks every build with "redefinition of module 'SwiftBridging'".
# Hide the stale file from the compiler with a VFS overlay instead of deleting system files.
STALE=/Library/Developer/CommandLineTools/usr/include/swift/module.modulemap
if [[ -f $STALE && -f ${STALE:h}/bridging.modulemap ]]; then
  : > "$OUT/empty.modulemap"
  cat > "$OUT/overlay.yaml" <<EOF
{ "version": 0, "case-sensitive": "false", "roots": [ { "type": "file",
  "name": "$STALE", "external-contents": "$PWD/$OUT/empty.modulemap" } ] }
EOF
  SWIFTC+=(-vfsoverlay "$OUT/overlay.yaml" -Xcc -ivfsoverlay -Xcc "$OUT/overlay.yaml")
fi

echo "Compiling…"
"${SWIFTC[@]}" Sources/main.swift -o "$APP/Contents/MacOS/ClaudeEye"

echo "Making icon…"
"${SWIFTC[@]}" scripts/make-icon.swift -o "$OUT/make-icon"
rm -rf "$OUT/AppIcon.iconset"
"$OUT/make-icon" "$OUT/AppIcon.iconset"
iconutil -c icns "$OUT/AppIcon.iconset" -o "$APP/Contents/Resources/AppIcon.icns"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>$NAME</string>
  <key>CFBundleDisplayName</key><string>$NAME</string>
  <key>CFBundleIdentifier</key><string>$BUNDLE_ID</string>
  <key>CFBundleExecutable</key><string>ClaudeEye</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleVersion</key><string>$VERSION</string>
  <key>CFBundleShortVersionString</key><string>$VERSION</string>
  <key>LSMinimumSystemVersion</key><string>13.0</string>
  <key>LSApplicationCategoryType</key><string>public.app-category.productivity</string>
  <key>NSHighResolutionCapable</key><true/>
  <key>NSHumanReadableCopyright</key><string>MIT License</string>
  <key>NSScreenCaptureUsageDescription</key><string>Claude Eye takes a screenshot when the eye is on so Claude can see what you're showing.</string>
  <key>NSMicrophoneUsageDescription</key><string>Claude Eye listens when you click the microphone so you can talk instead of typing.</string>
  <key>NSSpeechRecognitionUsageDescription</key><string>Claude Eye turns what you say into text for your message.</string>
</dict>
</plist>
PLIST

# A stable signing identity lets macOS keep the Screen Recording permission across
# rebuilds (create one with scripts/setup-signing.sh). Otherwise sign ad-hoc.
IDENTITY=$(security find-identity -p codesigning 2>/dev/null | awk '/"Claude Eye Local Signing"/ {print $2; exit}')
if [[ -n $IDENTITY ]] && codesign --force --deep -s "$IDENTITY" "$APP" 2>/dev/null; then
  echo "Signed with \"Claude Eye Local Signing\""
else
  codesign --force --deep -s - "$APP"
  echo "Ad-hoc signed. Screen Recording permission will reset after each rebuild (see scripts/setup-signing.sh)."
fi

echo "Built: $APP"

if $INSTALL; then
  mkdir -p "$HOME/Applications"
  pkill -x ClaudeEye 2>/dev/null && sleep 0.5 || true
  rm -rf "$HOME/Applications/$NAME.app"
  ditto "$APP" "$HOME/Applications/$NAME.app"
  echo "Installed: ~/Applications/$NAME.app"
fi
$OPEN && open "$HOME/Applications/$NAME.app"
exit 0
