#!/bin/bash
# Install UsageMenuBar ke /Applications dan (opsional) jadikan login item.
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
APP_SRC="$HERE/dist/UsageMenuBar.app"
APP_DST="/Applications/UsageMenuBar.app"

if [ ! -d "$APP_SRC" ]; then
  echo "Belum ada bundle. Jalankan dulu: ./build-app.sh"
  exit 1
fi

echo "==> Menutup instance yang sedang jalan (jika ada)"
osascript -e 'quit app "UsageMenuBar"' >/dev/null 2>&1 || true
pkill -x UsageMenuBar || true

echo "==> Menyalin ke $APP_DST"
rm -rf "$APP_DST"
cp -R "$APP_SRC" "$APP_DST"

echo "==> Menjalankan"
open "$APP_DST"

echo
echo "==> Selesai."
echo "Agar otomatis jalan saat login:"
echo "  System Settings > General > Login Items > tambahkan $APP_DST"
echo
echo "Catatan: app mencari CLI usage-mon dari Homebrew dulu (/opt/homebrew/bin atau"
echo "/usr/local/bin), baru fallback ke ~/Dev/usage-mon/usage-mon."
echo "Jika lokasi proyek dipindah, ubah di UsageRunner.locateScript()."
