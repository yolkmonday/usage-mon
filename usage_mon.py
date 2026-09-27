#!/usr/bin/env python3
"""
usage-mon: pantau pemakaian token & biaya Claude Code dan Codex dari file lokal.

Sumber data:
  - Claude : ~/.claude/projects/**/*.jsonl  (baris type=assistant -> message.usage)
  - Codex  : ~/.codex/sessions/**/*.jsonl  (event_msg payload.type=token_count)

Pemakaian:
  usage_mon.py                 ringkasan default (7 hari terakhir)
  usage_mon.py --days 30       ubah rentang hari
  usage_mon.py --daily         tabel tren per hari
  usage_mon.py --models        breakdown per model
  usage_mon.py --projects      breakdown per project (Claude)
  usage_mon.py --json          output JSON mentah
  usage_mon.py --watch 5       refresh tiap 5 detik
"""

from __future__ import annotations

import argparse
import json
import os
import subprocess
import sys
import urllib.error
import urllib.request
import time
from collections import defaultdict
from dataclasses import dataclass, field
from datetime import datetime, timedelta, timezone
from pathlib import Path

HOME = Path.home()
CLAUDE_DIR = HOME / ".claude" / "projects"
CODEX_DIR = HOME / ".codex" / "sessions"
PRICES_FILE = HOME / ".config" / "usage-mon" / "prices.json"
CACHE_FILE = HOME / ".cache" / "usage-mon" / "scan-cache.json"
CLAUDE_KEYCHAIN_SERVICE = "Claude Code-credentials"
CLAUDE_USAGE_URL = "https://api.anthropic.com/api/oauth/usage"

# ---------------------------------------------------------------------------
# Harga per 1 juta token (USD). Perkiraan; cache write ~1.25x input, cache read ~0.1x.
# ---------------------------------------------------------------------------
DEFAULT_PRICE = {"input": 3.0, "output": 15.0, "cache_write": 3.75, "cache_read": 0.30}

CLAUDE_PRICES = {
    "claude-opus": {"input": 15.0, "output": 75.0, "cache_write": 18.75, "cache_read": 1.50},
    "claude-sonnet": {"input": 3.0, "output": 15.0, "cache_write": 3.75, "cache_read": 0.30},
    "claude-haiku": {"input": 0.80, "output": 4.0, "cache_write": 1.0, "cache_read": 0.08},
    "claude-fable": {"input": 3.0, "output": 15.0, "cache_write": 3.75, "cache_read": 0.30},
}

CODEX_PRICES = {
    "gpt-5.5": {"input": 2.5, "output": 10.0, "cache_read": 0.25},
    "gpt-5.4": {"input": 2.5, "output": 10.0, "cache_read": 0.25},
    "gpt-5": {"input": 1.25, "output": 10.0, "cache_read": 0.125},
}


def price_for(model: str, table: dict, default: dict) -> dict:
    m = (model or "").lower()
    for key, p in table.items():
        if key in m:
            return p
    return default


def load_custom_prices() -> None:
    """Override harga dari ~/.config/usage-mon/prices.json (opsional)."""
    if not PRICES_FILE.exists():
        return
    try:
        data = json.loads(PRICES_FILE.read_text())
    except (OSError, json.JSONDecodeError):
        return
    for name, pricing in (data.get("claude") or {}).items():
        CLAUDE_PRICES[name.lower()] = pricing
    for name, pricing in (data.get("codex") or {}).items():
        CODEX_PRICES[name.lower()] = pricing


# ---------------------------------------------------------------------------
# Cache scan: simpan per file berdasarkan (mtime, size) agar file tak berubah
# tidak di-parse ulang. Berguna untuk mode --watch / menu bar yang refresh sering.
# ---------------------------------------------------------------------------
def _load_cache() -> dict:
    if not CACHE_FILE.exists():
        return {}
    try:
        return json.loads(CACHE_FILE.read_text())
    except (OSError, json.JSONDecodeError):
        return {}


def _save_cache(cache: dict) -> None:
    try:
        CACHE_FILE.parent.mkdir(parents=True, exist_ok=True)
        CACHE_FILE.write_text(json.dumps(cache))
    except OSError:
        pass


