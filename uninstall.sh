#!/bin/bash
# Removes the launchd agent, the script and the runner. Keeps your config
# (~/.config/weekly-cleanup) and the log. Same BIN/LABEL options as install.sh.
set -euo pipefail

BIN="${BIN:-$HOME/bin}"
LABEL="${LABEL:-local.weekly-cleanup}"
[[ "$LABEL" =~ ^[A-Za-z0-9][A-Za-z0-9.-]*$ ]] || { echo "uninstall: invalid LABEL" >&2; exit 1; }
PLIST="$HOME/Library/LaunchAgents/$LABEL.plist"

if [ -f "$PLIST" ] && ! grep -qF "<string>$BIN/weekly-cleanup-runner</string>" "$PLIST"; then
  echo "uninstall: $PLIST does not run $BIN/weekly-cleanup-runner, leaving it alone" >&2; exit 1
fi
launchctl bootout "gui/$(id -u)/$LABEL" 2>/dev/null || true
rm -f "$PLIST" "$BIN/weekly-cleanup.sh" "$BIN/weekly-cleanup-runner" "$BIN/.weekly-cleanup-runner.swift"

echo "Removed $LABEL, $BIN/weekly-cleanup.sh and $BIN/weekly-cleanup-runner."
echo "Kept ~/.config/weekly-cleanup and ~/Library/Logs/weekly-cleanup.log."
echo "Remove the runner from System Settings > Privacy & Security > Full Disk Access by hand."
