#!/usr/bin/env python3
"""super-board-status.py — read-only live snapshot of the super-board pipeline.

Renders the richer status template defined in
`.claude/skills/super-board/references/status.md` (fixed 80-col Kanban
plus dedicated Workers / Block-reasons / Recent / Health sections).

The same template can be hand-rendered by the model — but the token-by-
token box-drawing takes ≈3 min per invocation, which makes the richer
view impractical in practice. This script renders it in ≈1.3 s by doing
the layout as a single Python pass.

What it does:
  1. Resolve config slug: arg | `.claude/super-board/active` | sole config.
  2. ONE GraphQL call for project items (number, title, labels, Status).
  3. ONE `gh issue view` per Blocked/Skipped card for reason-tag extraction.
  4. Read today's manifest and pipe everything to the locked-template
     renderer that prints the 80-col snapshot matching the spec in
     references/status.md.

What it does NOT do:
  - Any GitHub mutations (read-only verb — same forbidden set as the skill).
  - Touch the manifest, locks, or worktrees.
  - Wait for or poll workers.

Cross-platform: pure Python 3 stdlib + `gh` CLI. Works on macOS, Linux,
Windows (PowerShell / CMD / Git Bash / WSL). No bash, no jq.

Usage:
  python .claude/bin/super-board-status.py [<config-slug>]

Exit codes:
  0  ok
  64 missing arg + no active marker + no single config
  66 config not found
  67 gh / network failure
"""

from __future__ import annotations

import datetime
import json
import re
import subprocess
import sys
import time
import unicodedata
from pathlib import Path
from typing import Any, Callable

# Make box-drawing chars render on Windows consoles too.
try:
    sys.stdout.reconfigure(encoding="utf-8")  # type: ignore[attr-defined]
except Exception:
    pass


# ───────────────────────────── lane constants ─────────────────────────────
# Used by dispatch parsing, kanban glyph lookup, and the workers section.
# Source of truth — never inline these as dict literals at call sites.

LANE_ORDER: tuple[str, ...] = ("build", "qa", "review")
LANE_GLYPH = {"build": "🔨", "qa": "🔍", "review": "✏️"}
LANE_LABEL = {"build": "Building", "qa": "QA", "review": "Review"}
LANE_ROLE = {"build": "Builder ", "qa": "Tester  ", "review": "Reviewer"}


# ───────────────────────────── manifest grammar ─────────────────────────────
# The dispatcher's log format lives in `scripts/super-board-run.sh`. These
# regexes are the contract between the two. When the dispatcher changes a
# log line, update the regex here AND add a fixture to `tests/` so the
# divergence can't sneak back in.

TS_RE = re.compile(r"^\[(\d{2}):(\d{2}):(\d{2})\] (.*)$")
# Dispatcher emits: `dispatch lane=${lane} issue=#${issue} pid=${pid} claim=...`
# Lanes are restricted to the known set so a typo'd lane never reaches the
# LANE_GLYPH / LANE_ORDER lookups below.
DISPATCH_RE = re.compile(r"dispatch lane=(build|qa|review) issue=#(\d+) pid=(\d+)")
# Two reap variants in the dispatcher:
#   `reaped stale lock + swept assignee on #N (pid=P)`
#   `reaped stale lock for #N (pid=P)`
# And `pid=${PID:-empty}` can expand to `pid=empty` when the PID was lost.
REAP_RE = re.compile(r"reaped stale lock\b[^#]*#(\d+) \(pid=(\d+|empty)\)")
ZOMBIE_RE = re.compile(r"zombie [a-z]+ worker on #(\d+) \(pid=(\d+)\)(.*)$")
ALERT_RE = re.compile(r"block-rate alert: (.+)$")


# ───────────────────────────── pure helpers ─────────────────────────────

# Control chars (C0 + DEL) sourced from GitHub-controlled issue titles would
# otherwise reach the terminal verbatim and could redraw the kanban frame
# (e.g. a title containing `\x1b[2K\r`). Strip them at ingestion. Tabs, LF,
# and CR are all in this range — none have a legitimate place in a one-line
# title display anyway.
_CTRL_CHARS_RE = re.compile(r"[\x00-\x1f\x7f]")


