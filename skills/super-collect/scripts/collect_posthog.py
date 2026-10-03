#!/usr/bin/env python3
"""super-collect source `posthog`: product signals through PostHog HogQL. Stdlib, read-only.

    POST {host}/api/projects/{project_id}/query/  {"query":{"kind":"HogQLQuery","query":…}}

Key: POSTHOG_PERSONAL_API_KEY (env, else nearest .env / .env.local), read-only scopes
`query:read` + `error_tracking:read`. Host / project_id / thresholds come from the
config's `collect.posthog` block, falling back to POSTHOG_HOST / POSTHOG_PROJECT_ID.
Never prints the key.

    collect_posthog.py list   [--since 14d|YYYY-MM-DD] [--config cfg.json]
    collect_posthog.py check  <signal> <key> --after YYYY-MM-DD   # verifier: stopped after a fix?
    collect_posthog.py funnel [--since 14d]                       # markdown report, never tickets
    collect_posthog.py ping   [--since 14d]                       # connection test + silent signals
    collect_posthog.py events [--since 14d]                       # event inventory for tracking gaps

`list` runs every signal in SIGNALS (narrow with `collect.posthog.signals`) plus one row
per `collect.posthog.failure_events` entry. Each candidate carries its fingerprint
`posthog|<signal>|<hash of normalised key>`, a category label (error/ux/perf/feature)
and a replay link from the latest matching `$session_id`.

API limits honoured: explicit LIMIT (aggregates only, no OFFSET), one query at a time
(well under 240 req/min, 3 concurrent), each query a single grouped scan (10 s max).

To add a signal, add one row to SIGNALS. Kinds:
  group   — one problem per `group` value; kept when distinct users >= min_users.
  vitals  — p75 of each web-vital per pathname; kept when samples >= min_samples and any
            p75 crosses its limit.
  survey  — raw `survey sent` responses; the agent themes them (>= 3 users per theme).
  failure — built from `collect.posthog.failure_events` (project-defined app failures).
"""
from __future__ import annotations

import argparse
import datetime as dt
import json
import os
import sys
import urllib.error
import urllib.request

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import collect_common as cc  # noqa: E402

LIMIT = 1000
SESSION = "argMax(toString(properties.$session_id), timestamp)"

SIGNALS = {
    "exception": {
        "kind": "group", "event": "$exception",
        # issue_id is PostHog's virtual error-tracking column: it follows issue merges.
        "group": "toString(issue_id)",
        "title": "argMax(coalesce(nullIf(toString(properties.$exception_message), ''), "
                 "nullIf(toString(properties.$exception_types), ''), 'exception'), timestamp)",
        "users": "count(distinct person_id)", "min_users": 5,
        "type": "bug", "category": "error", "label": "Exception:",
        "hint": "Enable exception autocapture: posthog.init(…, { capture_exceptions: true }).",
    },
    "rageclick": {
        "kind": "group", "event": "$rageclick",
        "group": "concat(cutQueryString(toString(properties.$current_url)), ' ', substring(elements_chain, 1, 200))",
        "title": "cutQueryString(any(toString(properties.$current_url)))",
        "users": "count(distinct person_id)", "min_users": 5,
        "type": "bug", "category": "ux", "label": "Rage clicks on",
        "hint": "Rage clicks need autocapture: posthog.init(…, { autocapture: true }).",
    },
    "dead_click": {
        "kind": "group", "event": "$dead_click",
        "group": "concat(cutQueryString(toString(properties.$current_url)), ' ', substring(elements_chain, 1, 200))",
        "title": "cutQueryString(any(toString(properties.$current_url)))",
        "users": "count(distinct person_id)", "min_users": 5,
        "type": "bug", "category": "ux", "label": "Dead clicks on", "triage": True,  # medium-high FP risk
        "hint": "Enable dead clicks: posthog.init(…, { capture_dead_clicks: true }).",
    },
    "web_vitals": {
        "kind": "vitals", "event": "$web_vitals", "group": "toString(properties.$pathname)",
        "min_samples": 50,
        "limits": {"LCP": 4000, "INP": 500, "CLS": 0.25},  # p75; LCP/INP in ms
        "type": "bug", "category": "perf", "label": "Slow page",
        "hint": "Enable web vitals: posthog.init(…, { capture_performance: { web_vitals: true } }).",
    },
    "survey": {
        "kind": "survey", "event": "survey sent", "min_users": 3,
        "type": "feature", "category": "feature", "label": "Survey theme:",
        "hint": "No surveys running; skip unless the project uses PostHog surveys.",
    },
}
DEFAULT_MIN_USERS = 5
DEFAULT_FAILURE_RATE = 0.10


