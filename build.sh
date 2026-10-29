#!/bin/sh
# Builds "Today HUD.app" next to this script, for this Mac.
#   UNIVERSAL=1 ./build.sh   builds for both Apple silicon and Intel (what releases ship)
#   VERSION=1.2 ./build.sh   sets the version shown in Finder
set -eu
cd "$(dirname "$0")"

APP="Today HUD.app"
BIN="$APP/Contents/MacOS/TodayHUD"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"

if [ "${UNIVERSAL:-0}" = 1 ]; then
  TMP=$(mktemp -d)
  for arch in arm64 x86_64; do
    swiftc -O -swift-version 5 -target "$arch-apple-macos13.0" main.swift -o "$TMP/$arch"
  done
  lipo -create "$TMP/arm64" "$TMP/x86_64" -output "$BIN"
  rm -rf "$TMP"
else
  swiftc -O -swift-version 5 -target "$(uname -m)-apple-macos13.0" main.swift -o "$BIN"
fi

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>Today HUD</string>
  <key>CFBundleIdentifier</key><string>local.today-hud</string>
  <key>CFBundleExecutable</key><string>TodayHUD</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>${VERSION:-0.1}</string>
  <key>LSMinimumSystemVersion</key><string>13.0</string>
  <key>LSUIElement</key><true/>
</dict>
</plist>
PLIST

codesign --force --sign - "$APP" >/dev/null
echo "Built $APP"
