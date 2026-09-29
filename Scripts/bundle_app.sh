#!/bin/bash
# Builds RainyDesktop and wraps it in a minimal .app bundle. A bare SPM
# executable can create ordinary NSWindows fine, but NSStatusItem (the menu
# bar settings icon) is unreliable without a real app bundle + Info.plist --
# this is what actually fixes "no menu bar icon".
set -euo pipefail

cd "$(dirname "$0")/.."

CONFIG="${1:-debug}"
swift build -c "$CONFIG"

BIN_PATH=".build/$CONFIG/RainyDesktop"
APP_DIR=".build/RainyDesktop.app"
CONTENTS="$APP_DIR/Contents"

rm -rf "$APP_DIR"
mkdir -p "$CONTENTS/MacOS"

cp "$BIN_PATH" "$CONTENTS/MacOS/RainyDesktop"

cat > "$CONTENTS/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleURLTypes</key>
    <array>
        <dict>
            <key>CFBundleURLName</key>
            <string>com.rainydesktop.app</string>
            <key>CFBundleURLSchemes</key>
            <array><string>rainydesktop</string></array>
        </dict>
    </array>
    <key>CFBundleIconFile</key>
    <string>AppIcon</string>
    <key>CFBundleExecutable</key>
    <string>RainyDesktop</string>
    <key>CFBundleIdentifier</key>
    <string>com.rainydesktop.app</string>
    <key>CFBundleName</key>
    <string>Rainy Desktop</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleShortVersionString</key>
    <string>1.0</string>
    <key>CFBundleVersion</key>
    <string>1</string>
    <key>LSUIElement</key>
    <true/>
    <key>NSHighResolutionCapable</key>
    <true/>
    <key>LSApplicationCategoryType</key>
    <string>public.app-category.utilities</string>
</dict>
</plist>
PLIST

# Ship the shader sources inside the bundle so the app never has to read
# them out of ~/Documents (a TCC-protected folder -> a permission prompt).
mkdir -p "$CONTENTS/Resources/Shaders"
cp Sources/RainyDesktop/Rendering/Shaders/*.metal Sources/RainyDesktop/Rendering/Shaders/*.h "$CONTENTS/Resources/Shaders/"

cp Assets/AppIcon.icns "$CONTENTS/Resources/AppIcon.icns"

# Sign with a stable identity + identifier. An ad-hoc signature changes on
# every build, so macOS treats each rebuild as a new app and re-asks for
# folder permissions; a real identity keeps the user's grant across builds.
IDENTITY="$(security find-identity -v -p codesigning | awk -F'"' '/Apple Development|Developer ID Application/ {print $2; exit}')"
codesign --force --sign "${IDENTITY:--}" --identifier com.rainydesktop.app "$APP_DIR"

echo "Built $APP_DIR (signed: ${IDENTITY:-ad-hoc})"

# Keep an up-to-date copy in /Applications so it's launchable from
# Spotlight/Launchpad/Finder. (Shaders are still read from this source
# checkout at runtime -- see Rendering/ShaderSource.swift.)
INSTALL_DIR="/Applications/RainyDesktop.app"
rm -rf "$INSTALL_DIR"
cp -R "$APP_DIR" "$INSTALL_DIR"
echo "Installed $INSTALL_DIR"
echo "Run with: open $INSTALL_DIR"