def sanitize_title(s: str) -> str:
    return _CTRL_CHARS_RE.sub("", s)


def hms_to_epoch(today_iso: str, hms: str) -> int:
    """Combine an ISO date + HH:MM:SS local time into a Unix epoch.

    Pure: no module state, no I/O. `today_iso` is passed explicitly so the
    manifest parser can be unit-tested with a fixed date.
    """
    try:
        dt = datetime.datetime.strptime(f"{today_iso} {hms}", "%Y-%m-%d %H:%M:%S")
        return int(dt.timestamp())
    except ValueError:
        return 0


def parse_manifest(text: str, today_iso: str) -> dict[str, Any]:
    """Parse a super-board run manifest into structured state.

    Pure function (no I/O, no global state) so it can be unit-tested with
    hand-crafted fixtures. Returns a dict with:
      inflight: {lane → {pid, issue, ts}}    — workers currently dispatched
      recents: [{epoch, verb, glyph, issue, target, detail}, ...]
      last_tick: HH:MM:SS of the most recent `tick —` line, or None
      start_hms: HH:MM:SS of the most recent `super-board run started`, or None
      exited: True if the run has logged `exiting cleanly`
      reaped_count: number of `reaped stale lock ...` lines seen
    """
    inflight: dict[str, dict[str, str]] = {}
    recents: list[dict[str, Any]] = []
    last_tick: str | None = None
    start_hms: str | None = None
    exited = False
    reaped_count = 0

    for line in (text or "").splitlines():
        m = TS_RE.match(line)
        if not m:
            continue
        h, mi, s, rest = m.groups()
        hms = f"{h}:{mi}:{s}"
        ep = hms_to_epoch(today_iso, hms)

        if "super-board run started" in rest:
            start_hms = hms
            exited = False
            continue
        if "exiting cleanly" in rest:
            exited = True
            continue
        if rest.startswith("tick "):
            last_tick = hms
            continue

        if dm := DISPATCH_RE.search(rest):
            lane, issue, pid = dm.groups()
            # Clean lane handoffs (Build → QA → Review) don't emit reap/zombie
            # lines, so the prior lane's inflight entry would otherwise linger
            # and render as a phantom concurrent worker. A fresh dispatch into
            # a later lane for the same issue is proof the earlier lane
            # finished — drop the prior entry before recording the new one.
            for prior in LANE_ORDER[: LANE_ORDER.index(lane)]:
                if inflight.get(prior, {}).get("issue") == issue:
                    del inflight[prior]
            inflight[lane] = {"pid": pid, "issue": issue, "ts": hms}
            recents.append({
                "epoch": ep, "verb": "dispatch", "glyph": LANE_GLYPH[lane],
                "issue": f"#{issue}", "target": LANE_LABEL[lane],
                # `attempt N/3` is filled in at render time from current
                # labels — the manifest doesn't encode it at dispatch time.
                "detail": "",
            })
            continue
        if rm := REAP_RE.search(rest):
            # The dispatcher logs `reaped stale lock ...` for every reap; bump
            # the housekeeping counter here (one branch, not two) and record
            # the event. `pid=empty` matches when the dispatcher couldn't
            # recover the PID from the lock file — in that case we can't drop
            # a specific inflight entry, but the reap is still worth surfacing.
            reaped_count += 1
            issue, pid = rm.groups()
            if pid != "empty":
                for lane, v in list(inflight.items()):
                    if v["pid"] == pid:
                        del inflight[lane]
            recents.append({
                "epoch": ep, "verb": "reap", "glyph": "♻",
                "issue": f"#{issue}", "target": "",
                "detail": "stale lock + assignee swept",
            })
            continue
        if zm := ZOMBIE_RE.search(rest):
            issue, pid, det = zm.groups()
            for lane, v in list(inflight.items()):
                if v["pid"] == pid:
                    del inflight[lane]
            recents.append({
                "epoch": ep, "verb": "zombie", "glyph": "💀",
                "issue": f"#{issue}", "target": "", "detail": det.strip(" —"),
            })
            continue
        if am := ALERT_RE.search(rest):
            recents.append({
                "epoch": ep, "verb": "alert", "glyph": "⚠",
                "issue": "", "target": "", "detail": am.group(1),
            })

    return {
        "inflight": inflight,
        "recents": recents,
        "last_tick": last_tick,
        "start_hms": start_hms,
        "exited": exited,
        "reaped_count": reaped_count,
    }


