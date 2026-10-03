#!/usr/bin/env python3
"""super-collect source `sentry`: pull unresolved issues through the Sentry REST API.

Stdlib only, read-only. Ported from BookKeepingApp's sentry-bug-hunt/sentry_issues.py.
Token: SENTRY_AUTH_TOKEN (env, else nearest .env / .env.local), scopes event:read
project:read. Org / project / host / environment come from the config's
`collect.sentry` block, falling back to SENTRY_ORG / SENTRY_PROJECT / SENTRY_URL.
Never prints the token.

    collect_sentry.py list  [--since 14d|YYYY-MM-DD] [--limit 100] [--config cfg.json]
    collect_sentry.py event <issue_id> [--which recommended|latest|oldest]
    collect_sentry.py tags  <issue_id>
    collect_sentry.py check <issue_id> [--after YYYY-MM-DD]     # verifier: still happening?
    collect_sentry.py ping                                      # onboarding connection test

`list` prints {"source":"sentry","since":…,"candidates":[…]} sorted by urgency; each
candidate carries its fingerprint `err|sentry|<id>`. Issues under the config's
`min_events` / `min_users` thresholds are dropped.
HTTP 429 is retried with backoff (Retry-After when sent).
"""
from __future__ import annotations

import argparse
import datetime as dt
import json
import math
import os
import re
import sys
import time
import urllib.error
import urllib.parse
import urllib.request

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import collect_common as cc  # noqa: E402

EMAIL = re.compile(r"[\w.+-]+@[\w-]+\.[\w.-]+")


class SentryError(RuntimeError):
    pass


def settings(cfg):
    s = cc.collect_block(cfg, "sentry")
    token = cc.secret("SENTRY_AUTH_TOKEN")
    org = s.get("org") or cc.secret("SENTRY_ORG")
    project = s.get("project") or cc.secret("SENTRY_PROJECT")
    base = (s.get("host") or cc.secret("SENTRY_URL") or "https://sentry.io").rstrip("/")
    if not (token and org):
        raise SentryError("Missing SENTRY_AUTH_TOKEN (.env) or collect.sentry.org (config). "
                          "Token needs scopes event:read, project:read.")
    return {"token": token, "org": org, "project": project, "base": base,
            "env": s.get("environment", "production"),
            "min_events": int(s.get("min_events", 1)), "min_users": int(s.get("min_users", 1))}


def api(st, path, params=None, retries=5):
    url = st["base"] + path + ("?" + urllib.parse.urlencode(params, doseq=True) if params else "")
    req = urllib.request.Request(url, headers={"Authorization": f"Bearer {st['token']}"})
    for attempt in range(retries + 1):
        try:
            with urllib.request.urlopen(req, timeout=45) as r:
                return json.load(r)
        except urllib.error.HTTPError as e:
            if e.code == 429 and attempt < retries:
                wait = e.headers.get("Retry-After") if e.headers else None
                wait = float(wait) if wait and wait.replace(".", "", 1).isdigit() else 2 ** (attempt + 1)
                print(f"Sentry API 429 on {path}; retrying in {wait:.0f}s", file=sys.stderr)
                time.sleep(min(wait, 60))
                continue
            raise SentryError(f"Sentry API HTTP {e.code} on {path}") from None
    raise SentryError(f"Sentry API gave up on {path}")


def env_params(st, extra=None):
    p = dict(extra or {})
    if st["env"]:
        p["environment"] = st["env"]
    return p


def parse_ts(s):
    return dt.datetime.fromisoformat(s.replace("Z", "+00:00")) if s else None


def score(issue, now):
    """Urgency: users weigh most, then window volume, then live and new/regressed status."""
    users = int(issue.get("userCount") or 0)
    events = int(issue.get("count") or 0)
    last24 = sum(b[1] for b in (issue.get("stats") or {}).get("24h", []))
    last = parse_ts(issue.get("lastSeen"))
    active = bool(last and (now - last).total_seconds() < 48 * 3600)
    s = 3 * math.log2(1 + users) + 2 * math.log2(1 + events) + math.log2(1 + last24)
    s += 3 if active else 0
    s += 2 if issue.get("substatus") in ("new", "regressed", "escalating") else 0
    s += 2 if issue.get("level") == "fatal" or issue.get("isUnhandled") else 0
    return round(s, 2), active, last24


def list_issues(st, since, limit=100, now=None):
    now = now or dt.datetime.now(cc.UTC)
    params = {"statsPeriod": f"{max(1, (now - since).days)}d", "groupStatsPeriod": "24h",
              "query": "is:unresolved", "sort": "user", "limit": str(limit)}
    if st["project"]:
        params["project"] = api(st, f"/api/0/projects/{st['org']}/{st['project']}/")["id"]
    raw = api(st, f"/api/0/organizations/{st['org']}/issues/", env_params(st, params))
    out = []
    for i in raw if isinstance(raw, list) else []:
        events, users = int(i.get("count") or 0), int(i.get("userCount") or 0)
        if events < st["min_events"] or users < st["min_users"]:
            continue
        s, active, last24 = score(i, now)
        out.append({
            "fingerprint": f"err|sentry|{i.get('id')}",
            "score": s, "id": i.get("id"), "shortId": i.get("shortId"),
            "title": i.get("title"), "culprit": i.get("culprit"), "level": i.get("level"),
            "unhandled": i.get("isUnhandled"), "substatus": i.get("substatus"),
            "events": events, "users": users, "events24h": last24,
            "firstSeen": i.get("firstSeen"), "lastSeen": i.get("lastSeen"),
            "stillHappening": active, "permalink": i.get("permalink"),
        })
    out.sort(key=lambda x: -x["score"])
    return out


