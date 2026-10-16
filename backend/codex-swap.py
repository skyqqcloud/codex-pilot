#!/usr/bin/env python3
"""Switch named ChatGPT/Codex logins without logging out."""
from __future__ import annotations

import atexit
import fcntl
import base64
import json
import math
import os
import re
import shutil
import ssl
import subprocess
import sys
import time
import urllib.error
import urllib.parse
import urllib.request
from concurrent.futures import ThreadPoolExecutor, as_completed
from datetime import datetime, timedelta
from pathlib import Path

HOME = Path.home()
AUTH = Path(os.environ.get("CODEX_HOME", str(HOME / ".codex"))).expanduser() / "auth.json"
DATA = HOME / ".codex-swap"
ACCOUNTS = DATA
CURRENT_FILE = DATA / "current"
LOCK = DATA / ".lock"
OPERATION_LOCK = DATA / ".operation.lock"
_LOCK_HANDLE = None
ORDER_FILE = DATA / "order"
CACHE_FILE = DATA / ".quota-cache.json"

USAGE_URL = "https://chatgpt.com/backend-api/wham/usage"
REFRESH_URL = "https://auth.openai.com/oauth/token"
CLIENT_ID = "app_EMoamEEZ73f0CkXaXp7hrann"
TIMEOUT = 8
NAME_RE = re.compile(r"^[A-Za-z0-9][A-Za-z0-9._-]*$")
ANSI_RE = re.compile(r"\033\[[0-9;]*m")


def color_on() -> bool:
    return sys.stdout.isatty() and not os.environ.get("NO_COLOR") and os.environ.get("TERM", "") != "dumb"


def c(code: str, text: str) -> str:
    if not color_on() or not text:
        return text
    return f"\033[{code}m{text}\033[0m"


def vislen(text: str) -> int:
    return len(ANSI_RE.sub("", text))


def pad(text: str, width: int) -> str:
    extra = width - vislen(text)
    return text if extra <= 0 else text + (" " * extra)


def rpad(text: str, width: int) -> str:
    extra = width - vislen(text)
    return text if extra <= 0 else (" " * extra) + text


def pct_cell(n, when: str, when_w: int = 11, muted: bool = False) -> str:
    dim = "2;" if muted else ""
    if n is None:
        body = c("2", "--")
        when_s = ""
    else:
        s = f"{n}%"
        if n <= 10:
            body = c(f"{dim}31", s) if muted else c("1;31", s)
        elif n <= 30:
            body = c(f"{dim}33", s)
        elif n >= 95:
            body = c("2", s) if muted else s
        else:
            body = c(f"{dim}32", s)
        when_s = when or ""
    return rpad(body, 4) + "  " + pad(c("2", when_s), when_w)
COMMANDS = {"save", "add", "delete", "order", "list", "status", "help"}
JSON_MODE = False
NO_APP = False
FETCH = False


def usage() -> None:
    print("Usage:")
    print("  codex-swap.py              list saved accounts (quota from local cache)")
    print("  codex-swap.py --fetch      list and refresh quota from the network")
    print("  codex-swap.py 5            switch to account 5")
    print("  codex-swap.py save 1       save current login as 1")
    print("  codex-swap.py add 20       login a new account as 20 (does not log out)")
    print("  codex-swap.py delete 20    delete saved account 20")
    print("  codex-swap.py order 1 5 20 set display order")
    print("  codex-swap.py quota 5      refresh one account's quota (network)")


def jprint(obj) -> None:
    print(json.dumps(obj, ensure_ascii=False))


def die(msg: str, code: int = 1) -> None:
    if JSON_MODE:
        jprint({"ok": False, "error": msg})
    else:
        print(msg)
    sys.exit(code)


def _pick(d, *keys, default=None):
    if not isinstance(d, dict):
        return default
    for k in keys:
        if k in d and d[k] is not None:
            return d[k]
    return default


def load_auth(path: Path) -> dict:
    with path.open() as f:
        return json.load(f)


def save_auth(path: Path, data: dict) -> None:
    tmp = path.with_suffix(path.suffix + ".tmp")
    with tmp.open("w") as f:
        json.dump(data, f, indent=2)
        f.write("\n")
    os.chmod(tmp, 0o600)
    os.replace(tmp, path)


def copy_auth(src: Path, dst: Path) -> None:
    shutil.copy2(src, dst)
    os.chmod(dst, 0o600)


def write_current(name: str) -> None:
    tmp = ACCOUNTS / ".current.swap"
    tmp.write_text(name + "\n")
    os.replace(tmp, CURRENT_FILE)


def read_current() -> str:
    try:
        return CURRENT_FILE.read_text().strip()
    except FileNotFoundError:
        return ""


def read_order() -> list:
    try:
        return [ln.strip() for ln in ORDER_FILE.read_text().splitlines() if ln.strip()]
    except (FileNotFoundError, OSError):
        return []