def _file_sig(path: Path) -> tuple[int, int]:
    st = path.stat()
    return (int(st.st_mtime), st.st_size)


# ---------------------------------------------------------------------------
# Struktur data
# ---------------------------------------------------------------------------
@dataclass
class Bucket:
    input: int = 0
    output: int = 0
    cache_write: int = 0
    cache_read: int = 0
    cost: float = 0.0
    events: int = 0

    def add(self, inp=0, out=0, cw=0, cr=0, cost=0.0):
        self.input += inp
        self.output += out
        self.cache_write += cw
        self.cache_read += cr
        self.cost += cost
        self.events += 1

    @property
    def total_tokens(self) -> int:
        return self.input + self.output + self.cache_write + self.cache_read


@dataclass
class Result:
    source: str
    total: Bucket = field(default_factory=Bucket)
    daily: dict = field(default_factory=lambda: defaultdict(Bucket))
    models: dict = field(default_factory=lambda: defaultdict(Bucket))
    projects: dict = field(default_factory=lambda: defaultdict(Bucket))
    rate_limit: dict | None = None  # khusus Codex
    last_error: str | None = None


def parse_iso(ts: str) -> datetime | None:
    if not ts:
        return None
    try:
        return datetime.fromisoformat(ts.replace("Z", "+00:00")).astimezone(timezone.utc)
    except ValueError:
        return None


# ---------------------------------------------------------------------------
# Limit Claude: dibaca dari API OAuth resmi memakai token di Keychain.
# Token tidak pernah ditulis ke disk/cache.
# ---------------------------------------------------------------------------
def _claude_oauth_token() -> str | None:
    """Ambil access token OAuth Claude Code dari macOS Keychain."""
    try:
        out = subprocess.run(
            ["security", "find-generic-password", "-s", CLAUDE_KEYCHAIN_SERVICE, "-w"],
            capture_output=True, text=True, timeout=10,
        )
    except (OSError, subprocess.SubprocessError):
        return None
    if out.returncode != 0 or not out.stdout.strip():
        return None
    try:
        data = json.loads(out.stdout)
    except json.JSONDecodeError:
        return None
    return (data.get("claudeAiOauth") or {}).get("accessToken")


def fetch_claude_limits() -> dict | None:
    """Kembalikan dict limit Claude, atau {'error': ...} bila gagal."""
    token = _claude_oauth_token()
    if not token:
        return {"error": "token OAuth tidak ditemukan di Keychain"}

    req = urllib.request.Request(
        CLAUDE_USAGE_URL,
        headers={
            "Authorization": f"Bearer {token}",
            "anthropic-beta": "oauth-2025-04-20",
            "Accept": "application/json",
            "User-Agent": "usage-mon/1.0",
        },
    )
    try:
        with urllib.request.urlopen(req, timeout=15) as resp:
            data = json.loads(resp.read().decode())
    except urllib.error.HTTPError as e:
        if e.code in (401, 403):
            return {"error": "token expired/ditolak (401/403) - jalankan Claude Code sekali untuk refresh"}
        return {"error": f"HTTP {e.code}: {e.reason}"}
    except (urllib.error.URLError, OSError, json.JSONDecodeError) as e:
        return {"error": f"gagal menghubungi API: {e}"}

    # ambil label subscription dari keychain kalau ada
    limits = []
    for item in data.get("limits") or []:
        kind = item.get("kind")
        pct = item.get("percent", 0)
        # tampilkan: session & weekly_all selalu; scoped hanya bila aktif/terpakai
        if kind == "weekly_scoped" and not item.get("is_active") and pct == 0:
            continue
        scoped = item.get("scope") or {}
        model = (scoped.get("model") or {}).get("display_name") if scoped else None
        label = {
            "session": "5 jam",
            "weekly_all": "mingguan",
            "weekly_scoped": f"mingguan ({model})" if model else "mingguan (model)",
        }.get(kind, kind)
        limits.append({
            "label": label,
            "percent": pct,
            "severity": item.get("severity", "normal"),
            "resets_at": item.get("resets_at"),
        })

    # fallback bila array limits kosong
    if not limits:
        for key, label in (("five_hour", "5 jam"), ("seven_day", "mingguan"),
                           ("seven_day_opus", "mingguan (Opus)"), ("seven_day_sonnet", "mingguan (Sonnet)")):
            w = data.get(key)
            if w and w.get("utilization") is not None:
                limits.append({
                    "label": label,
                    "percent": w.get("utilization", 0),
                    "severity": "normal",
                    "resets_at": w.get("resets_at"),
                })

    return {"limits": limits, "extra_usage": data.get("extra_usage")}



