# usage-mon

Pantau pemakaian **Claude Code** dan **Codex**: CLI + app menu bar macOS.

- **CLI** (`usage_mon.py`) — token, biaya, tren, limit
- **Menu bar** (`MenuBar/`) — app Swift yang menampilkan kuota di bar atas; klik untuk popup detail

## Install (Homebrew)

```bash
brew install yolkmonday/tap/usage-mon             # CLI (macOS & Linux)
brew install --cask yolkmonday/tap/usage-mon-app  # app menu bar (macOS)
```

## CLI

```bash
chmod +x usage-mon
./usage-mon                 # ringkasan 7 hari terakhir
./usage-mon --days 30       # ubah rentang hari
./usage-mon --section daily # hanya tren harian
./usage-mon --section models
./usage-mon --section projects
./usage-mon --json          # output JSON (dipakai menu bar)
./usage-mon --prices        # lihat tabel harga yang dipakai
./usage-mon --no-limit      # lewati panggilan API limit Claude
./usage-mon --watch 5       # auto-refresh tiap 5 detik
```

Alias opsional:

```bash
alias umon="$HOME/Dev/usage-mon/usage-mon"
```

## Menu bar (Swift)

App native yang menaruh satu item di menu bar:

- Label = **ikon gauge + persentase kuota tertinggi** (mis. `[gauge] 100%`),
  berwarna hijau/oranye/merah sesuai status. Ikon dari [Lucide](https://lucide.dev) (`gauge`).
- Klik → popup berisi limit Claude & Codex, ringkasan token + biaya per agent, ganti rentang 7h/30h, tombol refresh & keluar.
- Refresh otomatis tiap 60 detik.
- Tanpa dock icon (`LSUIElement`).

### Build & jalankan

```bash
cd MenuBar
./build-app.sh              # build + bikin dist/UsageMenuBar.app
open dist/UsageMenuBar.app  # jalankan
```

Atau install ke `/Applications`:

```bash
cd MenuBar
./install.sh
```

Agar otomatis jalan saat login: **System Settings › General › Login Items** → tambahkan
`UsageMenuBar.app`.

### Mode debug

```bash
dist/UsageMenuBar.app/Contents/MacOS/UsageMenuBar --once   # cetak JSON hasil fetch
dist/UsageMenuBar.app/Contents/MacOS/UsageMenuBar --title  # cetak label menu bar
dist/UsageMenuBar.app/Contents/MacOS/UsageMenuBar --icon   # cek ikon resource termuat
```

### Mengganti ikon

Ikon menu bar ada di `MenuBar/Sources/UsageMenuBar/Resources/`:

- `gauge.pdf` — vector template yang dipakai menu bar (monokrom, warnanya ikut status)
- `gauge.svg` — sumber asli
- `AppIcon.icns` — ikon app bundle (pakai `build-app.sh`)

Untuk memakai ikon Iconify lain, unduh SVG-nya lalu konversi ke PDF template:

```bash
curl "https://api.iconify.design/<set>/<nama>.svg?height=24" -o ikon.svg
rsvg-convert -f pdf -o Sources/UsageMenuBar/Resources/gauge.pdf ikon.svg
```

App memanggil script `usage-mon`. Lokasi dicari otomatis (relatif ke executable, lalu
`~/Dev/usage-mon/usage-mon`); ubah di `MenuBar/Sources/UsageMenuBar/UsageRunner.swift`
bila proyek dipindah.

## Sumber data

| Agent  | Lokasi                            | Yang dibaca                                  |
|--------|-----------------------------------|----------------------------------------------|
| Claude | `~/.claude/projects/**/*.jsonl`   | baris `type=assistant` → `message.usage`     |
| Codex  | `~/.codex/sessions/**/*.jsonl`    | `event_msg` → `token_count`                  |

## Limit / kuota

| Agent  | Sumber limit                                              |
|--------|-----------------------------------------------------------|
| Claude | API OAuth `api.anthropic.com/api/oauth/usage`             |
| Codex  | field `rate_limits` di file session (`event_msg`)         |

**Kenapa limit Claude tidak ada di file lokal?** Claude Code tidak menyimpan data kuota
(5 jam / mingguan) ke disk. Data itu hanya tersedia lewat API. Token OAuth Claude Code
tersimpan di macOS Keychain (service `Claude Code-credentials`), atau di
`~/.claude/.credentials.json` pada Linux; CLI ini membacanya
(read-only, tidak pernah ditulis ke cache) lalu memanggil endpoint usage resmi.

- Limit akan tampil di bagian **Limit Claude** (5 jam, mingguan, dan per-model bila aktif).
- Jika token expired, CLI menampilkan pesan error dan saran; jalankan `claude` sekali
  untuk me-refresh token.
- Lewati panggilan API dengan `--no-limit`.

## Akurasi

- **Dedup**: satu `requestId` + `apiBlockIndex` hanya dihitung sekali (retry/streaming bisa menulis usage berkali-kali).
- **Codex**: `total_token_usage` bersifat kumulatif per sesi, jadi dipakai selisih antar hari (mendukung reset konteks).
- **Cache**: hasil parse disimpan di `~/.cache/usage-mon/scan-cache.json` berdasarkan `mtime+size`, sehingga scan ulang ~12x lebih cepat (berguna untuk `--watch` / menu bar).

## Harga

Estimasi biaya memakai harga per 1 juta token (USD). Ubah lewat:

`~/.config/usage-mon/prices.json`

```json
{
  "claude": {
    "claude-opus": { "input": 15.0, "output": 75.0, "cache_write": 18.75, "cache_read": 1.5 }
  },
  "codex": {
    "gpt-6-astra": { "input": 2.5, "output": 10.0, "cache_read": 0.25 }
  }
}
```

Model yang tidak punya harga khusus akan memakai default dan ditandai peringatan di `--section models`.

## Catatan

Angka biaya adalah **estimasi** berdasarkan token yang tercatat, bukan tagihan resmi.
