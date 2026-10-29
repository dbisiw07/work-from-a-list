#!/bin/sh
# Stops Work from a List and removes the app and its LaunchAgent. Your list, mantras and
# settings stay; add --all to remove those too.
#   curl -fsSL https://raw.githubusercontent.com/dbisiw07/work-from-a-list/main/uninstall.sh | sh
set -u
LABEL="io.github.dbisiw07.work-from-a-list"
launchctl bootout "gui/$(id -u)/$LABEL" 2>/dev/null
pkill -x WorkFromAList 2>/dev/null
rm -f "$HOME/Library/LaunchAgents/$LABEL.plist"
rm -rf "$HOME/Applications/Work from a List.app"
for link in /opt/homebrew/bin/today /usr/local/bin/today "$HOME/.local/bin/today"; do
  case "$(readlink "$link" 2>/dev/null)" in *"Work from a List.app"*) rm -f "$link";; esac
done
if [ "${1:-}" = "--all" ]; then
  rm -rf "$HOME/Library/Application Support/WorkFromAList"
  defaults delete "$LABEL" 2>/dev/null
  echo "Work from a List and its data removed."
else
  echo "Work from a List removed. Your list and mantras are still in ~/Library/Application Support/WorkFromAList."
fi