class PostHogError(RuntimeError):
    pass


def settings(cfg):
    s = cc.collect_block(cfg, "posthog")
    key = cc.secret("POSTHOG_PERSONAL_API_KEY")
    pid = str(s.get("project_id") or cc.secret("POSTHOG_PROJECT_ID") or "")
    host = (s.get("host") or cc.secret("POSTHOG_HOST") or "https://us.posthog.com").rstrip("/")
    if not (key and pid):
        raise PostHogError("Missing POSTHOG_PERSONAL_API_KEY (.env) or collect.posthog.project_id (config).")
    host = host.replace(".i.posthog.com", ".posthog.com")  # the ingest host serves no query API
    signals = s.get("signals") or list(SIGNALS)
    unknown = [n for n in signals if n not in SIGNALS]
    if unknown:
        raise PostHogError(f"Unknown collect.posthog.signals: {unknown}; known: {list(SIGNALS)}")
    return {"key": key, "pid": pid, "host": host, "signals": signals,
            "min_users": s.get("min_users"),
            "failure_events": s.get("failure_events") or [],
            "failure_rate": float(s.get("failure_rate", DEFAULT_FAILURE_RATE)),
            "version_property": s.get("version_property"),
            "funnel": s.get("funnel") or []}


def _request(st, path, body=None):
    req = urllib.request.Request(f"{st['host']}{path}", data=json.dumps(body).encode() if body else None,
                                 headers={"Authorization": "Bearer " + st["key"],
                                          "Content-Type": "application/json"})
    try:
        with urllib.request.urlopen(req, timeout=60) as resp:
            return json.load(resp)
    except urllib.error.HTTPError as e:
        raise PostHogError(f"PostHog HTTP {e.code} on {path.split('?')[0]}") from None


def hogql(st, query):
    return _request(st, f"/api/projects/{st['pid']}/query/",
                    {"query": {"kind": "HogQLQuery", "query": query}}).get("results") or []


def lit(s):
    return "'" + str(s).replace("\\", "\\\\").replace("'", "\\'") + "'"


def ts(d):
    return f"toDateTime({lit(d.strftime('%Y-%m-%d %H:%M:%S'))})"


def replay(st, session):
    return f"{st['host']}/project/{st['pid']}/replay/{session}" if session else None


def min_users(st, sig):
    return int(st["min_users"] if st["min_users"] is not None else sig.get("min_users", DEFAULT_MIN_USERS))


def group_query(sig, since, users_min):
    return (f"select {sig['group']} as k, {sig['title']} as t, count() as events, {sig['users']} as users, "
            f"min(timestamp), max(timestamp), {SESSION} from events "
            f"where event = {lit(sig['event'])} and timestamp >= {ts(since)} "
            f"group by k having users >= {int(users_min)} order by users desc limit {LIMIT}")


def vitals_query(sig, since):
    p75 = ", ".join(f"quantile(0.75)(toFloat(properties.$web_vitals_{m}_value))" for m in sig["limits"])
    return (f"select {sig['group']} as k, count() as samples, count(distinct person_id), {p75}, {SESSION} "
            f"from events where event = {lit(sig['event'])} and timestamp >= {ts(since)} "
            f"group by k having samples >= {int(sig['min_samples'])} order by samples desc limit {LIMIT}")


def candidate(st, name, sig, key, title, events, users, first, last, session, **extra):
    c = {"fingerprint": cc.fingerprint("posthog", name, key), "signal": name, "key": key,
         "type": sig["type"], "labels": [sig["category"]] + (["needs-triage"] if sig.get("triage") else []),
         "title": f"{sig['label']} {str(title)[:80]}", "events": int(events or 0), "users": int(users or 0),
         "firstSeen": first, "lastSeen": last, "replay": replay(st, session)}
    c.update(extra)
    return c


