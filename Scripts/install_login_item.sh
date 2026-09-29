#!/bin/bash
# Installs a per-user launchd agent that opens RainyDesktop.app at login.
# Reversible: run uninstall_login_item.sh to remove it.
set -euo pipefail

cd "$(dirname "$0")/.."
PROJECT_DIR="$(pwd)"
APP_PATH="/Applications/RainyDesktop.app"
LABEL="com.rainydesktop.app"
PLIST="$HOME/Library/LaunchAgents/$LABEL.plist"

if [ ! -d "$APP_PATH" ]; then
    echo "No built app at $APP_PATH -- run ./Scripts/bundle_app.sh first." >&2
    exit 1
fi

mkdir -p "$HOME/Library/LaunchAgents"

cat > "$PLIST" <<PLISTEOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>$LABEL</string>
    <key>ProgramArguments</key>
    <array>
        <string>/usr/bin/open</string>
        <string>$APP_PATH</string>
    </array>
    <key>RunAtLoad</key>
    <true/>
    <key>KeepAlive</key>
    <false/>
    <key>ProcessType</key>
    <string>Interactive</string>
</dict>
</plist>
PLISTEOF

# Unload first in case it's already installed (e.g. re-running after a rebuild).
launchctl bootout "gui/$(id -u)" "$PLIST" 2>/dev/null || true
launchctl bootstrap "gui/$(id -u)" "$PLIST"

echo "Installed: $PLIST"
echo "RainyDesktop will now open automatically at login."
echo "To remove: ./Scripts/uninstall_login_item.sh"
