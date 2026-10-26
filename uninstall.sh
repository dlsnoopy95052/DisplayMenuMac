#!/bin/bash
set -euo pipefail
AGENT="$HOME/Library/LaunchAgents/com.local.displaymenu.plist"
launchctl bootout "gui/$(id -u)" "$AGENT" 2>/dev/null || true
pkill -f '/Display Menu.app/Contents/MacOS/DisplayMenu' 2>/dev/null || true
rm -f "$AGENT"
rm -rf "$HOME/Applications/Display Menu.app"
echo 'Display Menu removed.'
