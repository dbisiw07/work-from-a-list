#!/bin/sh
set -u
LABEL="local.today-hud"
launchctl bootout "gui/$(id -u)/$LABEL" 2>/dev/null
pkill -x TodayHUD 2>/dev/null
rm -f "$HOME/Library/LaunchAgents/$LABEL.plist"
rm -rf "$HOME/Applications/Today HUD.app"
echo "Today HUD removed."
