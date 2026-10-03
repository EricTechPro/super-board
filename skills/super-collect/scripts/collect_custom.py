#!/usr/bin/env python3
"""super-collect source `custom`: the extra sources a project added in onboard
("➕ Add another source") — an MCP server, an HTTP API, a CLI command, or a known app.

Each lives in the config's `collect.custom[]` as {name, kind, target, auth_env?, map?}.
This script classifies what the user typed, proves it can be read (read-only) before
it is saved, and turns its output into candidates shaped like every other source's,
so they go through the same verifier and filer (fingerprint `custom|<name>|<key>`).

    collect_custom.py classify "<what the user typed>"
    collect_custom.py ping (--name N | --kind K --target T [--auth-env E]) [--config C]
    collect_custom.py add  --name N --kind K --target T [--auth-env E] [--map JSON] --config C
    collect_custom.py list [--name N] [--since 14d] [--config C]
    collect_custom.py normalize --name N [--config C] < raw.json      (MCP output the agent fetched)

Kinds:
  http  GET the URL (Bearer token from `auth_env` when set); JSON expected.
  cli   run the command (no shell), read stdout: JSON, or one record per distinct line.
        Commands that look like they change something are refused.
  mcp   the script cannot call an MCP server: `ping`/`list` return
        {"status": "agent", ...} and the agent calls the server's read/list tool once
        (limit 1 for ping), then pipes the JSON through `normalize`.
  app   a known app name resolved at classify time to one of the three above.

Output: one JSON object. Exit 0 ok · 2 unreachable / refused · 64 usage.
Secrets: only the named env var is read (collect_common.secret); never printed.
"""
from __future__ import annotations

import argparse
import json
import os
import re
import shlex
import shutil
import subprocess
import sys
import urllib.error
import urllib.request
from collections import OrderedDict

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import collect_common as cc  # noqa: E402

BUILTIN = {"sentry", "posthog", "github", "prs", "architecture"}
# Known apps → how to read them. MCP names are the usual server names; a project whose
# server is called something else types it as "mcp:<name>".
APPS = {
    "linear": ("mcp", "linear", None), "jira": ("mcp", "atlassian", None), "atlassian": ("mcp", "atlassian", None),
    "notion": ("mcp", "notion", None), "asana": ("mcp", "asana", None), "slack": ("mcp", "slack", None),
    "vercel": ("cli", "vercel logs --output json", None), "fly": ("cli", "fly logs --no-tail --json", None),
    "datadog": ("http", "https://api.datadoghq.com/api/v2/logs/events?filter[query]=status:error", "DD_API_KEY"),
    "betterstack": ("http", "https://uptime.betterstack.com/api/v2/incidents", "BETTERSTACK_API_TOKEN"),
    "statuspage": ("http", "https://<page>.statuspage.io/api/v2/incidents.json", None),
}
MUTATING = re.compile(r"\b(rm|mv|dd|kill|delete|destroy|drop|push|deploy|apply|create|update|edit|set|write|"
                      r"publish|merge|reset|truncate|install|uninstall|scale|restart|rollback|promote)\b", re.I)
MAX_CANDIDATES = 50
TIMEOUT = 20


def mcp_servers():
    """Names of the MCP servers Claude Code knows here (names only — values are never read out)."""
    names = set()
    for path in (".mcp.json", os.path.expanduser("~/.claude.json")):
        try:
            data = json.load(open(path))
        except (OSError, ValueError):
            continue
        names |= set((data.get("mcpServers") or {}).keys())
        for proj in (data.get("projects") or {}).values():
            if isinstance(proj, dict):
                names |= set((proj.get("mcpServers") or {}).keys())
    return names


def slug(s):
    return re.sub(r"[^a-z0-9]+", "-", s.lower()).strip("-")[:30] or "custom"


def classify(text):
    t = (text or "").strip()
    low = t.lower()
    if not t:
        return {"kind": None, "error": "empty"}
    if low in BUILTIN:
        return {"kind": "builtin", "name": low, "note": f"{low} is a built-in source — tick it instead"}
    if low.startswith("mcp:"):
        name = t[4:].strip()
        return {"kind": "mcp", "name": slug(name), "target": name}
    if re.match(r"^https?://", low):
        host = re.sub(r"^https?://([^/]+).*", r"\1", low)
        return {"kind": "http", "name": slug(host.split(".")[-2] if host.count(".") else host), "target": t}
    if low in APPS:
        kind, target, auth = APPS[low]
        if kind == "mcp" and target not in mcp_servers() and low in mcp_servers():
            target = low
        out = {"kind": kind, "name": low, "target": target, "app": low}
        if auth:
            out["auth_env"] = auth
        return out
    if low in mcp_servers():
        return {"kind": "mcp", "name": slug(low), "target": t}
    first = shlex.split(t)[0] if t else ""
    if first and shutil.which(first):
        return {"kind": "cli", "name": slug(first), "target": t}
    return {"kind": None, "error": f"couldn't read \"{t}\" — not a link, app, MCP server or command I can run read-only"}


