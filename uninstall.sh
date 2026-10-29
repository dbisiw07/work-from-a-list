#!/bin/sh
# Stops Today HUD and removes the app and its LaunchAgent. Your list, mantras and
# settings stay; add --all to remove those too.
#   curl -fsSL https://raw.githubusercontent.com/dbisiw07/today-hud/main/uninstall.sh | sh
set -u
LABEL="local.today-hud"
launchctl bootout "gui/$(id -u)/$LABEL" 2>/dev/null
pkill -x TodayHUD 2>/dev/null
rm -f "$HOME/Library/LaunchAgents/$LABEL.plist"
rm -rf "$HOME/Applications/Today HUD.app"
if [ "${1:-}" = "--all" ]; then
  rm -rf "$HOME/Library/Application Support/TodayHUD"
  defaults delete "$LABEL" 2>/dev/null
  echo "Today HUD and its data removed."
else
  echo "Today HUD removed. Your list and mantras are still in ~/Library/Application Support/TodayHUD."
fi