def run_signal(st, name, since):
    sig = SIGNALS[name]
    out, extra = [], {}
    if sig["kind"] == "group":
        for k, t, events, users, first, last, session in hogql(st, group_query(sig, since, min_users(st, sig))):
            out.append(candidate(st, name, sig, k, t or k, events, users, first, last, session))
    elif sig["kind"] == "vitals":
        metrics = list(sig["limits"])
        for row in hogql(st, vitals_query(sig, since)):
            k, samples, users, p75s, session = row[0], row[1], row[2], row[3:3 + len(metrics)], row[-1]
            over = {m: v for m, v in zip(metrics, p75s) if v is not None and float(v) > sig["limits"][m]}
            if over:
                out.append(candidate(st, name, sig, k, f"{k} (p75 " + ", ".join(f"{m} {float(v):g}" for m, v in over.items()) + ")",
                                     samples, users, None, None, session, p75=dict(zip(metrics, p75s))))
    elif sig["kind"] == "survey":
        rows = hogql(st, f"select toString(properties.$survey_id), toString(properties.$survey_response), "
                         f"distinct_id, timestamp from events where event = {lit(sig['event'])} "
                         f"and timestamp >= {ts(since)} order by timestamp desc limit {LIMIT}")
        if rows:
            extra["surveyResponses"] = [{"survey": r[0], "response": str(r[1])[:300], "user": r[2], "at": r[3]}
                                        for r in rows]
    return out, extra


def failure_query(entry, since):
    fail = entry.get("fail") or "1"
    return (f"select countIf({fail}), uniqIf(distinct_id, {fail}), uniq(distinct_id), "
            f"minIf(timestamp, {fail}), maxIf(timestamp, {fail}), "
            f"argMaxIf(toString(properties.$session_id), timestamp, {fail}) "
            f"from events where event = {lit(entry['event'])} and timestamp >= {ts(since)}")


def run_failures(st, since):
    sig = {"type": "bug", "category": "error", "label": "Failing:"}
    out = []
    for entry in st["failure_events"]:
        rows = hogql(st, failure_query(entry, since))
        if not rows:
            continue
        events, users, total, first, last, session = rows[0]
        users, total = int(users or 0), int(total or 0)
        rate = users / total if total else 0.0
        threshold = int(entry.get("min_users", st["min_users"] or DEFAULT_MIN_USERS))
        if users >= threshold or (entry.get("fail") and users and rate >= st["failure_rate"]):
            key = f"{entry['event']} {entry.get('fail', '')}".strip()
            out.append(candidate(st, "failure", sig, key, key, events, users, first, last, session,
                                 failureRate=round(rate, 3)))
    return out


def list_signals(st, since):
    out, extra = [], {}
    for name in st["signals"]:
        c, e = run_signal(st, name, since)
        out += c
        extra.update(e)
    out += run_failures(st, since)
    out.sort(key=lambda c: -c["users"])
    return out, extra


def check(st, name, key, after, now=None):
    """Verifier facts. Stopped = zero hits since `after` AND >= 3 days of traffic since then."""
    now = now or dt.datetime.now(cc.UTC)
    if name == "failure":
        event, _, fail = key.partition(" ")
        where = f"event = {lit(event)}" + (f" and ({fail})" if fail else "")
    else:
        sig = SIGNALS[name]
        where = f"event = {lit(sig['event'])}" + (f" and {sig['group']} = {lit(key)}" if "group" in sig else "")
    ver = st.get("version_property")
    vers = f", groupUniqArray(10)(toString(properties.{ver}))" if ver else ""
    rows = hogql(st, f"select count(), count(distinct person_id), max(timestamp){vers} from events "
                     f"where {where} and timestamp >= {ts(after)}")
    row = rows[0] if rows else (0, 0, None, [])
    events = int(row[0] or 0)
    days = (now - after).days
    out = {"signal": name, "key": key, "after": after.isoformat(), "eventsAfter": events,
           "usersAfter": int(row[1] or 0), "lastSeen": row[2], "daysSince": days,
           "stopped": events == 0 and days >= 3}
    if ver:
        out["versionsAfter"] = row[3] if len(row) > 3 else []
    if name == "exception":
        try:
            issue = _request(st, f"/api/environments/{st['pid']}/error_tracking/issues/{key}/")
            out["issueStatus"] = issue.get("status")  # PostHog reopens a resolved issue on recurrence
        except PostHogError as e:
            out["issueStatus"] = f"unknown ({e})"
    return out