def dig(obj, path):
    for part in (path or "").split("."):
        if not part:
            continue
        if isinstance(obj, dict):
            obj = obj.get(part)
        elif isinstance(obj, list) and part.isdigit() and int(part) < len(obj):
            obj = obj[int(part)]
        else:
            return None
    return obj


def records_of(data, mp):
    if mp.get("items"):
        got = dig(data, mp["items"])
        return got if isinstance(got, list) else []
    if isinstance(data, list):
        return data
    if isinstance(data, dict):
        for v in data.values():
            if isinstance(v, list):
                return v
            if isinstance(v, dict):
                for w in v.values():
                    if isinstance(w, list):
                        return w
    return []


def first(rec, mp, key, names):
    if mp.get(key):
        v = dig(rec, mp[key])
        return v
    for n in names:
        if isinstance(rec, dict) and rec.get(n) not in (None, ""):
            return rec[n]
    return None


def normalize(name, data, mp=None):
    """Raw output → candidates. JSON records are mapped; plain text lines are grouped
    by their normalised form, so one repeating log line is one candidate with a count."""
    mp = mp or {}
    cands = OrderedDict()
    if isinstance(data, str):
        for line in data.splitlines():
            line = line.strip()
            if not line:
                continue
            key = cc.fingerprint("custom", name, line).split("|")[-1]
            c = cands.setdefault(key, {"title": line[:120], "body": line[:2000], "url": None, "count": 0})
            c["count"] += 1
    else:
        for rec in records_of(data, mp):
            if not isinstance(rec, dict):
                rec = {"title": str(rec)}
            title = str(first(rec, mp, "title", ("title", "name", "message", "summary", "subject")) or "")[:200]
            rid = first(rec, mp, "id", ("id", "identifier", "key", "number", "uuid"))
            key = str(rid) if rid is not None else title
            key = cc.fingerprint("custom", name, key).split("|")[-1]
            body = first(rec, mp, "body", ("description", "body", "details", "text"))
            count = first(rec, mp, "count", ("count", "events", "occurrences", "users"))
            c = cands.setdefault(key, {"title": title or key, "body": (str(body)[:2000] if body else ""),
                                       "url": first(rec, mp, "url", ("url", "html_url", "permalink", "link", "shortlink")),
                                       "count": 0})
            c["count"] += int(count) if isinstance(count, (int, float)) else 1
    out = []
    for key, c in list(cands.items())[:MAX_CANDIDATES]:
        out.append({"source": "custom", "name": name, "key": key, "fingerprint": f"custom|{name}|{key}", **c})
    return out, len(cands) > MAX_CANDIDATES


def fetch(src, since=None):
    """Return (status, data or error). status: ok | unavailable | refused | agent."""
    kind, target = src.get("kind"), src.get("target") or ""
    if kind == "mcp":
        return "agent", {"server": target, "how": "call this MCP server's read/list tool (issues, errors or incidents), "
                         "read-only; for a ping, limit 1. Then pipe the JSON into: collect_custom.py normalize --name "
                         + src.get("name", target)}
    if kind == "http":
        if "<" in target:
            return "unavailable", "the URL still has a placeholder — put the real one in"
        req = urllib.request.Request(target, headers={"Accept": "application/json", "User-Agent": "super-collect"})
        if src.get("auth_env"):
            tok = cc.secret(src["auth_env"])
            if not tok:
                return "unavailable", f"key missing: add {src['auth_env']} to .env"
            req.add_header("Authorization", f"Bearer {tok}")
        try:
            with urllib.request.urlopen(req, timeout=TIMEOUT) as r:
                raw = r.read().decode("utf-8", "replace")
        except urllib.error.HTTPError as e:
            if e.code in (401, 403):
                return "unavailable", (f"HTTP {e.code}: it needs a token. Add it to .env"
                                       + (f" as {src['auth_env']}" if src.get("auth_env") else " and give its name (auth_env)")
                                       + ", then test again")
            return "unavailable", f"HTTP {e.code}"
        except (urllib.error.URLError, OSError) as e:
            return "unavailable", f"can't reach it: {getattr(e, 'reason', e)}"
        try:
            return "ok", json.loads(raw)
        except ValueError:
            return "ok", raw
    if kind == "cli":
        if MUTATING.search(target) or re.search(r"[;&|<>`$]", target):
            return "refused", "that command looks like it changes something (or chains commands) — give a read-only one"
        argv = shlex.split(target)
        if not argv or not shutil.which(argv[0]):
            return "unavailable", f"{argv[0] if argv else target} isn't installed here"
        try:
            r = subprocess.run(argv, capture_output=True, text=True, timeout=TIMEOUT, stdin=subprocess.DEVNULL)
        except subprocess.TimeoutExpired:
            return "unavailable", f"timed out after {TIMEOUT}s"
        if r.returncode != 0:
            return "unavailable", f"exit {r.returncode}: {(r.stderr or r.stdout).strip()[:200]}"
        try:
            return "ok", json.loads(r.stdout)
        except ValueError:
            return "ok", r.stdout
    return "unavailable", f"unknown kind {kind!r}"