# ---------------------------------------------------------------------------
# Parser: Claude
# ---------------------------------------------------------------------------
def scan_claude(since: datetime) -> Result:
    res = Result(source="claude")
    if not CLAUDE_DIR.exists():
        res.last_error = f"folder tidak ditemukan: {CLAUDE_DIR}"
        return res

    # cache: {path: {"sig":[mtime,size], "project":..., "entries":[[ts,inp,out,cw,cr,model]...]}}
    cache = _load_cache()
    new_cache: dict = {}

    for path in CLAUDE_DIR.rglob("*.jsonl"):
        try:
            sig = _file_sig(path)
        except OSError:
            continue
        rel = path.relative_to(CLAUDE_DIR)
        project = rel.parts[0]
        key = str(path)
        cached = cache.get(key)
        if cached and cached.get("sig") == list(sig):
            entries = cached["entries"]
        else:
            entries = parse_claude_file(path)
        new_cache[key] = {"sig": list(sig), "project": project, "entries": entries}

    merged = _load_cache()
    merged.update(new_cache)
    _save_cache(merged)

    for meta in new_cache.values():
        project = meta["project"]
        for ts, inp, out, cw, cr, model in meta["entries"]:
            when = parse_iso(ts)
            if when is None or when < since:
                continue
            p = price_for(model, CLAUDE_PRICES, DEFAULT_PRICE)
            cost = (
                inp * p["input"]
                + out * p["output"]
                + cw * p.get("cache_write", p["input"])
                + cr * p.get("cache_read", p["input"] * 0.1)
            ) / 1_000_000
            day = when.strftime("%Y-%m-%d")
            for b in (res.total, res.daily[day], res.models[model], res.projects[project]):
                b.add(inp, out, cw, cr, cost)
    return res


def parse_claude_file(path: Path) -> list:
    """Ekstrak entry usage dari satu file JSONL Claude. Hasil siap masuk cache."""
    entries = []
    seen: set = set()
    try:
        with path.open("r", errors="ignore") as fh:
            for line in fh:
                if '"usage"' not in line or '"assistant"' not in line:
                    continue
                try:
                    obj = json.loads(line)
                except json.JSONDecodeError:
                    continue
                if obj.get("type") != "assistant":
                    continue
                usage = (obj.get("message") or {}).get("usage")
                if not usage:
                    continue
                # dedup: satu requestId + apiBlockIndex dihitung sekali
                rid = obj.get("requestId")
                if rid is not None:
                    k = (rid, obj.get("apiBlockIndex"))
                    if k in seen:
                        continue
                    seen.add(k)
                model = (obj.get("message") or {}).get("model") or "unknown"
                entries.append([
                    obj.get("timestamp", ""),
                    int(usage.get("input_tokens", 0)),
                    int(usage.get("output_tokens", 0)),
                    int(usage.get("cache_creation_input_tokens", 0)),
                    int(usage.get("cache_read_input_tokens", 0)),
                    model,
                ])
    except OSError:
        return []
    return entries


# ---------------------------------------------------------------------------
# Parser: Codex
# ---------------------------------------------------------------------------
def parse_codex_file(path: Path) -> dict:
    """Kembalikan {'model':..., 'events': [[ts, input, output, cached]...], 'rate_limit':...}."""
    model = "gpt-5"
    events = []
    rate_limit = None
    try:
        with path.open("r", errors="ignore") as fh:
            for line in fh:
                if '"token_count"' not in line and '"turn_context"' not in line:
                    continue
                try:
                    obj = json.loads(line)
                except json.JSONDecodeError:
                    continue
                typ = obj.get("type")
                payload = obj.get("payload") or {}
                if typ == "turn_context":
                    model = payload.get("model") or model
                    continue
                if typ != "event_msg" or payload.get("type") != "token_count":
                    continue
                info = payload.get("info")
                if payload.get("rate_limits"):
                    rate_limit = payload["rate_limits"]
                if not info:
                    continue
                t = info.get("total_token_usage") or {}
                events.append([
                    obj.get("timestamp", ""),
                    int(t.get("input_tokens", 0)),
                    int(t.get("output_tokens", 0)),
                    int(t.get("cached_input_tokens", 0)),
                ])
    except OSError:
        return {"model": model, "events": [], "rate_limit": None}
    return {"model": model, "events": events, "rate_limit": rate_limit}


