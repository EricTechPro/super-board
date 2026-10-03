"""Shared helpers for the super-collect fetchers. Stdlib only.

- active_config(): the project's super-board config (`.claude/super-board/active`
  -> `configs/<slug>.json`), or the file named by --config.
- secret(name): an env var, else the nearest `.env` / `.env.local` walking up
  from cwd. Only the named key is read; values are never printed.
- since(arg, default_days): `--since 30d` / `--since 2026-09-01` -> aware UTC datetime.
- fingerprint(source, *parts): the stable dedupe key super-collect-file.sh stamps.
"""
from __future__ import annotations

import datetime as dt
import hashlib
import json
import os
import re

UTC = dt.timezone.utc


def _find_up(rel):
    d = os.getcwd()
    while True:
        p = os.path.join(d, rel)
        if os.path.exists(p):
            return p
        parent = os.path.dirname(d)
        if parent == d:
            return None
        d = parent


def active_config(path=None):
    """Return (config dict, path). Empty dict when no config is found."""
    if not path:
        ptr = _find_up(os.path.join(".claude", "super-board", "active"))
        if ptr:
            with open(ptr) as f:
                slug = f.read().strip()
            cand = os.path.join(os.path.dirname(ptr), "configs", f"{slug}.json")
            path = cand if os.path.exists(cand) else None
    if not path:
        return {}, None
    with open(path) as f:
        return json.load(f), path


def collect_block(cfg, source=None):
    block = (cfg or {}).get("collect") or {}
    return block.get(source) or {} if source else block


def secret(name):
    if os.environ.get(name):
        return os.environ[name]
    d = os.getcwd()
    while True:
        for fname in (".env", ".env.local"):
            p = os.path.join(d, fname)
            if os.path.exists(p):
                with open(p) as f:
                    for line in f:
                        line = line.strip()
                        if line.startswith("#") or "=" not in line:
                            continue
                        k, v = line.split("=", 1)
                        if k.strip().removeprefix("export ").strip() == name:
                            v = v.strip().strip('"').strip("'")
                            if v:
                                return v
        parent = os.path.dirname(d)
        if parent == d:
            return ""
        d = parent


def since(arg, default_days=14, now=None):
    now = now or dt.datetime.now(UTC)
    if not arg:
        return now - dt.timedelta(days=int(default_days))
    m = re.fullmatch(r"(\d+)([dhw])", arg.strip())
    if m:
        n, unit = int(m.group(1)), m.group(2)
        return now - {"d": dt.timedelta(days=n), "h": dt.timedelta(hours=n), "w": dt.timedelta(weeks=n)}[unit]
    d = dt.datetime.fromisoformat(arg.strip().replace("Z", "+00:00"))
    return d if d.tzinfo else d.replace(tzinfo=UTC)


def window_days(cfg):
    return int(collect_block(cfg).get("window_days") or 14)


_NOISE = re.compile(r"0x[0-9a-f]+|[0-9a-f]{8,}|\d+")


def normalize(text):
    """Collapse ids, numbers and whitespace so one cause keeps one key across runs."""
    return re.sub(r"\s+", " ", _NOISE.sub("N", (text or "").lower())).strip()[:300]


def fingerprint(source, *parts):
    """`posthog|exception|<hash>` etc. Free text is hashed so the key never holds quotes."""
    safe = []
    for p in parts:
        p = str(p)
        safe.append(p if re.fullmatch(r"[A-Za-z0-9_.:/-]{1,60}", p) else hashlib.sha1(normalize(p).encode()).hexdigest()[:12])
    return "|".join([source, *safe])
