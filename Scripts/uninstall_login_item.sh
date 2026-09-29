#!/bin/bash
# Removes the login item installed by install_login_item.sh.
set -euo pipefail

LABEL="com.rainydesktop.app"
PLIST="$HOME/Library/LaunchAgents/$LABEL.plist"

if [ -f "$PLIST" ]; then
    launchctl bootout "gui/$(id -u)" "$PLIST" 2>/dev/null || true
    rm "$PLIST"
    echo "Removed $PLIST -- RainyDesktop will no longer open at login."
else
    echo "No login item installed at $PLIST."
fi
