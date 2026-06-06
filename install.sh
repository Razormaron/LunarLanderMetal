#!/bin/bash
set -e
cd "$(dirname "$0")"

echo "Building..."
swift build -c release

APP="/Applications/LunarLander.app"
BINARY=".build/arm64-apple-macosx/release/LunarLanderMetal"

mkdir -p "$APP/Contents/MacOS"
mkdir -p "$APP/Contents/Resources"

cp "$BINARY" "$APP/Contents/MacOS/LunarLander"

cat > "$APP/Contents/Info.plist" << 'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key><string>LunarLander</string>
    <key>CFBundleDisplayName</key><string>Lunar Lander</string>
    <key>CFBundleIdentifier</key><string>com.local.lunarlander</string>
    <key>CFBundleVersion</key><string>1.0</string>
    <key>CFBundleExecutable</key><string>LunarLander</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>LSMinimumSystemVersion</key><string>13.0</string>
    <key>NSHighResolutionCapable</key><true/>
    <key>NSPrincipalClass</key><string>NSApplication</string>
</dict>
</plist>
PLIST

touch "$APP"
killall Dock 2>/dev/null || true

echo "Done — LunarLander.app installed in /Applications."
echo "Launch it from /Applications or Spotlight."