def write_order(names: list) -> None:
    ACCOUNTS.mkdir(parents=True, exist_ok=True)
    tmp = ACCOUNTS / f".order.swap.{os.getpid()}"
    tmp.write_text("\n".join(names) + ("\n" if names else ""))
    os.replace(tmp, ORDER_FILE)


def ordered_slots(slots: list) -> list:
    saved = read_order()
    rank = {name: i for i, name in enumerate(saved)}

    def key(n: str):
        if n in rank:
            return (0, rank[n], "")
        if n.isdigit():
            return (1, int(n), "")
        return (2, 0, n)

    return sorted(slots, key=key)


def saved_slot_names() -> list:
    """账号槽文件名——排除缓存等非槽 json（NAME_RE 不允许点开头）。"""
    return [p.stem for p in ACCOUNTS.glob("*.json") if NAME_RE.match(p.stem)]


def read_quota_cache() -> dict:
    try:
        data = json.loads(CACHE_FILE.read_text())
        return data if isinstance(data, dict) else {}
    except (FileNotFoundError, json.JSONDecodeError, OSError):
        return {}


def write_quota_cache(cache: dict) -> None:
    ACCOUNTS.mkdir(parents=True, exist_ok=True)
    tmp = ACCOUNTS / f".quota-cache.swap.{os.getpid()}"
    tmp.write_text(json.dumps(cache, ensure_ascii=False, indent=1) + "\n")
    os.chmod(tmp, 0o600)
    os.replace(tmp, CACHE_FILE)


def valid_plan(value):
    if isinstance(value, str) and re.fullmatch(r"[a-z][a-z0-9_-]{0,63}", value.strip().lower()):
        return value.strip().lower()
    return None


def cached_plan(q: dict, meta: dict):
    # A slot can be replaced with another login; never reuse its previous plan.
    aid = meta.get("account_id")
    if aid and aid != "?" and q.get("account_id") == aid:
        return valid_plan(q.get("plan"))
    return None


def cache_entry(q: dict, previous=None) -> dict:
    previous = previous or {}
    plan = valid_plan(q.get("plan")) or cached_plan(previous, q)
    return {
        "plan": plan,
        "account_id": q.get("account_id"),
        "five": q.get("five"),
        "five_window_seconds": q.get("five_window_seconds"),
        "five_when": q.get("five_remain") or "",
        "five_reset_at": q.get("five_reset_at"),
        "week": q.get("week"),
        "week_window_seconds": q.get("week_window_seconds"),
        "week_when": q.get("week_when") or "",
        "week_reset_at": q.get("week_reset_at"),
        "fetched_at": int(datetime.now().timestamp()),
    }


def fetch_quotas_into_cache(names: list, failures=None) -> dict:
    """Caller holds the operation lock; aliases of one account share one request."""
    failures = failures if failures is not None else []
    cache = read_quota_cache()
    groups = {}
    for name in names:
        path = slot_path(name)
        if not path.is_file():
            failures.append(name)
            continue
        aid = auth_meta(path)["account_id"]
        key = "id:" + aid if aid != "?" else "slot:" + name
        groups.setdefault(key, []).append(path)
    if groups:
        with ThreadPoolExecutor(max_workers=min(4, len(groups))) as executor:
            futures = {executor.submit(quota_for, paths[0]): paths for paths in groups.values()}
            for future in as_completed(futures):
                paths = futures[future]
                try:
                    quota = future.result()
                except Exception:
                    quota = {}
                if quota.get("five") is not None or quota.get("week") is not None or valid_plan(quota.get("plan")):
                    for path in paths:
                        cache[path.stem] = cache_entry(quota, cache.get(path.stem))
                else:
                    failures.extend(path.stem for path in paths)
    write_quota_cache(cache)
    return cache


def next_unused_name(exclude=None) -> str:
    used = {p.stem for p in ACCOUNTS.glob("*.json") if NAME_RE.match(p.stem)}
    if exclude:
        used |= set(exclude)
    i = 1
    while f"n{i}" in used:
        i += 1
    return f"n{i}"


def slot_path(name: str) -> Path:
    return ACCOUNTS / f"{name}.json"


def b64url_json(seg: str):
    seg += "=" * ((4 - len(seg) % 4) % 4)
    return json.loads(base64.urlsafe_b64decode(seg))


def auth_meta(path: Path) -> dict:
    out = {"email": "?", "plan": "?", "account_id": "?", "label": "?"}
    try:
        data = load_auth(path)
        tok = (data.get("tokens") or {}).get("id_token") or ""
        if tok.count(".") < 2:
            return out
        claims = b64url_json(tok.split(".")[1])
        auth = claims.get("https://api.openai.com/auth") or {}
        email = claims.get("email") or "?"
        plan = auth.get("chatgpt_plan_type") or "?"
        aid = auth.get("chatgpt_account_id") or (data.get("tokens") or {}).get("account_id") or "?"
        out = {"email": email, "plan": plan, "account_id": aid, "label": f"{email}  {plan}"}
    except Exception:
        pass
    return out


