#!/bin/bash
# Build UsageMenuBar menjadi .app bundle di folder dist/
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
cd "$HERE"

CONFIG="${1:-release}"
echo "==> Building ($CONFIG)..."
swift build -c "$CONFIG"

BIN=".build/$CONFIG/UsageMenuBar"
APP="dist/UsageMenuBar.app"

echo "==> Membuat app bundle..."
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

cp "$BIN" "$APP/Contents/MacOS/UsageMenuBar"

# Salin resource bundle SwiftPM (mis. UsageMenuBar_UsageMenuBar.bundle) bila ada
for b in .build/"$CONFIG"/*.bundle; do
    [ -e "$b" ] || continue
    cp -R "$b" "$APP/Contents/Resources/"
done

# Ikon aplikasi (opsional)
if [ -f "Resources/AppIcon.icns" ]; then
    cp "Resources/AppIcon.icns" "$APP/Contents/Resources/AppIcon.icns"
fi

cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key>
    <string>UsageMenuBar</string>
    <key>CFBundleDisplayName</key>
    <string>Usage Monitor</string>
    <key>CFBundleIdentifier</key>
    <string>com.local.usagemonitor</string>
    <key>CFBundleVersion</key>
    <string>1.0</string>
    <key>CFBundleShortVersionString</key>
    <string>1.0</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleExecutable</key>
    <string>UsageMenuBar</string>
    <key>CFBundleIconFile</key>
    <string>AppIcon</string>
    <key>LSMinimumSystemVersion</key>
    <string>13.0</string>
    <key>LSUIElement</key>
    <true/>
</dict>
</plist>
PLIST

echo "==> Selesai: $APP"
echo "Jalankan dengan: open $APP"