def visual_width(s: str) -> int:
    """Approximate east-asian-width-aware cell count."""
    w = 0
    for c in s:
        if unicodedata.category(c) == "Mn" or ord(c) == 0xFE0F:
            continue
        if unicodedata.east_asian_width(c) in ("W", "F"):
            w += 2
        elif ord(c) >= 0x2600:  # most symbol/emoji blocks render wide
            w += 2
        else:
            w += 1
    return w


def vpad(s: str, width: int) -> str:
    """Right-pad s with spaces to occupy `width` visual cells."""
    diff = width - visual_width(s)
    return s + (" " * diff) if diff > 0 else s


def truncate_to(s: str, width: int) -> str:
    """Truncate s to <= width visual cells, adding … if shortened."""
    if visual_width(s) <= width:
        return s
    out = ""
    for c in s:
        if visual_width(out + c) > width - 1:
            return out + "…"
        out += c
    return out


def box_top(label: str, count: int) -> str:
    head = f"┌─ {label:<8} [{count}] "
    fill = "─" * (80 - visual_width(head) - 1)
    return head + fill + "┐"


def box_bot() -> str:
    return "└" + ("─" * 78) + "┘"


def box_line(body: str) -> str:
    body = truncate_to(body, 76)
    return f"│ {vpad(body, 76)} │"


def rebuild_count(item: dict[str, Any] | None) -> int:
    """Read `loop:rebuild-N` from labels; 0 if absent."""
    if not item:
        return 0
    for lab in item["labels"]:
        if m := re.match(r"loop:rebuild-(\d+)", lab):
            return int(m.group(1))
    return 0


def attempt_str(item: dict[str, Any] | None) -> str:
    """`attempt N/3` derived from the issue's current `loop:rebuild-N` label."""
    return f"{min(rebuild_count(item) + 1, 3)}/3"


def rebuild_suffix(item: dict[str, Any]) -> str:
    k = rebuild_count(item)
    return f"↻ {min(k + 1, 3)}/3" if k else ""


REASON_TABLE: list[tuple[str, str]] = [
    ("🛡", "dependency gate"),
    ("🔐", "missing creds"),
    ("💳", "quota / billing"),
    ("❓", "ambiguous AC"),
    ("⚙",  "infra / tooling"),
    ("⏭", "skipped"),
]


def reason_for(body: str) -> tuple[str, str]:
    """Pick the leading reason emoji from a comment body; fall back to 🚫."""
    for em, txt in REASON_TABLE:
        if em in body:
            return em, txt
    return "🚫", "other"


def field_status(node: dict[str, Any]) -> str:
    """Read the `Status` single-select field from a project-item node."""
    for fv in (node.get("fieldValues", {}).get("nodes") or []):
        if fv and fv.get("field", {}).get("name") == "Status":
            return fv.get("name") or "Backlog"
    return "Backlog"


# ───────────────────────────── side-effecting helpers ─────────────────────────────

# Slugs are file-system identifiers (configs/<slug>.json, runs/<date>-<slug>.md),
# so we constrain them to a safe character class up front. Without this, a
# slug like `../../../../etc/passwd` would slide through `Path(f"...{slug}...")`
# and let an arg read arbitrary `.json` files relative to CWD. The script is
# read-only so the blast radius is limited, but the read-only contract in
# `status.md` reads stronger than what the unguarded code delivers — close
# the gap here.
_SLUG_RE = re.compile(r"\A[A-Za-z0-9._-]+\Z")