def http_json(url, headers=None, data=None):
    body = None
    headers = dict(headers or {})
    if data is not None:
        body = urllib.parse.urlencode(data).encode()
        headers.setdefault("Content-Type", "application/x-www-form-urlencoded")
    req = urllib.request.Request(url, data=body, headers=headers)
    ctx = ssl.create_default_context()
    with urllib.request.urlopen(req, timeout=TIMEOUT, context=ctx) as resp:
        raw = resp.read()
        return resp.status, json.loads(raw.decode() if raw else "null")


def auth_headers(data: dict) -> dict:
    tokens = data.get("tokens") or {}
    h = {
        "Authorization": f"Bearer {tokens.get('access_token') or ''}",
        "Accept": "application/json",
        "User-Agent": "codex-cli",
    }
    aid = tokens.get("account_id") or ""
    if aid:
        h["ChatGPT-Account-Id"] = aid
    return h


def refresh(data: dict) -> bool:
    rt = (data.get("tokens") or {}).get("refresh_token")
    if not rt:
        return False
    try:
        _, payload = http_json(
            REFRESH_URL,
            data={
                "grant_type": "refresh_token",
                "refresh_token": rt,
                "client_id": CLIENT_ID,
            },
        )
    except Exception:
        return False
    tokens = data.setdefault("tokens", {})
    if payload.get("access_token"):
        tokens["access_token"] = payload["access_token"]
    if payload.get("id_token"):
        tokens["id_token"] = payload["id_token"]
    if payload.get("refresh_token"):
        tokens["refresh_token"] = payload["refresh_token"]
    return bool(tokens.get("access_token"))


def fetch_usage(data: dict):
    try:
        return http_json(USAGE_URL, headers=auth_headers(data))
    except urllib.error.HTTPError as e:
        body = e.read()
        try:
            payload = json.loads(body.decode() if body else "null")
        except Exception:
            payload = None
        return e.code, payload
    except Exception:
        return None, None


def windows_from_payload(payload):
    if not isinstance(payload, dict):
        return []
    snap = (
        payload.get("rate_limit")
        or payload.get("rateLimit")
        or payload.get("rate_limits")
        or payload.get("rateLimits")
        or payload
    )
    by_id = payload.get("rate_limits_by_limit_id") or payload.get("rateLimitsByLimitId") or {}
    if isinstance(by_id, dict) and isinstance(by_id.get("codex"), dict):
        snap = by_id["codex"]
    if not isinstance(snap, dict):
        return []
    out = []
    for key in ("primary_window", "secondary_window", "primary", "secondary"):
        w = snap.get(key)
        if not isinstance(w, dict):
            continue
        used = _pick(w, "used_percent", "usedPercent")
        seconds = _pick(w, "limit_window_seconds", "limitWindowSeconds")
        minute_value = _pick(w, "window_minutes", "windowDurationMins", "window_duration_mins")
        minutes = None
        value = seconds if seconds is not None else minute_value
        if value is not None and not isinstance(value, bool):
            try:
                n = float(value)
                if math.isfinite(n) and n > 0:
                    minutes = n / 60 if seconds is not None else n
            except (TypeError, ValueError):
                minutes = None
        reset_at = _pick(w, "reset_at", "resets_at", "resetsAt", "resetAt")
        reset_after = _pick(w, "reset_after_seconds", "resetAfterSeconds", "reset_after")
        out.append((used, minutes, reset_at, reset_after))
    return out


def fmt_remain(reset_at, reset_after) -> str:
    secs = None
    if reset_after is not None:
        try:
            secs = float(reset_after)
        except (TypeError, ValueError):
            secs = None
    if secs is None and reset_at is not None:
        try:
            n = float(reset_at)
            if n > 1e12:
                n /= 1000
            secs = n - datetime.now().timestamp()
        except (TypeError, ValueError, OSError):
            secs = None
    if secs is None:
        return ""
    if secs < 0:
        secs = 0
    secs = int(secs)
    days, rem = divmod(secs, 86400)
    hours, rem = divmod(rem, 3600)
    mins = rem // 60
    if days > 0:
        return f"{days}d {hours:>2}h" if hours else f"{days}d"
    if hours > 0:
        return f"{hours}h {mins:>2}m"
    return f"{mins}m"