def scan_codex(since: datetime) -> Result:
    res = Result(source="codex")
    if not CODEX_DIR.exists():
        res.last_error = f"folder tidak ditemukan: {CODEX_DIR}"
        return res

    cache = _load_cache()
    new_cache: dict = {}
    for path in CODEX_DIR.rglob("*.jsonl"):
        try:
            sig = _file_sig(path)
        except OSError:
            continue
        key = str(path)
        cached = cache.get(key)
        if cached and cached.get("sig") == list(sig):
            parsed = cached
        else:
            parsed = parse_codex_file(path)
        new_cache[key] = {"sig": list(sig), **parsed}

    # gabung dengan cache Claude yang sudah ditulis sebelumnya (hindari saling hapus)
    merged = _load_cache()
    merged.update(new_cache)
    _save_cache(merged)

    latest_rl_ts = ""
    for meta in new_cache.values():
        model = meta.get("model", "gpt-5")
        events = meta.get("events", [])
        if not events:
            continue
        # total_token_usage kumulatif per sesi -> pakai nilai maksimum per hari, selisih antar hari
        per_day: dict[str, list] = {}
        for ts, inp, out, cr in events:
            day = ts[:10]
            if day not in per_day or inp + out > per_day[day][0] + per_day[day][1]:
                per_day[day] = [inp, out, cr, ts]
        prev_in = prev_out = prev_cr = 0
        for day in sorted(per_day):
            inp_t, out_t, cr_t, ts = per_day[day]
            if inp_t < prev_in:
                prev_in = prev_out = prev_cr = 0
            inp = max(inp_t - prev_in, 0)
            out = max(out_t - prev_out, 0)
            cr = max(cr_t - prev_cr, 0)
            prev_in, prev_out, prev_cr = inp_t, out_t, cr_t
            when = parse_iso(ts)
            if when is None or when < since:
                continue
            uncached = max(inp - cr, 0)
            p = price_for(model, CODEX_PRICES, {"input": 1.25, "output": 10.0, "cache_read": 0.125})
            cost = (uncached * p["input"] + cr * p.get("cache_read", 0.125) + out * p["output"]) / 1_000_000
            for b in (res.total, res.daily[day], res.models[model]):
                b.add(uncached, out, 0, cr, cost)
        # rate limit terbaru diambil dari file yang event-nya paling akhir
        events_all = meta.get("events", [])
        rl_ts = events_all[-1][0] if events_all else ""
        if meta.get("rate_limit") and rl_ts >= latest_rl_ts:
            latest_rl_ts = rl_ts
            res.rate_limit = meta["rate_limit"]
    return res


# ---------------------------------------------------------------------------
# Tampilan
# ---------------------------------------------------------------------------
BOLD = "\033[1m"
DIM = "\033[2m"
RESET = "\033[0m"
GREEN = "\033[32m"
YELLOW = "\033[33m"
CYAN = "\033[36m"
RED = "\033[31m"


def fmt_int(n: int) -> str:
    return f"{n:,}"


def fmt_tok(n: int) -> str:
    if n >= 1_000_000:
        return f"{n/1_000_000:.2f}M"
    if n >= 1_000:
        return f"{n/1_000:.1f}K"
    return str(n)


def fmt_cost(c: float) -> str:
    return f"${c:,.2f}"


def bar(value: float, maxv: float, width: int = 24) -> str:
    if maxv <= 0:
        return ""
    filled = int(round((value / maxv) * width))
    return "█" * filled + "·" * (width - filled)