def valid_slug(slug: str) -> bool:
    # `.` and `..` are pure-dot literals that pass the regex's char class but
    # are path-traversal sentinels — reject them explicitly. (`Path(.json)`
    # would land at `.claude/super-board/configs/.json` which still wouldn't
    # escape the configs dir, but the manifest path uses the same slug too
    # and `..` there does escape.)
    if slug in (".", ".."):
        return False
    return bool(_SLUG_RE.match(slug))


def resolve_config_slug(argv: list[str]) -> str:
    if len(argv) > 1 and argv[1]:
        return argv[1]
    active = Path(".claude/super-board/active")
    if active.is_file():
        return active.read_text().strip()
    cfgs = sorted(Path(".claude/super-board/configs").glob("*.json"))
    if len(cfgs) == 1:
        return cfgs[0].stem
    print(f"usage: {argv[0]} <config-slug>  (or set .claude/super-board/active)", file=sys.stderr)
    sys.exit(64)


def gh(*args: str, check: bool = True) -> str:
    """Run gh and return stdout. Exits 67 on failure when check=True."""
    try:
        proc = subprocess.run(
            ["gh", *args], capture_output=True, text=True, encoding="utf-8", check=False
        )
    except FileNotFoundError:
        print("gh CLI not found on PATH", file=sys.stderr)
        sys.exit(67)
    if proc.returncode != 0:
        if check:
            print(f"gh call failed ({' '.join(args[:3])}…)", file=sys.stderr)
            if proc.stderr.strip():
                print(proc.stderr.strip(), file=sys.stderr)
            sys.exit(67)
        return ""
    return proc.stdout


# ───────────────────────────── GraphQL ─────────────────────────────
# Targeted query — number, title, labels, Status only. ~3 KB vs. 100+ KB for
# `gh project item-list --format json` (which slurps every issue body).
# `repositoryOwner(login:)` is the abstract owner; `... on ProjectV2Owner`
# picks the `projectV2` field which both User and Organization implement.
# `$after` is nullable — first page omits the `-F after=…` arg entirely
# (default null) so we don't have to pass a sentinel value.

ITEMS_QUERY = """
query($owner:String!, $number:Int!, $after:String) {
  repositoryOwner(login:$owner) {
    ... on ProjectV2Owner {
      projectV2(number:$number) {
        items(first:100, after:$after) {
          pageInfo { endCursor hasNextPage }
          nodes {
            content { ... on Issue { number title labels(first:20){nodes{name}} } }
            fieldValues(first:8) {
              nodes { ... on ProjectV2ItemFieldSingleSelectValue {
                name field { ... on ProjectV2SingleSelectField { name } } } }
            }
          }
        }
      }
    }
  }
}
"""

# Hard ceiling on pagination depth. 20 pages × 100 items = 2000 cards, which
# is well past any realistic super-board project (the dispatcher's 5000-pt/hr
# GraphQL budget makes a 20-page snapshot a meaningful chunk of quota). If a
# project ever exceeds this, we print a truncation warning rather than loop
# forever on a buggy server response.
MAX_ITEM_PAGES = 20


def paginate_items(
    fetch: Callable[[str | None], dict[str, Any]],
    max_pages: int = MAX_ITEM_PAGES,
) -> tuple[list[dict[str, Any]], bool]:
    """Walk `fetch(after) → graphql_payload` until pagination is exhausted.

    Pure: no I/O of its own — the `fetch` callable does all I/O. Returns
    (all_nodes, hit_cap), where `hit_cap` is True iff we stopped because
    of `max_pages` (i.e., the project is bigger than we surfaced).
    """
    all_nodes: list[dict[str, Any]] = []
    after: str | None = None
    for _ in range(max_pages):
        payload = fetch(after)
        items_section = (
            ((payload.get("data") or {})
                .get("repositoryOwner") or {})
                .get("projectV2") or {}
        ).get("items") or {}
        all_nodes.extend(items_section.get("nodes") or [])
        page_info = items_section.get("pageInfo") or {}
        if not page_info.get("hasNextPage"):
            return all_nodes, False
        after = page_info.get("endCursor")
        if not after:
            return all_nodes, False
    return all_nodes, True