def ping(st, since):
    hogql(st, "select 1")
    events = sorted({SIGNALS[n]["event"] for n in st["signals"]} | {e["event"] for e in st["failure_events"]})
    rows = hogql(st, f"select event, count() from events where event in ({', '.join(lit(e) for e in events)}) "
                     f"and timestamp >= {ts(since)} group by event")
    seen = {r[0]: int(r[1]) for r in rows}
    silent = [{"signal": n, "event": SIGNALS[n]["event"], "suggestion": SIGNALS[n]["hint"]}
              for n in st["signals"] if not seen.get(SIGNALS[n]["event"])]
    silent += [{"signal": "failure", "event": e["event"],
                "suggestion": f"No `{e['event']}` events: check the event name or that the app sends it."}
               for e in st["failure_events"] if not seen.get(e["event"])]
    return {"ok": True, "host": st["host"], "project_id": st["pid"], "eventCounts": seen, "silent": silent}


def events(st, since):
    """Every event name seen in the window, for the tracking-gap pass: the agent diffs this
    against the app's routes and capture() calls to find workflows with no success/failure event."""
    rows = hogql(st, f"select event, count(), count(distinct person_id), max(timestamp) from events "
                     f"where timestamp >= {ts(since)} group by event order by count() desc limit {LIMIT}")
    silent = [s["signal"] for s in ping(st, since)["silent"]]
    return {"source": "posthog", "since": since.isoformat(), "silentSignals": silent,
            "events": [{"event": r[0], "count": int(r[1]), "users": int(r[2]), "lastSeen": r[3]} for r in rows]}


def funnel(st, since):
    steps = st["funnel"]
    if not steps:
        return "No `collect.posthog.funnel` steps configured.\n"
    cols = ", ".join(f"uniqIf(person_id, event = {lit(e)})" for e in steps)
    row = (hogql(st, f"select {cols} from events where timestamp >= {ts(since)}") or [[0] * len(steps)])[0]
    lines = [f"# PostHog funnel since {since.date()}", "", "| Step | People | From previous |", "|---|---|---|"]
    prev = None
    for e, n in zip(steps, row):
        n = int(n or 0)
        lines.append(f"| `{e}` | {n} | {f'{100 * n / prev:.0f}%' if prev else '—'} |")
        prev = n
    lines += ["", "Distinct people per event in the window, not an ordered funnel. "
              "Report only: super-collect files no tickets from drop-off or abandonment spikes."]
    return "\n".join(lines) + "\n"


def main(argv=None):
    p = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    p.add_argument("--config")
    sub = p.add_subparsers(dest="cmd", required=True)
    for name in ("list", "funnel", "ping", "events"):
        sub.add_parser(name).add_argument("--since")
    ck = sub.add_parser("check")
    ck.add_argument("signal", choices=list(SIGNALS) + ["failure"])
    ck.add_argument("key")
    ck.add_argument("--after", required=True)
    a = p.parse_args(argv)
    cfg, _ = cc.active_config(a.config)
    try:
        st = settings(cfg)
        if a.cmd == "funnel":
            sys.stdout.write(funnel(st, cc.since(a.since, cc.window_days(cfg))))
            return 0
        if a.cmd == "list":
            since = cc.since(a.since, cc.window_days(cfg))
            cands, extra = list_signals(st, since)
            out = {"source": "posthog", "since": since.isoformat(), "candidates": cands, **extra}
        elif a.cmd == "check":
            out = check(st, a.signal, a.key, cc.since(a.after))
        elif a.cmd == "events":
            out = events(st, cc.since(a.since, cc.window_days(cfg)))
        else:
            out = ping(st, cc.since(a.since, cc.window_days(cfg)))
    except PostHogError as e:
        print(json.dumps({"source": "posthog", "status": "unavailable", "error": str(e)}))
        return 2
    print(json.dumps(out, indent=1, default=str))
    return 0


if __name__ == "__main__":
    sys.exit(main())