def print_report(claude: Result, codex: Result, days: int, section: str,
                 claude_limits: dict | None = None):
    now = datetime.now(timezone.utc)
    print(f"{BOLD}usage-mon{RESET} {DIM}· {days} hari terakhir · {now.strftime('%Y-%m-%d %H:%M UTC')}{RESET}")
    print()

    if section in ("overview", "all"):
        print(f"{BOLD}Ringkasan{RESET}")
        header = f"  {'sumber':<10}{'token':>12}{'input':>12}{'output':>12}{'cache':>12}{'biaya':>12}"
        print(DIM + header + RESET)
        grand_tok = grand_cost = 0
        for r in (claude, codex):
            t = r.total
            cache = t.cache_write + t.cache_read
            print(f"  {r.source:<10}{fmt_tok(t.total_tokens):>12}{fmt_tok(t.input):>12}"
                  f"{fmt_tok(t.output):>12}{fmt_tok(cache):>12}{fmt_cost(t.cost):>12}")
            grand_tok += t.total_tokens
            grand_cost += t.cost
        print(DIM + "  " + "-" * 68 + RESET)
        print(f"  {'TOTAL':<10}{fmt_tok(grand_tok):>12}{'':>12}{'':>12}{'':>12}{fmt_cost(grand_cost):>12}")
        for r in (claude, codex):
            if r.last_error:
                print(f"  {YELLOW}! {r.source}: {r.last_error}{RESET}")
        print()

    if section in ("models", "all"):
        print(f"{BOLD}Per model{RESET}")
        for r in (claude, codex):
            if not r.models:
                continue
            print(f"  {CYAN}{r.source}{RESET}")
            unknown = []
            for model, b in sorted(r.models.items(), key=lambda kv: -kv[1].cost):
                table = CLAUDE_PRICES if r.source == "claude" else CODEX_PRICES
                if model != "unknown" and not any(k in model.lower() for k in table):
                    unknown.append(model)
                print(f"    {model:<28}{fmt_tok(b.total_tokens):>10}  {fmt_cost(b.cost):>10}")
            if unknown:
                print(f"    {YELLOW}! tanpa harga khusus (pakai default): {', '.join(unknown)}{RESET}")
        print()

    if section in ("daily", "all"):
        print(f"{BOLD}Tren harian{RESET}")
        for r in (claude, codex):
            if not r.daily:
                continue
            print(f"  {CYAN}{r.source}{RESET}")
            rows = sorted(r.daily.items())
            maxcost = max((b.cost for _, b in rows), default=0)
            for day, b in rows[-14:]:
                b_ = bar(b.cost, maxcost)
                print(f"    {day}  {b_:<24} {fmt_tok(b.total_tokens):>8}  {fmt_cost(b.cost):>10}")
        print()

    if section in ("projects", "all"):
        if claude.projects:
            print(f"{BOLD}Per project (Claude){RESET}")
            top = sorted(claude.projects.items(), key=lambda kv: -kv[1].cost)[:12]
            maxc = max((b.cost for _, b in top), default=0)
            for name, b in top:
                short = name[:36]
                print(f"    {short:<38}{bar(b.cost, maxc, 18)} {fmt_cost(b.cost):>9}")
            print()

    if claude_limits is not None:
        print(f"{BOLD}Limit Claude{RESET}")
        if claude_limits.get("error"):
            print(f"    {YELLOW}! {claude_limits['error']}{RESET}")
            print(f"    {DIM}tips: jalankan `claude` sekali untuk refresh token, lalu coba lagi.{RESET}")
        else:
            for item in claude_limits.get("limits", []):
                print("    " + render_limit_bar(item["label"], item["percent"], item.get("resets_at")))
            eu = claude_limits.get("extra_usage") or {}
            if eu.get("is_enabled"):
                print(f"    {DIM}extra usage aktif{RESET}")
        print()

    if codex.rate_limit:
        print(f"{BOLD}Limit Codex{RESET}")
        rl = codex.rate_limit
        for label, key in (("5 jam", "primary"), ("mingguan", "secondary")):
            w = rl.get(key) or {}
            pct = w.get("used_percent")
            if pct is None:
                continue
            print("    " + render_limit_bar(label, pct, w.get("resets_at"), is_epoch=True))
        plan = rl.get("plan_type")
        if plan:
            print(f"    {DIM}plan: {plan}{RESET}")
        print()