def frames(exc):
    st = (exc.get("stacktrace") or {}).get("frames") or []
    keep = [f for f in st if f.get("inApp")] or st[-5:]
    return [{"file": f.get("filename") or f.get("absPath"), "line": f.get("lineNo"),
             "function": f.get("function")} for f in reversed(keep)]


def event(st, issue_id, which="recommended"):
    e = api(st, f"/api/0/organizations/{st['org']}/issues/{issue_id}/events/{which}/", env_params(st))
    entries = {x.get("type"): x.get("data") for x in e.get("entries", [])}
    rel = e.get("release")
    return {
        "eventId": e.get("eventID"), "dateCreated": e.get("dateCreated"), "title": e.get("title"),
        "release": rel.get("version") if isinstance(rel, dict) else rel,
        "tags": {t["key"]: t["value"] for t in e.get("tags", []) if t.get("key") not in ("user", "user.email")},
        "request": {"method": (entries.get("request") or {}).get("method"),
                    "url": (entries.get("request") or {}).get("url")},
        "exceptions": [{"type": x.get("type"), "value": EMAIL.sub("<email>", str(x.get("value") or "")),
                        "frames": frames(x)}
                       for x in (entries.get("exception") or {}).get("values", [])],
        "breadcrumbs": [{"ts": b.get("timestamp"), "category": b.get("category"),
                         "message": EMAIL.sub("<email>", str(b.get("message") or ""))[:200]}
                        for b in ((entries.get("breadcrumbs") or {}).get("values") or [])[-15:]],
    }


def tags(st, issue_id):
    raw = api(st, f"/api/0/organizations/{st['org']}/issues/{issue_id}/tags/", env_params(st))
    return {t.get("key"): [(v.get("value"), v.get("count")) for v in t.get("topValues", [])[:5]]
            for t in raw if t.get("key") not in ("user", "user.email")}


def check(st, issue_id, after=None):
    """Verifier facts: status, resolution release, last seen, and whether it fired after `after`."""
    i = api(st, f"/api/0/organizations/{st['org']}/issues/{issue_id}/")
    last = parse_ts(i.get("lastSeen"))
    details = i.get("statusDetails") or {}
    release = details.get("inRelease")
    released = None
    if isinstance(release, str) and release:
        try:
            r = api(st, f"/api/0/organizations/{st['org']}/releases/{urllib.parse.quote(release, safe='')}/")
            released = parse_ts(r.get("dateReleased") or r.get("dateCreated"))
        except SentryError:
            released = None
    return {
        "id": i.get("id"), "status": i.get("status"), "substatus": i.get("substatus"),
        "resolvedIn": release or details.get("inCommit") or details.get("inNextRelease"),
        "releaseDate": released.isoformat() if released else None,
        # resolved in a release and not seen since it shipped → already fixed
        "seenAfterRelease": bool(last and released and last > released) if released else None,
        "lastSeen": i.get("lastSeen"), "events": int(i.get("count") or 0),
        "after": after.isoformat() if after else None,
        "seenAfter": bool(last and after and last > after) if after else None,
        "permalink": i.get("permalink"),
    }


def main(argv=None):
    p = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    p.add_argument("--config")
    sub = p.add_subparsers(dest="cmd", required=True)
    lp = sub.add_parser("list")
    lp.add_argument("--since")
    lp.add_argument("--limit", type=int, default=100)
    ev = sub.add_parser("event")
    ev.add_argument("issue_id")
    ev.add_argument("--which", default="recommended", choices=["recommended", "latest", "oldest"])
    tg = sub.add_parser("tags")
    tg.add_argument("issue_id")
    ck = sub.add_parser("check")
    ck.add_argument("issue_id")
    ck.add_argument("--after")
    sub.add_parser("ping")
    a = p.parse_args(argv)
    cfg, _ = cc.active_config(a.config)
    try:
        st = settings(cfg)
        if a.cmd == "list":
            since = cc.since(a.since, cc.window_days(cfg))
            out = {"source": "sentry", "since": since.isoformat(), "candidates": list_issues(st, since, a.limit)}
        elif a.cmd == "event":
            out = event(st, a.issue_id, a.which)
        elif a.cmd == "tags":
            out = tags(st, a.issue_id)
        elif a.cmd == "check":
            out = check(st, a.issue_id, cc.since(a.after) if a.after else None)
        else:
            path = f"/api/0/projects/{st['org']}/{st['project']}/" if st["project"] else f"/api/0/organizations/{st['org']}/"
            api(st, path)
            out = {"ok": True, "org": st["org"], "project": st["project"], "host": st["base"]}
    except SentryError as e:
        print(json.dumps({"source": "sentry", "status": "unavailable", "error": str(e)}))
        return 2
    print(json.dumps(out, indent=1, default=str))
    return 0


if __name__ == "__main__":
    sys.exit(main())