def fmt_5h_remain(reset_at, reset_after) -> str:
    secs = None
    if reset_after is not None:
        try:
            secs = float(reset_after)
        except (TypeError, ValueError):
            secs = None
    if secs is None and reset_at is not None:
        try:
            n = float(reset_at)
            if n > 1e12:
                n /= 1000
            secs = n - datetime.now().timestamp()
        except (TypeError, ValueError, OSError):
            secs = None
    if secs is None:
        return ""
    if secs < 0:
        secs = 0
    secs = int(secs)
    hours, rem = divmod(secs, 3600)
    mins = rem // 60
    if hours > 0 and mins > 0:
        return f"{hours}h {mins}min"
    if hours > 0:
        return f"{hours}h"
    return f"{mins}min"


def reset_epoch(reset_at, reset_after):
    """统一成 unix 秒，供 GUI 本地倒计时用。"""
    if reset_at is not None:
        try:
            n = float(reset_at)
            return int(n / 1000 if n > 1e12 else n)
        except (TypeError, ValueError, OSError):
            pass
    if reset_after is not None:
        try:
            return int(datetime.now().timestamp() + float(reset_after))
        except (TypeError, ValueError, OverflowError):
            pass
    return None


def fmt_when(reset_at, reset_after) -> str:
    dt = None
    if reset_at is not None:
        try:
            n = float(reset_at)
            if n > 1e12:
                n /= 1000
            dt = datetime.fromtimestamp(n)
        except (TypeError, ValueError, OSError):
            dt = None
    if dt is None and reset_after is not None:
        try:
            dt = datetime.now() + timedelta(seconds=float(reset_after))
        except (TypeError, ValueError, OverflowError):
            dt = None
    if dt is None:
        return ""
    now = datetime.now()
    if dt.date() == now.date():
        return dt.strftime("%H:%M")
    return dt.strftime("%m-%d %H:%M")


def quota_data(payload) -> dict:
    five = week = None
    five_when = week_when = five_remain = ""
    five_reset_at = week_reset_at = None
    five_window_seconds = week_window_seconds = None
    for used, minutes, reset_at, reset_after in windows_from_payload(payload):
        if used is None:
            continue
        try:
            remaining = max(0, min(100, round(100 - float(used))))
        except (TypeError, ValueError):
            continue
        label = None
        if minutes is not None:
            try:
                m = float(minutes)
            except (TypeError, ValueError):
                m = None
            if m is not None:
                if 200 <= m <= 400:
                    label = "5H"
                elif 9000 <= m <= 12000:
                    label = "7D"
        if label is None:
            label = "5H" if five is None else "7D"
        if label == "5H" and five is None:
            five, five_when = remaining, fmt_when(reset_at, reset_after)
            five_remain = fmt_5h_remain(reset_at, reset_after)
            five_reset_at = reset_epoch(reset_at, reset_after)
            five_window_seconds = round(minutes * 60) if minutes is not None else None
        elif label == "7D" and week is None:
            week, week_when = remaining, fmt_remain(reset_at, reset_after)
            week_reset_at = reset_epoch(reset_at, reset_after)
            week_window_seconds = round(minutes * 60) if minutes is not None else None
    return {
        "plan": valid_plan(payload.get("plan_type")) if isinstance(payload, dict) else None,
        "five": five,
        "five_window_seconds": five_window_seconds,
        "five_when": five_when,
        "five_remain": five_remain,
        "five_reset_at": five_reset_at,
        "week": week,
        "week_window_seconds": week_window_seconds,
        "week_when": week_when,
        "week_reset_at": week_reset_at,
    }


def quota_for(path: Path) -> dict:
    empty = {
        "five": None, "five_when": "", "five_remain": "", "five_reset_at": None,
        "week": None, "week_when": "", "week_reset_at": None,
    }
    try:
        aid = auth_meta(path)["account_id"]
        live_source = aid != "?" and AUTH.is_file() and auth_meta(AUTH)["account_id"] == aid
        source = AUTH if live_source else path
        data = load_auth(source)
        original_tokens = dict(data.get("tokens") or {})
        if live_source:
            copy_auth(AUTH, path)
    except Exception:
        return empty
    status, payload = fetch_usage(data)
    if status == 401 and refresh(data):
        # Never overwrite credentials refreshed meanwhile by the desktop client.
        if live_source:
            try:
                latest = load_auth(AUTH)
            except Exception:
                return empty
            if (latest.get("tokens") or {}) != original_tokens:
                data = latest
            else:
                save_auth(AUTH, data)
        for name in saved_slot_names():
            peer = slot_path(name)
            if peer == path or (aid != "?" and auth_meta(peer)["account_id"] == aid):
                save_auth(peer, data)
        status, payload = fetch_usage(data)
    if status != 200: return empty
    if isinstance(payload, dict) and payload.get("account_id") not in (None, aid): return empty
    quota = quota_data(payload)
    quota["account_id"] = aid
    return quota


def running(name: str) -> bool:
    return subprocess.call(["pgrep", "-x", name], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL) == 0


