#!/bin/zsh
# Repeatable build: compiles the release binary and packages a
# Finder-launchable ArcLatch.app under ./build/.
set -euo pipefail
cd "$(dirname "$0")"

echo "Building ArcLatch (release)…"
swift build -c release --product ArcLatchApp

BIN=".build/release/ArcLatchApp"
APP="build/ArcLatch.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/ArcLatch"
cp "Assets/ArcLatch.icns" "$APP/Contents/Resources/"

cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key><string>ArcLatch</string>
    <key>CFBundleDisplayName</key><string>ArcLatch</string>
    <key>CFBundleIdentifier</key><string>com.billymrx.arclatch</string>
    <key>CFBundleExecutable</key><string>ArcLatch</string>
    <key>CFBundleIconFile</key><string>ArcLatch.icns</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>0.2.0</string>
    <key>CFBundleVersion</key><string>2</string>
    <key>LSMinimumSystemVersion</key><string>14.0</string>
    <key>NSHighResolutionCapable</key><true/>
    <key>NSPrincipalClass</key><string>NSApplication</string>
    <key>NSHumanReadableCopyright</key><string>Local use. Fire up local AI on your Mac.</string>
</dict>
</plist>
PLIST

printf 'APPL????' > "$APP/Contents/PkgInfo"
codesign --force --sign - "$APP" 2>/dev/null || true

echo "Built: $(cd build && pwd)/ArcLatch.app"
