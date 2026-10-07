#!/bin/sh
# Builds Notch HUD.app next to this script. Usage: ./build.sh [--install]
set -e
cd "$(dirname "$0")"
# Built into the plugin, so a marketplace install carries the app and the mod can launch it.
APP="../plugin/notch-hud/app/Notch HUD.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
swiftc -O -parse-as-library -target arm64-apple-macos15 \
  -framework AppKit -framework SwiftUI \
  Sources/main.swift -o "$APP/Contents/MacOS/NotchHUD"
cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleName</key><string>Notch HUD</string>
  <key>CFBundleIdentifier</key><string>io.github.skuvshin0v.notch-hud</string>
  <key>CFBundleExecutable</key><string>NotchHUD</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>0.1.0</string>
  <key>LSMinimumSystemVersion</key><string>15.0</string>
  <key>LSUIElement</key><true/>
  <key>NSAppleEventsUsageDescription</key><string>Notch HUD brings forward the terminal tab a session runs in.</string>
</dict></plist>
PLIST
cp Sounds/*.wav "$APP/Contents/Resources/"
codesign --force --sign - "$APP" >/dev/null 2>&1 || true
echo "built: $APP"
if [ "$1" = "--install" ]; then
  rm -rf "/Applications/Notch HUD.app"
  cp -R "$APP" /Applications/
  echo "installed: /Applications/Notch HUD.app"
fi
