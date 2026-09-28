#!/bin/bash
# Build UsageMenuBar menjadi .app bundle universal (arm64 + x86_64) di folder dist/.
#
# Env vars:
#   VERSION        - versi app (default: git tag terbaru tanpa prefix "v", fallback 0.0.0)
#   SIGN_IDENTITY  - identity Developer ID untuk codesign
#                    (mis. "Developer ID Application: Ari Padrian (K4TMF53N3L)")
#                    kosong -> ad-hoc signing (codesign -s -)
#   NOTARIZE=1     - submit ke notarytool & staple (butuh SIGN_IDENTITY + keychain
#                    profile "notary")
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
cd "$HERE"

CONFIG="${1:-release}"

VERSION="${VERSION:-$(git -C "$HERE/.." describe --tags --abbrev=0 2>/dev/null | sed 's/^v//' || true)}"
VERSION="${VERSION:-0.0.0}"

echo "==> Building universal binary ($CONFIG), version $VERSION..."
swift build -c "$CONFIG" --arch arm64 --arch x86_64

BIN_DIR="$(swift build -c "$CONFIG" --arch arm64 --arch x86_64 --show-bin-path)"
BIN="$BIN_DIR/UsageMenuBar"
APP="dist/UsageMenuBar.app"

echo "==> Membuat app bundle..."
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

cp "$BIN" "$APP/Contents/MacOS/UsageMenuBar"

# Salin resource bundle SwiftPM (mis. UsageMenuBar_UsageMenuBar.bundle) bila ada
for b in "$BIN_DIR"/*.bundle; do
    [ -e "$b" ] || continue
    cp -R "$b" "$APP/Contents/Resources/"
done

# Ikon aplikasi (opsional)
if [ -f "Resources/AppIcon.icns" ]; then
    cp "Resources/AppIcon.icns" "$APP/Contents/Resources/AppIcon.icns"
fi

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key>
    <string>UsageMenuBar</string>
    <key>CFBundleDisplayName</key>
    <string>Usage Monitor</string>
    <key>CFBundleIdentifier</key>
    <string>com.yolkmonday.usagemon</string>
    <key>CFBundleVersion</key>
    <string>${VERSION}</string>
    <key>CFBundleShortVersionString</key>
    <string>${VERSION}</string>
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
    <key>LSMultipleInstancesProhibited</key>
    <true/>
</dict>
</plist>
PLIST

echo "==> Signing..."
if [ -n "${SIGN_IDENTITY:-}" ]; then
    echo "    identity: $SIGN_IDENTITY"
    # Resource bundle SwiftPM tidak berisi kode; cukup tersegel oleh signature app.
    codesign --force --options runtime --timestamp -s "$SIGN_IDENTITY" "$APP/Contents/MacOS/UsageMenuBar"
    codesign --force --options runtime --timestamp -s "$SIGN_IDENTITY" "$APP"
else
    echo "    SIGN_IDENTITY kosong -> ad-hoc signing"
    codesign --force --deep -s - "$APP"
fi

echo "==> Verifikasi signature..."
codesign --verify --deep --strict "$APP"

ZIP_FINAL="dist/UsageMenuBar-$VERSION.zip"

if [ "${NOTARIZE:-0}" = "1" ]; then
    if [ -z "${SIGN_IDENTITY:-}" ]; then
        echo "NOTARIZE=1 butuh SIGN_IDENTITY (ad-hoc signing tidak bisa dinotarisasi)." >&2
        exit 1
    fi
    echo "==> Notarizing..."
    ZIP_SUBMIT="dist/UsageMenuBar.zip"
    ditto -c -k --keepParent "$APP" "$ZIP_SUBMIT"
    # notarytool --wait tetap exit 0 walau status Invalid, jadi cek statusnya.
    NOTARY_OUT="$(xcrun notarytool submit "$ZIP_SUBMIT" --keychain-profile notary --wait 2>&1)"
    echo "$NOTARY_OUT"
    if ! grep -q "status: Accepted" <<<"$NOTARY_OUT"; then
        echo "Notarisasi gagal (status bukan Accepted)." >&2
        exit 1
    fi
    xcrun stapler staple "$APP"
    spctl --assess --type execute -vv "$APP"
    rm -f "$ZIP_SUBMIT"
    ditto -c -k --keepParent "$APP" "$ZIP_FINAL"
else
    ditto -c -k --keepParent "$APP" "$ZIP_FINAL"
fi

echo "==> Selesai: $APP"
echo "    Zip: $ZIP_FINAL"
echo "Jalankan dengan: open $APP"
