#!/bin/bash
# Build OpenSong and install/update it at a STABLE location you can pin to the Dock.
# Re-run any time to update the same pinned app in place. No Xcode required.
#
# Usage: ./Scripts/install.sh            # installs to ~/Applications/OpenSong.app
#        ./Scripts/install.sh /path.app  # custom location
set -euo pipefail
cd "$(dirname "$0")/.."

PRODUCT="OpenSong"
BUNDLE_ID="dev.jude.opensong"
DEST="${1:-$HOME/Applications/OpenSong.app}"

echo "Building release…"
swift build -c release --product "$PRODUCT"
BIN=".build/release/$PRODUCT"
[[ -f "$BIN" ]] || { echo "missing build product: $BIN"; exit 1; }

# Assemble into a temp bundle, then swap into place (so a running app isn't corrupted).
STAGE="$(mktemp -d)/$PRODUCT.app"
mkdir -p "$STAGE/Contents/MacOS" "$STAGE/Contents/Resources"
cp "$BIN" "$STAGE/Contents/MacOS/$PRODUCT"
[[ -f Resources/OpenSong.icns ]] && cp Resources/OpenSong.icns "$STAGE/Contents/Resources/OpenSong.icns"

cat > "$STAGE/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleExecutable</key><string>$PRODUCT</string>
    <key>CFBundleIdentifier</key><string>$BUNDLE_ID</string>
    <key>CFBundleName</key><string>$PRODUCT</string>
    <key>CFBundleIconFile</key><string>OpenSong</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>0.1.0</string>
    <key>CFBundleVersion</key><string>1</string>
    <key>LSMinimumSystemVersion</key><string>14.0</string>
    <key>NSHighResolutionCapable</key><true/>
    <key>NSPrincipalClass</key><string>NSApplication</string>
</dict>
</plist>
PLIST

# Prefer a stable self-signed identity (so macOS permissions persist across rebuilds);
# fall back to ad-hoc. Create the stable identity once with Scripts/make-signing-cert.sh.
IDENTITY="-"
if security find-identity -v -p codesigning 2>/dev/null | grep -q "OpenSong Local"; then
  IDENTITY="OpenSong Local"
fi
codesign --force --deep --sign "$IDENTITY" "$STAGE" 2>/dev/null || true

mkdir -p "$(dirname "$DEST")"
# Quit a running copy so the swap is clean.
pkill -f "$DEST/Contents/MacOS/$PRODUCT" 2>/dev/null || true
sleep 0.3
rm -rf "$DEST"
mv "$STAGE" "$DEST"
# Refresh Launch Services so the Dock/Finder pick up the new build + icon.
/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -f "$DEST" 2>/dev/null || true

echo "Installed → $DEST   (signed: $IDENTITY)"
echo "Pin it: open it once, then right-click its Dock icon → Options → Keep in Dock."
