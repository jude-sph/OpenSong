#!/bin/bash
# Build OpenSong.app from the SwiftPM executable (no Xcode required).
set -euo pipefail
cd "$(dirname "$0")/.."

PRODUCT="OpenSong"
BUNDLE_ID="dev.jude.opensong"

echo "Building release…"
swift build -c release --product "$PRODUCT"
BIN=".build/release/$PRODUCT"
[[ -f "$BIN" ]] || { echo "missing build product: $BIN"; exit 1; }

APP="build/$PRODUCT.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/$PRODUCT"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleExecutable</key><string>$PRODUCT</string>
    <key>CFBundleIdentifier</key><string>$BUNDLE_ID</string>
    <key>CFBundleName</key><string>$PRODUCT</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>0.1.0</string>
    <key>CFBundleVersion</key><string>1</string>
    <key>LSMinimumSystemVersion</key><string>14.0</string>
    <key>NSHighResolutionCapable</key><true/>
    <key>NSPrincipalClass</key><string>NSApplication</string>
</dict>
</plist>
PLIST

codesign --force --sign - "$APP" 2>/dev/null || echo "(ad-hoc codesign skipped)"
echo "Built $APP"