def quit_chatgpt() -> bool:
    subprocess.call(
        ["osascript", "-e", 'tell application "ChatGPT" to quit'],
        stdout=subprocess.DEVNULL,
        stderr=subprocess.DEVNULL,
    )
    subprocess.call(
        ["osascript", "-e", 'tell application "Codex" to quit'],
        stdout=subprocess.DEVNULL,
        stderr=subprocess.DEVNULL,
    )
    for _ in range(40):
        if not running("ChatGPT"):
            break
        time.sleep(0.25)
    if running("ChatGPT"):
        subprocess.call(["killall", "ChatGPT"], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        for _ in range(20):
            if not running("ChatGPT"):
                break
            time.sleep(0.25)
    if running("ChatGPT"):
        return False
    subprocess.call(
        ["pkill", "-f", "/Applications/ChatGPT.app/Contents/"],
        stdout=subprocess.DEVNULL,
        stderr=subprocess.DEVNULL,
    )
    time.sleep(1)
    return True


def open_chatgpt() -> bool:
    if subprocess.call(["open", "-a", "ChatGPT"], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL) != 0:
        subprocess.call(
            ["open", "-b", "com.openai.codex"],
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
        )
    for _ in range(20):
        if running("ChatGPT"):
            break
        time.sleep(0.25)
    if not running("ChatGPT"):
        subprocess.call(["open", "-n", "-a", "ChatGPT"])
        time.sleep(1)
    subprocess.call(
        ["osascript", "-e", 'tell application "ChatGPT" to activate'],
        stdout=subprocess.DEVNULL,
        stderr=subprocess.DEVNULL,
    )
    if running("ChatGPT"):
        if not JSON_MODE:
            print("Opened ChatGPT.")
        return True
    if not JSON_MODE:
        print("ChatGPT failed to launch. Open it from Dock.")
    return False


def acquire_lock() -> None:
    global _LOCK_HANDLE
    if _LOCK_HANDLE is not None:
        return
    ACCOUNTS.mkdir(parents=True, exist_ok=True)
    # Respect an in-flight operation from the older installed version.
    legacy_pid = LOCK / "pid"
    if legacy_pid.is_file():
        try:
            pid = int(legacy_pid.read_text().strip())
            os.kill(pid, 0)
        except (OSError, ValueError):
            pass
        else:
            die("旧版切号工具正在操作账号，请稍后重试。")
    handle = OPERATION_LOCK.open("a+")
    os.chmod(OPERATION_LOCK, 0o600)
    deadline = time.monotonic() + 30
    while True:
        try:
            fcntl.flock(handle, fcntl.LOCK_EX | fcntl.LOCK_NB)
            break
        except BlockingIOError:
            if time.monotonic() >= deadline:
                handle.close()
                die("另一个账号操作尚未完成，请稍后重试。")
            time.sleep(0.1)
    _LOCK_HANDLE = handle
    atexit.register(handle.close)


def require_name(name: str) -> None:
    if not NAME_RE.match(name):
        die("Invalid account name: " + name + "\nUse letters, digits, dot, underscore, hyphen.")


def require_live_auth() -> None:
    if not AUTH.is_file():
        die(f"Missing current auth: {AUTH}\nLog in to one Codex account first.")


def snapshot_if_tagged(current_name: str) -> None:
    dest = slot_path(current_name)
    if dest.is_file():
        live_id = auth_meta(AUTH)["account_id"]
        slot_id = auth_meta(dest)["account_id"]
        if live_id != "?" and slot_id != "?" and live_id != slot_id:
            die(
                f"Live workspace ({auth_meta(AUTH)['label']}) is not account "
                f"'{current_name}' ({auth_meta(dest)['label']}).\n"
                "Tag it first:  codex-swap save <name>\n"
                f"Refusing to overwrite '{current_name}'."
            )
    copy_auth(AUTH, dest)


def list_state(fetch_quota: bool = False) -> dict:
    current = read_current()
    live_meta = auth_meta(AUTH) if AUTH.is_file() else {"email": "?", "plan": "?", "account_id": "?", "label": "?"}
    slots = [p.stem for p in ACCOUNTS.glob("*.json") if NAME_RE.match(p.stem)]

    slots = ordered_slots(slots)
    failures = []
    cache = fetch_quotas_into_cache(slots, failures) if fetch_quota else read_quota_cache()
    rows = []
    for name in slots:
        p = slot_path(name)
        meta = auth_meta(p)
        q = cache.get(name) or {}
        rows.append(
            {
                "name": name,
                "plan": cached_plan(q, meta) or meta["plan"],
                "email": meta["email"],
                "account_id": meta["account_id"],
                "active": name == current and AUTH.is_file() and meta["account_id"] == live_meta["account_id"],
                "five": q.get("five"),
                "five_window_seconds": q.get("five_window_seconds"),
                "five_when": q.get("five_when") or "",
                "five_reset_at": q.get("five_reset_at"),
                "week": q.get("week"),
                "week_window_seconds": q.get("week_window_seconds"),
                "week_when": q.get("week_when") or "",
                "week_reset_at": q.get("week_reset_at"),
                "fetched_at": q.get("fetched_at"),
            }
        )
    warning = None
    if current and slot_path(current).is_file() and AUTH.is_file():
        live_id = live_meta.get("account_id") or "?"
        slot_id = auth_meta(slot_path(current))["account_id"]
        if live_id != "?" and slot_id != "?" and live_id != slot_id:
            warning = (
                f"live workspace is {live_meta.get('label')}, "
                f"but tagged as '{current}' ({auth_meta(slot_path(current))['label']}). "
                "Save the correct name before switching."
            )
    return {
        "ok": True,
        "current": current,
        "auth_exists": AUTH.is_file(),
        "quota_failed": failures,
        "live": {
            "email": live_meta.get("email") or "?",
            "plan": cached_plan(cache.get(current) or {}, live_meta) or live_meta.get("plan") or "?",
            "account_id": live_meta.get("account_id") or "?",
            "label": live_meta.get("label") or "?",
        },
        "warning": warning,
        "slots": rows,
    }


def cmd_list() -> int:
    if FETCH:
        acquire_lock()
    if JSON_MODE:
        jprint(list_state(fetch_quota=FETCH))
        return 0
    current = read_current()
    live_meta = auth_meta(AUTH) if AUTH.is_file() else {"email": "?", "plan": "?", "label": "?"}
    slots = [p.stem for p in ACCOUNTS.glob("*.json") if NAME_RE.match(p.stem)]
    if not current and not slots:
        print("  " + c("2", "(none saved)"))
        print()
        print(c("2", "codex-swap <name> | save <name> | add <name> | delete <name>"))
        return 0

    slots = ordered_slots(slots)
    cache = fetch_quotas_into_cache(slots) if FETCH else read_quota_cache()

    print()
    print(
        "  "
        + c("1", current or "?")
        + "  "
        + (cached_plan(cache.get(current) or {}, live_meta) or live_meta["plan"])
        + "  "
        + c("2", live_meta["email"])
    )
    print()
    w_id, w_plan = 2, 8
    w_5h, w_7d = 11, 13  # 4 + 2 + when(5) / when(7)
    emails = [auth_meta(slot_path(n))["email"] for n in slots]
    w_acct = max(7, max((len(e) for e in emails), default=7))
    gap = "  "

    print(
        "  "
        + " "
        + " "
        + rpad(c("2", "#"), w_id)
        + gap
        + pad(c("2", "plan"), w_plan)
        + gap
        + pad(c("2", "5H"), w_5h)
        + gap
        + pad(c("2", "7D"), w_7d)
        + gap
        + c("2", "account")
    )
    print(
        c(
            "2",
            "  "
            + " "
            + " "
            + ("─" * w_id)
            + gap
            + ("─" * w_plan)
            + gap
            + ("─" * w_5h)
            + gap
            + ("─" * w_7d)
            + gap
            + ("─" * w_acct),
        )
    )
    for name in slots:
        p = slot_path(name)
        meta = auth_meta(p)
        q = cache.get(name) or {}
        active = name == current
        five_clock = fmt_when(q.get("five_reset_at"), None) if q.get("five_reset_at") else (q.get("five_when") or "")
        five = pct_cell(q.get("five"), five_clock, 5, muted=not active)
        week = pct_cell(q.get("week"), q.get("week_when") or "", 7, muted=not active)
        mark = c("1;32", "●") if active else " "
        id_s = rpad(name, w_id)
        id_s = c("1", id_s) if active else c("2", id_s)
        plan_s = pad(cached_plan(q, meta) or meta["plan"], w_plan)
        if not active:
            plan_s = c("2", plan_s)
        email_s = c("1", meta["email"]) if active else c("2", meta["email"])
        print(
            "  "
            + mark
            + " "
            + id_s
            + gap
            + plan_s
            + gap
            + five
            + gap
            + week
            + gap
            + email_s
        )
    if current and slot_path(current).is_file() and AUTH.is_file():
        live_id = auth_meta(AUTH)["account_id"]
        slot_id = auth_meta(slot_path(current))["account_id"]
        if live_id != "?" and slot_id != "?" and live_id != slot_id:
            print()
            print(c("33", "WARNING") + f": live workspace is {auth_meta(AUTH)['label']},")
            print(f"         but tagged as '{current}' ({auth_meta(slot_path(current))['label']}).")
            print("Fix with:  codex-swap save <correct-name>")
            print(f"Do not switch until tagged, or you will overwrite '{current}'.")
    print()
    print(c("2", "  <name>   save <name>   add <name>   delete <name>"))
    return 0


def cmd_save(name: str) -> int:
    require_live_auth()
    acquire_lock()
    dest = slot_path(name)
    if dest.is_file():
        live_id, saved_id = auth_meta(AUTH)["account_id"], auth_meta(dest)["account_id"]
        if live_id != "?" and saved_id != "?" and live_id != saved_id:
            die("当前登录属于另一个账号，请保存为新账号，避免覆盖已有登录。")
    copy_auth(AUTH, dest)
    write_current(name)
    meta = auth_meta(dest)
    if JSON_MODE:
        jprint({"ok": True, "action": "save", "name": name, "plan": meta["plan"], "email": meta["email"]})
        return 0
    print(c("32", "Saved") + f" '{name}' ({meta['label']})")
    return 0


def cmd_delete(name: str) -> int:
    acquire_lock()
    dest = slot_path(name)
    if not dest.is_file():
        die(f"No saved account '{name}'.")
    current = read_current()
    if name == current:
        die(f"Refusing to delete active account '{name}'.\nSwitch away first, then:  codex-swap delete {name}")
    dest.unlink()
    if JSON_MODE:
        jprint({"ok": True, "action": "delete", "name": name})
        return 0
    print(c("33", "Deleted") + f" '{name}'.")
    return 0


def cmd_add(name: str) -> int:
    require_live_auth()
    acquire_lock()
    current = read_current()
    if not current:
        # 新机器/没有 current：先把当前登录自动记为一个槽（避开待添加的名字），再继续
        auto = next_unused_name(exclude={name})
        copy_auth(AUTH, slot_path(auto))
        write_current(auto)
        current = auto
    snapshot_if_tagged(current)
    dest = slot_path(name)
    if not NO_APP:
        if not quit_chatgpt():
            die("ChatGPT is still running. Add aborted.")
    try:
        AUTH.unlink()
    except FileNotFoundError:
        pass
    if not NO_APP:
        open_chatgpt()
    if JSON_MODE:
        jprint(
            {
                "ok": True,
                "action": "add",
                "pending_save": name,
                "kept": current,
                "message": "Log into the new account in ChatGPT. Do NOT click Log out. Then save.",
            }
        )
        return 0
    print(f"Kept current account '{current}' ({auth_meta(slot_path(current))['label']}).")
    if dest.is_file():
        print(f"Existing '{name}' will be replaced after you log in and save.")
    print()
    print("Log into the new account in ChatGPT.")
    print(c("33", "Do NOT click Log out") + " — that revokes other saved accounts.")
    print("When the main window is up:")
    print(c("1;32", f"  codex-swap save {name}"))
    print()
    print(c("2", "Cancel without adding:"))
    print(c("2", f"  cp \"{slot_path(current)}\" \"{AUTH}\" && open -a ChatGPT"))
    print()
    return 0


def cmd_switch(name: str) -> int:
    acquire_lock()
    dest = slot_path(name)
    if not dest.is_file():
        die(f"No saved account '{name}'.\nAdd it with:  codex-swap add {name}")
    current = read_current()
    if not current and AUTH.is_file():
        # 没有 current：先把当前登录自动记为槽，避免直接丢失
        auto = next_unused_name()
        copy_auth(AUTH, slot_path(auto))
        write_current(auto)
        current = auto
    if name == current and AUTH.is_file():
        snapshot_if_tagged(current)
        if JSON_MODE:
            jprint(
                {
                    "ok": True,
                    "action": "switch",
                    "from": current,
                    "to": name,
                    "already": True,
                    "plan": auth_meta(AUTH)["plan"],
                    "email": auth_meta(AUTH)["email"],
                }
            )
            return 0
        print(c("32", "Already using") + f" '{name}' ({auth_meta(AUTH)['label']})")
        return 0
    if not JSON_MODE:
        print(c("1", "Switching"))
        print("  " + c("2", "from") + f"  {current}  {c('2', auth_meta(AUTH)['label'])}")
        print("  " + c("32", "to") + f"    {name}  {auth_meta(dest)['label']}")
    if not NO_APP:
        if not quit_chatgpt():
            die("ChatGPT is still running. Swap aborted.")
    if AUTH.is_file() and current:
        snapshot_if_tagged(current)
    AUTH.parent.mkdir(parents=True, exist_ok=True)
    tmp = AUTH.parent / f".auth.json.swap.{os.getpid()}"
    try:
        copy_auth(dest, tmp)
        os.replace(tmp, AUTH)
    except Exception:
        if tmp.exists():
            tmp.unlink()
        die("Failed to replace active auth.")
    os.chmod(AUTH, 0o600)
    write_current(name)
    meta = auth_meta(AUTH)
    if not JSON_MODE:
        print(c("32", "Swapped") + f"  {name}  ({meta['label']})")
        print()
    if not NO_APP:
        open_chatgpt()
    if JSON_MODE:
        jprint(
            {
                "ok": True,
                "action": "switch",
                "from": current,
                "to": name,
                "already": False,
                "plan": meta["plan"],
                "email": meta["email"],
            }
        )
    return 0


def cmd_quota(name: str) -> int:
    acquire_lock()
    p = slot_path(name)
    if not p.is_file():
        die(f"No saved account '{name}'.")
    q = quota_for(p)
    ok = q.get("five") is not None or q.get("week") is not None or bool(valid_plan(q.get("plan")))
    cache = read_quota_cache()
    if ok:
        cache[name] = cache_entry(q, cache.get(name))
        write_quota_cache(cache)
    cur = cache.get(name) or {}
    five = q.get("five") if ok else cur.get("five")
    five_when = (q.get("five_remain") or "") if ok else (cur.get("five_when") or "")
    five_reset_at = q.get("five_reset_at") if ok else cur.get("five_reset_at")
    week = q.get("week") if ok else cur.get("week")
    week_when = (q.get("week_when") or "") if ok else (cur.get("week_when") or "")
    week_reset_at = q.get("week_reset_at") if ok else cur.get("week_reset_at")
    if JSON_MODE:
        jprint(
            {
                "ok": True,
                "action": "quota",
                "name": name,
                "fresh": ok,
                "plan": cached_plan(cur, auth_meta(p)),
                "five": five,
                "five_window_seconds": cur.get("five_window_seconds"),
                "five_when": five_when,
                "five_reset_at": five_reset_at,
                "week": week,
                "week_window_seconds": cur.get("week_window_seconds"),
                "week_when": week_when,
                "week_reset_at": week_reset_at,
                "fetched_at": cur.get("fetched_at"),
            }
        )
        return 0
    print(f"{name}  5H {five} ({five_when})   7D {week} ({week_when})")
    return 0


def cmd_quotas(names: list) -> int:
    acquire_lock()
    failures = []
    cache = fetch_quotas_into_cache(names, failures)
    rows = []
    for name in names:
        row = dict(cache.get(name) or {})
        row["plan"] = cached_plan(row, auth_meta(slot_path(name))) if slot_path(name).is_file() else None
        row.update(name=name, fresh=name not in failures)
        rows.append(row)
    jprint({"ok": True, "action": "quotas", "quotas": rows, "failed": failures})
    return 0


def cmd_order(names: list) -> int:
    acquire_lock()
    existing = [p.stem for p in ACCOUNTS.glob("*.json") if NAME_RE.match(p.stem)]
    unknown = [n for n in names if n not in existing]
    if unknown:
        die("No saved account: " + ", ".join(unknown))
    seen = set()
    ordered = []
    for n in names:
        if n not in seen:
            seen.add(n)
            ordered.append(n)
    rest = [n for n in ordered_slots(existing) if n not in seen]
    final = ordered + rest
    write_order(final)
    if JSON_MODE:
        jprint({"ok": True, "action": "order", "order": final})
        return 0
    print(c("32", "Order saved") + ": " + "  ".join(final))
    return 0


def main(argv: list[str]) -> int:
    global JSON_MODE, NO_APP, FETCH
    args: list[str] = []
    for a in argv:
        if a == "--json":
            JSON_MODE = True
        elif a == "--no-app":
            NO_APP = True
        elif a == "--fetch":
            FETCH = True
        else:
            args.append(a)
    argv = args
    ACCOUNTS.mkdir(parents=True, exist_ok=True)
    if not argv or argv[0] in {"list", "status"}:
        return cmd_list()
    if argv[0] in {"-h", "--help", "help"}:
        usage()
        return 0
    if argv[0] in {"save", "add", "delete"}:
        if len(argv) != 2:
            die(f"Usage: codex-swap {argv[0]} <name>")
        require_name(argv[1])
        if argv[0] == "save":
            return cmd_save(argv[1])
        if argv[0] == "add":
            return cmd_add(argv[1])
        return cmd_delete(argv[1])
    if argv[0] == "order":
        if len(argv) < 2:
            die("Usage: codex-swap.py order <name> [<name> ...]")
        for n in argv[1:]:
            require_name(n)
        return cmd_order(argv[1:])
    if argv[0] == "quotas":
        if len(argv) < 2:
            die("Usage: codex-swap.py quotas <name> [<name> ...]")
        for name in argv[1:]:
            require_name(name)
        return cmd_quotas(list(dict.fromkeys(argv[1:])))
    if argv[0] == "quota":
        if len(argv) != 2:
            die("Usage: codex-swap.py quota <name>")
        require_name(argv[1])
        return cmd_quota(argv[1])
    if len(argv) != 1:
        usage()
        return 1
    require_name(argv[0])
    return cmd_switch(argv[0])


if __name__ == "__main__":
    try:
        raise SystemExit(main(sys.argv[1:]))
    except KeyboardInterrupt:
        raise SystemExit(130)