def render_limit_bar(label: str, pct: float, resets_at, is_epoch: bool = False) -> str:
    color = GREEN if pct < 60 else YELLOW if pct < 85 else RED
    width = 24
    filled = int(round(pct / 100 * width))
    b_ = "█" * filled + "·" * (width - filled)
    reset_s = ""
    if resets_at:
        try:
            if is_epoch:
                dt = datetime.fromtimestamp(resets_at, timezone.utc)
            else:
                dt = parse_iso(str(resets_at))
            if dt:
                reset_s = dt.strftime("%m-%d %H:%M")
        except (ValueError, OSError, TypeError):
            reset_s = ""
    return f"{label:<20}{color}{b_}{RESET} {pct:5.1f}%  {DIM}reset {reset_s}{RESET}"


def to_json(claude: Result, codex: Result, days: int, claude_limits: dict | None = None) -> str:
    def dump(r: Result):
        return {
            "source": r.source,
            "total": {
                "input": r.total.input, "output": r.total.output,
                "cache_write": r.total.cache_write, "cache_read": r.total.cache_read,
                "total_tokens": r.total.total_tokens, "cost_usd": round(r.total.cost, 4),
            },
            "daily": {d: {"total_tokens": b.total_tokens, "cost_usd": round(b.cost, 4)}
                      for d, b in sorted(r.daily.items())},
            "models": {m: {"total_tokens": b.total_tokens, "cost_usd": round(b.cost, 4)}
                       for m, b in r.models.items()},
            "projects": {p: {"total_tokens": b.total_tokens, "cost_usd": round(b.cost, 4)}
                         for p, b in r.projects.items()},
            "rate_limit": r.rate_limit,
        }
    return json.dumps({
        "days": days,
        "claude": dump(claude),
        "codex": dump(codex),
        "claude_limits": claude_limits,
    }, indent=2)


def run_once(args) -> None:
    since = datetime.now(timezone.utc) - timedelta(days=args.days)
    claude = scan_claude(since)
    codex = scan_codex(since)

    claude_limits = None
    want_limit = args.section in ("overview", "all")
    if want_limit and not args.no_limit:
        claude_limits = fetch_claude_limits()

    if args.json:
        print(to_json(claude, codex, args.days, claude_limits))
    else:
        print_report(claude, codex, args.days, args.section, claude_limits)


def main() -> int:
    ap = argparse.ArgumentParser(description="Pantau pemakaian token & biaya Claude Code dan Codex.")
    ap.add_argument("--days", type=int, default=7, help="rentang hari ke belakang (default 7)")
    ap.add_argument("--section", choices=["overview", "daily", "models", "projects", "all"], default="all")
    ap.add_argument("--json", action="store_true", help="output JSON")
    ap.add_argument("--prices", action="store_true", help="tampilkan tabel harga yang dipakai")
    ap.add_argument("--no-limit", action="store_true", help="jangan ambil data limit Claude via API")
    ap.add_argument("--watch", type=float, metavar="SEC", help="refresh otomatis tiap N detik")
    args = ap.parse_args()

    load_custom_prices()

    if args.prices:
        print(f"{BOLD}Harga (USD per 1 juta token){RESET}")
        print(f"{CYAN}claude{RESET}  (input / output / cache_write / cache_read)")
        for k, v in CLAUDE_PRICES.items():
            print(f"  {k:<22}{v['input']:>7} /{v.get('output',0):>7} /"
                  f"{v.get('cache_write',0):>7} /{v.get('cache_read',0):>7}")
        print(f"{CYAN}codex{RESET}  (input / output / cache_read)")
        for k, v in CODEX_PRICES.items():
            print(f"  {k:<22}{v['input']:>7} /{v.get('output',0):>7} /{v.get('cache_read',0):>7}")
        print(f"\n{DIM}Override lewat: {PRICES_FILE}{RESET}")
        return 0

    if args.watch:
        try:
            while True:
                os.system("clear")
                run_once(args)
                sys.stdout.flush()
                time.sleep(args.watch)
        except KeyboardInterrupt:
            print()
    else:
        run_once(args)
    return 0


if __name__ == "__main__":
    sys.exit(main())
