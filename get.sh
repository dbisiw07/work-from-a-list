#!/bin/sh
# Installs Work from a List without building anything:
#   curl -fsSL https://raw.githubusercontent.com/dbisiw07/work-from-a-list/main/get.sh | sh
# Downloads the latest release into ~/Applications and registers a LaunchAgent so the
# HUD starts at login and comes back if it ever crashes (a normal Quit stays quit).
# `./get.sh "Work from a List.app"` installs a local build instead (install.sh does this).
set -eu

REPO="dbisiw07/work-from-a-list"
LABEL="io.github.dbisiw07.work-from-a-list"
APP_DIR="$HOME/Applications/Work from a List.app"
PLIST="$HOME/Library/LaunchAgents/$LABEL.plist"

if [ "$(sw_vers -productVersion | cut -d. -f1)" -lt 13 ]; then
  echo "Work from a List needs macOS 13 (Ventura) or later." >&2
  exit 1
fi

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
if [ $# -gt 0 ]; then
  SRC="$1"
else
  echo "Downloading Work from a List…"
  curl -fsSL "https://github.com/$REPO/releases/latest/download/Work-from-a-List.zip" -o "$TMP/app.zip"
  ditto -x -k "$TMP/app.zip" "$TMP"
  SRC="$TMP/Work from a List.app"
fi

launchctl bootout "gui/$(id -u)/$LABEL" 2>/dev/null || true
pkill -x WorkFromAList 2>/dev/null || true
# The app used to be called Today HUD; remove that copy (your list moves over on first run).
launchctl bootout "gui/$(id -u)/local.today-hud" 2>/dev/null || true
pkill -x TodayHUD 2>/dev/null || true
rm -rf "$HOME/Applications/Today HUD.app" "$HOME/Library/LaunchAgents/local.today-hud.plist"

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
  <array><string>$APP_DIR/Contents/MacOS/WorkFromAList</string></array>
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
echo "Installed. Work from a List is running and will start at login."