def find(cfg, name):
    for s in (cc.collect_block(cfg).get("custom") or []):
        if s.get("name") == name:
            return s
    return None


def describe(cands, data):
    n = len(cands)
    if not n:
        return "readable, nothing in it right now"
    noun = "record" if not isinstance(data, str) else "distinct line"
    return f"can read it ({n} {noun}{'s' if n != 1 else ''})"


def emit(obj, code=0):
    print(json.dumps(obj, indent=1))
    return code


def main(argv=None):
    p = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    p.add_argument("--config")
    sub = p.add_subparsers(dest="cmd", required=True)
    c = sub.add_parser("classify")
    c.add_argument("text")
    for verb in ("ping", "add", "list", "normalize"):
        sp = sub.add_parser(verb)
        sp.add_argument("--name")
        sp.add_argument("--kind", choices=["mcp", "http", "cli"])
        sp.add_argument("--target")
        sp.add_argument("--auth-env")
        sp.add_argument("--map")
        sp.add_argument("--since")
        sp.add_argument("--config", dest="config2")
    a = p.parse_args(argv)
    cfg_path = a.config or getattr(a, "config2", None)
    cfg, cfg_path = cc.active_config(cfg_path) if a.cmd != "classify" else ({}, None)

    if a.cmd == "classify":
        res = classify(a.text)
        return emit(res, 0 if res.get("kind") else 2)

    def spec():
        if a.kind and a.target:
            s = {"name": a.name or slug(a.target), "kind": a.kind, "target": a.target}
            if a.auth_env:
                s["auth_env"] = a.auth_env
            if a.map:
                s["map"] = json.loads(a.map)
            return s
        return find(cfg, a.name) if a.name else None

    if a.cmd == "ping":
        s = spec()
        if not s:
            return emit({"status": "unavailable", "error": "no such custom source; pass --kind and --target"}, 64)
        status, data = fetch(s)
        if status == "agent":
            return emit({"name": s["name"], "status": "agent", **data})
        if status != "ok":
            return emit({"name": s["name"], "status": status, "error": data}, 2)
        cands, _ = normalize(s["name"], data, s.get("map"))
        return emit({"name": s["name"], "status": "ok", "count": len(cands), "message": describe(cands, data),
                     "sample": cands[:1]})

    if a.cmd == "add":
        s = spec()
        if not (s and cfg_path):
            return emit({"error": "add needs --name --kind --target and a config"}, 64)
        col = cfg.setdefault("collect", {})
        custom = [x for x in (col.get("custom") or []) if x.get("name") != s["name"]] + [s]
        col["custom"] = custom
        srcs = col.setdefault("sources", [])
        if s["name"] not in srcs:
            srcs.append(s["name"])
        tmp = cfg_path + ".tmp"
        with open(tmp, "w") as f:
            json.dump(cfg, f, indent=2)
            f.write("\n")
        os.replace(tmp, cfg_path)
        return emit({"saved": s, "config": cfg_path})

    if a.cmd == "normalize":
        s = spec() or {"name": a.name or "custom"}
        raw = sys.stdin.read()
        try:
            data = json.loads(raw)
        except ValueError:
            data = raw
        cands, trunc = normalize(s["name"], data, s.get("map"))
        return emit({"source": "custom", "name": s["name"], "truncated": trunc, "candidates": cands})

    if a.cmd == "list":
        targets = [spec()] if a.name or a.target else (cc.collect_block(cfg).get("custom") or [])
        out = {"source": "custom", "since": cc.since(a.since, cc.window_days(cfg)).isoformat(), "sources": []}
        worst = 0
        for s in [t for t in targets if t]:
            status, data = fetch(s, a.since)
            row = {"name": s["name"], "kind": s.get("kind"), "status": status}
            if status == "ok":
                row["candidates"], row["truncated"] = normalize(s["name"], data, s.get("map"))
                row["status"] = "read" if row["candidates"] else "empty"
            elif status == "agent":
                row.update(data)
            else:
                row["error"] = data
                worst = 2
            out["sources"].append(row)
        return emit(out, worst)
    return 64


if __name__ == "__main__":
    sys.exit(main())
