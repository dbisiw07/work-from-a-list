#!/bin/sh
# Installs Today HUD without building anything:
#   curl -fsSL https://raw.githubusercontent.com/dbisiw07/today-hud/main/get.sh | sh
# Downloads the latest release into ~/Applications and registers a LaunchAgent so the
# HUD starts at login and comes back if it ever crashes (a normal Quit stays quit).
# `./get.sh "Today HUD.app"` installs a local build instead (install.sh does this).
set -eu

REPO="dbisiw07/today-hud"
LABEL="local.today-hud"
APP_DIR="$HOME/Applications/Today HUD.app"
PLIST="$HOME/Library/LaunchAgents/$LABEL.plist"

if [ "$(sw_vers -productVersion | cut -d. -f1)" -lt 13 ]; then
  echo "Today HUD needs macOS 13 (Ventura) or later." >&2
  exit 1
fi

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
if [ $# -gt 0 ]; then
  SRC="$1"
else
  echo "Downloading Today HUD…"
  curl -fsSL "https://github.com/$REPO/releases/latest/download/Today-HUD.zip" -o "$TMP/app.zip"
  ditto -x -k "$TMP/app.zip" "$TMP"
  SRC="$TMP/Today HUD.app"
fi

launchctl bootout "gui/$(id -u)/$LABEL" 2>/dev/null || true
pkill -x TodayHUD 2>/dev/null || true

mkdir -p "$HOME/Applications" "$HOME/Library/LaunchAgents"
rm -rf "$APP_DIR"
ditto "$SRC" "$APP_DIR"
xattr -dr com.apple.quarantine "$APP_DIR" 2>/dev/null || true

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
