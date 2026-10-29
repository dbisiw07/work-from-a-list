#!/bin/sh
# Builds the app, copies it to ~/Applications and registers a LaunchAgent that
# starts the HUD at login and restarts it if it ever crashes (a normal Quit stays quit).
set -eu
cd "$(dirname "$0")"

LABEL="local.today-hud"
APP_DIR="$HOME/Applications/Today HUD.app"
PLIST="$HOME/Library/LaunchAgents/$LABEL.plist"

./build.sh

launchctl bootout "gui/$(id -u)/$LABEL" 2>/dev/null || true
pkill -x TodayHUD 2>/dev/null || true

mkdir -p "$HOME/Applications" "$HOME/Library/LaunchAgents"
rm -rf "$APP_DIR"
cp -R "Today HUD.app" "$APP_DIR"

cat > "$PLIST" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key><string>$LABEL</string>
  <key>ProgramArguments</key>
  <array><string>$APP_DIR/Contents/MacOS/TodayHUD</string></array>
  <key>RunAtLoad</key><true/>
  <key>KeepAlive</key>
  <dict><key>SuccessfulExit</key><false/></dict>
  <key>ThrottleInterval</key><integer>5</integer>
  <key>ProcessType</key><string>Interactive</string>
  <key>LimitLoadToSessionType</key><string>Aqua</string>
</dict>
</plist>
PLIST

launchctl bootstrap "gui/$(id -u)" "$PLIST"
echo "Installed. Today HUD is running and will start at login."
