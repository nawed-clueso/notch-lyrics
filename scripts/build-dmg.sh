#!/usr/bin/env bash
# Build a distributable Notch Lyrics.app and Notch Lyrics.dmg.
# Ad-hoc signed (free). Recipients need to right-click → Open the first time
# OR run:  xattr -dr com.apple.quarantine "/Applications/Notch Lyrics.app"
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

APP_NAME="Notch Lyrics"
BUNDLE_ID="com.notchlyrics.app"
VERSION="1.1.2"
BUILD_DIR="$ROOT/build"
APP_DIR="$BUILD_DIR/$APP_NAME.app"
DMG_PATH="$BUILD_DIR/$APP_NAME.dmg"
EXEC_NAME="NotchLyrics"

echo "▶︎ Cleaning build dir"
rm -rf "$BUILD_DIR"
mkdir -p "$BUILD_DIR"

# Bundle.module only finds resources at the app root or at this Mac's .build
# path, so a packaged app that uses it runs here and crashes on every other
# Mac. Resources must go through Bundle.appResources.
if grep -rnE '^[^/]*Bundle\.module' Sources; then
    echo "✗ Bundle.module used above; use Bundle.appResources instead"
    exit 1
fi

echo "▶︎ Compiling release binary"
swift build -c release --arch arm64

BIN="$ROOT/.build/release/$EXEC_NAME"
RES_BUNDLE="$ROOT/.build/release/NotchLyrics_NotchLyrics.bundle"
test -f "$BIN" || { echo "✗ binary missing at $BIN"; exit 1; }
test -d "$RES_BUNDLE" || { echo "✗ resource bundle missing at $RES_BUNDLE"; exit 1; }

echo "▶︎ Assembling .app bundle"
mkdir -p "$APP_DIR/Contents/MacOS"
mkdir -p "$APP_DIR/Contents/Resources"

cp "$BIN" "$APP_DIR/Contents/MacOS/$EXEC_NAME"
cp -R "$RES_BUNDLE" "$APP_DIR/Contents/Resources/"

if [ -f "$ROOT/scripts/AppIcon.icns" ]; then
    cp "$ROOT/scripts/AppIcon.icns" "$APP_DIR/Contents/Resources/AppIcon.icns"
fi

cat > "$APP_DIR/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleExecutable</key>      <string>$EXEC_NAME</string>
    <key>CFBundleIconFile</key>        <string>AppIcon</string>
    <key>CFBundleIdentifier</key>      <string>$BUNDLE_ID</string>
    <key>CFBundleName</key>            <string>$APP_NAME</string>
    <key>CFBundleDisplayName</key>     <string>$APP_NAME</string>
    <key>CFBundleVersion</key>         <string>$VERSION</string>
    <key>CFBundleShortVersionString</key><string>$VERSION</string>
    <key>CFBundlePackageType</key>     <string>APPL</string>
    <key>CFBundleInfoDictionaryVersion</key><string>6.0</string>
    <key>LSMinimumSystemVersion</key>  <string>15.0</string>
    <key>NSHighResolutionCapable</key> <true/>
    <key>NSHumanReadableCopyright</key><string>© 2026 Nawed Ali. MIT License.</string>
    <key>NSAppleEventsUsageDescription</key>
    <string>Reads what's playing in Spotify, Apple Music, and YouTube Music to show synced lyrics.</string>
    <key>NSMicrophoneUsageDescription</key>
    <string>Captures audio from a loopback input device (e.g. BlackHole) so the effects engine can process system audio.</string>
</dict>
</plist>
PLIST

echo "▶︎ Ad-hoc signing"
codesign --force --deep --sign - "$APP_DIR" >/dev/null

echo "▶︎ Creating DMG"
hdiutil create \
    -volname "$APP_NAME" \
    -srcfolder "$APP_DIR" \
    -ov \
    -format UDZO \
    "$DMG_PATH" >/dev/null

echo ""
echo "✅ Done."
echo "   App: $APP_DIR"
echo "   DMG: $DMG_PATH"
echo ""
echo "Recipients see a Gatekeeper warning on first open (because this isn't"
echo "Developer ID signed). They should right-click the app → Open → confirm."
echo "Or run: xattr -dr com.apple.quarantine \"/Applications/$APP_NAME.app\""
