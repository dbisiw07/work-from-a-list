#!/bin/sh
# Builds "Today HUD.app" next to this script.
set -eu
cd "$(dirname "$0")"

APP="Today HUD.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"

swiftc -O -swift-version 5 -target arm64-apple-macos13.0 main.swift -o "$APP/Contents/MacOS/TodayHUD"

cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>Today HUD</string>
  <key>CFBundleIdentifier</key><string>local.today-hud</string>
  <key>CFBundleExecutable</key><string>TodayHUD</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>0.1</string>
  <key>LSMinimumSystemVersion</key><string>13.0</string>
  <key>LSUIElement</key><true/>
</dict>
</plist>
PLIST

codesign --force --sign - "$APP" >/dev/null
echo "Built $APP"