# ───────────────────────────── main ─────────────────────────────


def main() -> int:
    config_slug = resolve_config_slug(sys.argv)
    if not valid_slug(config_slug):
        print(
            f"invalid config slug: {config_slug!r} "
            f"(allowed chars: letters, digits, '.', '_', '-')",
            file=sys.stderr,
        )
        return 64
    config_path = Path(f".claude/super-board/configs/{config_slug}.json")
    if not config_path.is_file():
        print(f"config not found: {config_path}", file=sys.stderr)
        return 66

    cfg = json.loads(config_path.read_text())
    project_owner: str = cfg["project"]["owner"]
    project_number: int = int(cfg["project"]["number"])
    runs_dir = cfg.get("paths", {}).get("runs_dir", "docs/super-board/runs")
    run_date = datetime.date.today().isoformat()
    manifest_path = Path(runs_dir) / f"{run_date}-{config_slug}.md"

    # ── fetch project items (paginated) ──
    def fetch_page(after: str | None) -> dict[str, Any]:
        args = [
            "api", "graphql",
            "-f", f"query={ITEMS_QUERY}",
            "-F", f"owner={project_owner}",
            "-F", f"number={project_number}",
        ]
        if after:
            # First page leaves `$after` unset → GraphQL defaults to null.
            args += ["-F", f"after={after}"]
        out = gh(*args)
        payload: dict[str, Any] = json.loads(out)
        if payload.get("errors"):
            print("graphql returned errors:", file=sys.stderr)
            for err in payload["errors"]:
                print(f"  - {err.get('message')}", file=sys.stderr)
            sys.exit(67)
        return payload

    items_raw, hit_cap = paginate_items(fetch_page)
    if hit_cap:
        print(
            f"warning: stopped after {MAX_ITEM_PAGES * 100} items — "
            f"kanban may not show every card",
            file=sys.stderr,
        )

    items: list[dict[str, Any]] = []
    for n in items_raw:
        c = n.get("content") or {}
        if not c.get("number"):
            continue
        items.append({
            "number": c["number"],
            "title": sanitize_title(c.get("title") or ""),
            "labels": [
                l["name"]
                for l in (c.get("labels", {}).get("nodes") or [])
                if l.get("name")
            ],
            "status": field_status(n),
        })

    by_status: dict[str, list[dict[str, Any]]] = {
        s: sorted([i for i in items if i["status"] == s], key=lambda x: -x["number"])
        for s in ("Ready", "Building", "QA", "Review", "Done", "Blocked", "Skipped")
    }

    # ── fetch reason-tag comments for Blocked + Skipped only ──
    # Skip silently on error so a stale token doesn't break the rest of the
    # snapshot. The body is capped at 4000 chars; emojis in the locked
    # vocabulary land at the top of any well-formed reason-tag comment.
    reasons: dict[int, str] = {}
    for it in by_status["Blocked"] + by_status["Skipped"]:
        n = it["number"]
        out = gh("issue", "view", str(n), "--json", "comments", check=False)
        if not out:
            continue
        try:
            comments = json.loads(out).get("comments") or []
        except json.JSONDecodeError:
            continue
        comments.sort(key=lambda c: c.get("createdAt", ""))
        body = (comments[-1].get("body") if comments else "") or ""
        reasons[n] = body[:4000]

    # ── parse manifest ──
    manifest_text = manifest_path.read_text() if manifest_path.is_file() else ""
    now_epoch = int(time.time())
    state = parse_manifest(manifest_text, run_date)
    inflight = state["inflight"]
    recents = state["recents"][-5:][::-1]  # last 5, newest first
    last_tick = state["last_tick"]
    start_hms = state["start_hms"]
    exited = state["exited"]
    reaped_count = state["reaped_count"]

    # ── tiny closures over items / inflight / now_epoch ──
    def item_by_number(n: int) -> dict[str, Any] | None:
        return next((i for i in items if i["number"] == n), None)

    def glyph_for_issue(n: int) -> str:
        for lane, v in inflight.items():
            if v["issue"] == str(n):
                return LANE_GLYPH[lane]
        return "  "

    def worker_dur(hms: str) -> str:
        d = now_epoch - hms_to_epoch(run_date, hms)
        if d < 3600:
            return f"{d // 60}m"
        if d < 86400:
            return f"{d // 3600}h"
        return f"{d // 86400}d"

    def delta_ago(hms: str | None) -> str:
        if not hms:
            return "?"
        d = now_epoch - hms_to_epoch(run_date, hms)
        if d < 90:
            return f"{d}s ago"
        if d < 5400:
            return f"{d // 60}m ago"
        if d < 86400:
            return f"{d // 3600}h {(d % 3600) // 60}m ago"
        return f"{d // 86400}d ago"

    def t_minus(ep: int) -> str:
        d = now_epoch - ep
        if d < 60:
            return "T-1m" if d >= 30 else "T-0m"
        if d < 3600:
            return f"T-{d // 60}m"
        if d < 86400:
            return f"T-{d // 3600}h"
        return f"T-{d // 86400}d"

    def reason_for_issue(n: int) -> tuple[str, str]:
        return reason_for(reasons.get(n, ""))

    # ── header ──
    proj = cfg["project"]
    mode_label = "human-approves" if cfg.get("human_approves_merge") else "auto-merge"
    tg = cfg.get("truth_gate", "off")
    tt = cfg.get("truth_threshold", 70)
    gate_label = {"off": "off", "always": "always"}.get(tg, f"non-trivial (≥{tt})")
    bot_login = (
        cfg.get("notifications", {}).get("bot_identity")
        or cfg.get("claim", {}).get("assignee_login")
        or "?"
    )
    max_workers = cfg.get("max_workers", 3)

    print(f"📊 super-board · {proj['title']} (#{proj['number']})")
    print("─" * 80)
    print(f"config: {config_slug}   variant: {cfg.get('variant', '?')}   base: {cfg.get('base_branch', '?')}")
    print(f"mode:   {mode_label:<22} truth gate: {gate_label}")
    print()

    # ── kanban ──
    def render_lane(label: str, lane_items: list[dict[str, Any]]) -> str:
        out = [box_top(label, len(lane_items))]
        if not lane_items:
            out.append(box_line("(empty)"))
        else:
            for it in lane_items:
                n = it["number"]
                glyph = glyph_for_issue(n)
                left = f"{glyph} #{n}  {it['title']}"
                suffix = rebuild_suffix(it)
                if suffix:
                    budget = 76 - visual_width(suffix) - 1
                    if visual_width(left) > budget:
                        left = truncate_to(left, budget)
                    pad = 76 - visual_width(left) - visual_width(suffix)
                    if pad < 1:
                        pad = 1
                    out.append(box_line(left + (" " * pad) + suffix))
                else:
                    out.append(box_line(left))
        out.append(box_bot())
        return "\n".join(out)

    print(render_lane("Ready",    by_status["Ready"]))
    print(render_lane("Building", by_status["Building"]))
    print(render_lane("QA",       by_status["QA"]))
    print(render_lane("Review",   by_status["Review"]))

    # Done: single collapsed line.
    done = by_status["Done"]
    print(box_top("Done", len(done)))
    if not done:
        print(box_line("(empty)"))
    else:
        nums = [f"#{x['number']}" for x in done]
        tail = "   (squash-merged, collapsed)"
        full = " ".join(nums) + tail
        if visual_width(full) <= 76:
            print(box_line(full))
        else:
            accum: list[str] = []
            for i, x in enumerate(nums):
                remaining = len(nums) - i - 1
                candidate = " ".join(accum + [x])
                proposed = candidate + (f" … +{remaining} more" if remaining > 0 else "") + tail
                if visual_width(proposed) > 76:
                    break
                accum.append(x)
            remaining = len(nums) - len(accum)
            body = " ".join(accum) + (f" … +{remaining} more" if remaining > 0 else "") + tail
            print(box_line(body))
    print(box_bot())

    def render_blocklane(label: str, lane_items: list[dict[str, Any]]) -> str:
        out = [box_top(label, len(lane_items))]
        if not lane_items:
            out.append(box_line("(empty)"))
        else:
            for it in lane_items:
                em, _ = reason_for_issue(it["number"])
                out.append(box_line(f"{em} #{it['number']}  {it['title']}"))
        out.append(box_bot())
        return "\n".join(out)

    print(render_blocklane("Blocked", by_status["Blocked"]))
    print(render_blocklane("Skipped", by_status["Skipped"]))

    # ── workers ──
    print()
    active = len(inflight)
    run_active = bool(last_tick) and not exited

    if not run_active and active == 0:
        print(f"▎Workers  (claim: {bot_login})")
        print("   (no active run — `super-board run` to start)")
    else:
        print(f"▎Workers  (claim: {bot_login} · {active}/{max_workers} active)")
        if active == 0:
            print("   (idle)")
        else:
            for lane in sorted(inflight, key=LANE_ORDER.index):
                v = inflight[lane]
                glyph = LANE_GLYPH[lane]
                role = LANE_ROLE[lane]
                item = item_by_number(int(v["issue"]))
                extras: list[str] = []
                if item:
                    extras = [
                        l for l in item["labels"]
                        if l.startswith("loop:") and not l.startswith("loop:in-")
                    ]
                extra = (" · " + ", ".join(extras)) if extras else ""
                print(
                    f"   {glyph} {role}  #{v['issue']}  attempt {attempt_str(item)} · "
                    f"{worker_dur(v['ts'])}{extra}"
                )

    # ── block reasons ──
    print()
    print("▎Block reasons")
    blockers = by_status["Blocked"] + by_status["Skipped"]
    if not blockers:
        print("   (none)")
    else:
        groups: dict[str, dict[str, Any]] = {}
        for it in blockers:
            em, txt = reason_for_issue(it["number"])
            g = groups.setdefault(em, {"text": txt, "issues": []})
            g["issues"].append(f"#{it['number']}")
        for em, g in sorted(groups.items(), key=lambda kv: -len(kv[1]["issues"])):
            issues_str = ", ".join(g["issues"])
            print(f"   {em} ×{len(g['issues'])}  {g['text']:<18}  {issues_str}")

    # ── recent events ──
    print()
    print("▎Recent  (last 5 manifest events)")
    if not recents:
        print("   (no manifest events yet)")
    else:
        for r in recents:
            t = t_minus(r["epoch"])
            # Dispatch detail (`attempt N/3`) is filled in at render time
            # because the manifest doesn't encode the rebuild count at
            # dispatch time — the number shown reflects the issue's *current*
            # label. Live workers in the §Workers block above use the same
            # source, so the two stay consistent with each other.
            detail = r["detail"]
            if r["verb"] == "dispatch" and not detail:
                issue_num = int(r["issue"].lstrip("#"))
                detail = f"attempt {attempt_str(item_by_number(issue_num))}"
            if r["target"]:
                print(
                    f"   {t:<7} {r['glyph']} {r['verb']:<9} {r['issue']:<4} → "
                    f"{r['target']:<9} {detail}"
                )
            else:
                print(
                    f"   {t:<7} {r['glyph']} {r['verb']:<9} {r['issue']:<4}   "
                    f"        {detail}"
                )

    # ── health ──
    print()
    print("▎Health")
    if run_active:
        print(
            f"   last tick: {delta_ago(last_tick)}    run started: {delta_ago(start_hms)}"
            f"    workers: {active}/{max_workers}    worktrees cleaned: {reaped_count}"
        )
    elif exited and start_hms:
        print(
            f"   last run: completed {delta_ago(last_tick or start_hms)}    "
            f"workers: 0/{max_workers} idle"
        )
    else:
        print(f"   no run today    workers: 0/{max_workers} idle")

    return 0


if __name__ == "__main__":
    sys.exit(main())
