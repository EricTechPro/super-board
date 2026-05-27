"""Tests for super-board-status.py's manifest parser.

Pure stdlib. No pytest dependency, no `gh` auth, no network — runs anywhere
Python 3.10+ runs (matches the CI matrix in `.github/workflows/cross-platform.yml`).

Why these tests exist: the renderer's regexes are the contract between this
script and `scripts/super-board-run.sh`. When the dispatcher's log format
diverges from the parser's expectations, the Workers / Recent / Health
sections silently empty out — which is exactly what happened before these
tests existed (cf. the `attempt=` / `reaped worktree` calibration bugs).
Each test pins one dispatcher log line against the parser's behavior.

Run directly:
  python tests/test_status_parse.py

Exits 0 on success, 1 on the first failure with a traceback.
"""

from __future__ import annotations

import importlib.util
import sys
from pathlib import Path

# The script has a hyphen in its filename, so import via spec_from_file_location.
_REPO_ROOT = Path(__file__).resolve().parent.parent
_SCRIPT = _REPO_ROOT / "scripts" / "super-board-status.py"
_spec = importlib.util.spec_from_file_location("super_board_status", _SCRIPT)
assert _spec is not None and _spec.loader is not None
sbs = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(sbs)

TODAY = "2026-05-27"


def test_dispatch_line_from_real_dispatcher() -> None:
    """The exact format `run.sh:174` emits — no `attempt=` token."""
    manifest = "[08:35:37] dispatch lane=review issue=#25 pid=13960 claim=LucariusWest\n"
    state = sbs.parse_manifest(manifest, TODAY)
    assert "review" in state["inflight"], (
        f"DISPATCH_RE should match the dispatcher's real log line; "
        f"inflight was {state['inflight']!r}"
    )
    assert state["inflight"]["review"]["issue"] == "25"
    assert state["inflight"]["review"]["pid"] == "13960"
    assert state["inflight"]["review"]["ts"] == "08:35:37"
    assert len(state["recents"]) == 1
    assert state["recents"][0]["verb"] == "dispatch"
    assert state["recents"][0]["target"] == "Review"


def test_dispatch_all_three_lanes() -> None:
    """All three known lanes must parse — build, qa, review."""
    manifest = (
        "[10:00:00] dispatch lane=build issue=#1 pid=100 claim=bot\n"
        "[10:05:00] dispatch lane=qa issue=#2 pid=200 claim=bot\n"
        "[10:10:00] dispatch lane=review issue=#3 pid=300 claim=bot\n"
    )
    state = sbs.parse_manifest(manifest, TODAY)
    assert set(state["inflight"].keys()) == {"build", "qa", "review"}


def test_unknown_lane_is_ignored() -> None:
    """A typo'd lane in the manifest must not crash the renderer."""
    manifest = "[10:00:00] dispatch lane=design issue=#5 pid=999 claim=bot\n"
    state = sbs.parse_manifest(manifest, TODAY)
    # design is not in (build|qa|review), so DISPATCH_RE doesn't match and
    # inflight stays empty rather than KeyError'ing on LANE_GLYPH lookup.
    assert state["inflight"] == {}


def test_reap_swept_assignee_variant() -> None:
    """`run.sh:238`: `reaped stale lock + swept assignee on #N (pid=P)`."""
    manifest = "[08:43:43] reaped stale lock + swept assignee on #25 (pid=13960)\n"
    state = sbs.parse_manifest(manifest, TODAY)
    assert state["reaped_count"] == 1
    assert len(state["recents"]) == 1
    assert state["recents"][0]["verb"] == "reap"
    assert state["recents"][0]["issue"] == "#25"


def test_reap_bare_for_variant() -> None:
    """`run.sh:240`: `reaped stale lock for #N (pid=P)` — the other variant."""
    manifest = "[08:43:43] reaped stale lock for #25 (pid=13960)\n"
    state = sbs.parse_manifest(manifest, TODAY)
    assert state["reaped_count"] == 1, (
        "REAP_RE must also match the `for #N` variant, not only `on #N`"
    )
    assert len(state["recents"]) == 1


def test_reap_with_empty_pid() -> None:
    """`pid=${PID:-empty}` can expand to `pid=empty` — must not skip the reap."""
    manifest = "[08:43:43] reaped stale lock for #25 (pid=empty)\n"
    state = sbs.parse_manifest(manifest, TODAY)
    assert state["reaped_count"] == 1
    # pid=empty means we can't drop a specific inflight entry, but the event
    # itself should still show up in Recent.
    assert len(state["recents"]) == 1
    assert state["recents"][0]["verb"] == "reap"


def test_reap_drops_inflight_entry_by_pid() -> None:
    """A reap with a known pid should drop that worker from inflight."""
    manifest = (
        "[08:35:37] dispatch lane=review issue=#25 pid=13960 claim=bot\n"
        "[08:43:43] reaped stale lock + swept assignee on #25 (pid=13960)\n"
    )
    state = sbs.parse_manifest(manifest, TODAY)
    assert state["inflight"] == {}
    assert state["reaped_count"] == 1


def test_lane_handoff_drops_prior_inflight() -> None:
    """Build → QA on the same issue: the build entry must go (no zombie phantom)."""
    manifest = (
        "[10:00:00] dispatch lane=build issue=#7 pid=100 claim=bot\n"
        "[10:30:00] dispatch lane=qa issue=#7 pid=200 claim=bot\n"
    )
    state = sbs.parse_manifest(manifest, TODAY)
    assert "build" not in state["inflight"]
    assert state["inflight"]["qa"]["issue"] == "7"


def test_tick_and_exited_tracked() -> None:
    """`tick —` updates last_tick; `exiting cleanly` flips exited."""
    manifest = (
        "[10:00:00] super-board run started — config=foo\n"
        "[10:02:00] tick — Ready=1 Building=0\n"
        "[10:04:00] tick — Ready=0 Building=1\n"
        "[10:30:00] ✅ all active-pipeline columns empty and all lanes idle — exiting cleanly\n"
    )
    state = sbs.parse_manifest(manifest, TODAY)
    assert state["start_hms"] == "10:00:00"
    assert state["last_tick"] == "10:04:00"
    assert state["exited"] is True


def test_zombie_and_alert() -> None:
    manifest = (
        "[10:00:00] dispatch lane=qa issue=#9 pid=500 claim=bot\n"
        "[10:10:00] 💀 zombie qa worker on #9 (pid=500) — card moved to 'Done'; killing\n"
        "[10:15:00] block-rate alert: 3 of last 5 cards blocked\n"
    )
    state = sbs.parse_manifest(manifest, TODAY)
    assert state["inflight"] == {}, "zombie line should drop the inflight entry"
    verbs = [r["verb"] for r in state["recents"]]
    assert "zombie" in verbs and "alert" in verbs


def test_empty_manifest_returns_defaults() -> None:
    state = sbs.parse_manifest("", TODAY)
    assert state == {
        "inflight": {},
        "recents": [],
        "last_tick": None,
        "start_hms": None,
        "exited": False,
        "reaped_count": 0,
    }


def test_real_live_manifest_lines() -> None:
    """Two-line manifest matching the live NSAdashboard 2026-05-27 board.

    This is the case the original PR shipped broken: with the old
    DISPATCH_RE (`.*attempt=(\\d+)/3`) and the old reap prefix check
    (`reaped worktree`), this manifest produced inflight={} and
    reaped_count=0 — i.e., the headline feature didn't work.
    """
    manifest = (
        "[08:35:37] dispatch lane=review issue=#25 pid=13960 claim=LucariusWest\n"
        "[08:43:43] reaped stale lock + swept assignee on #25 (pid=13960)\n"
    )
    state = sbs.parse_manifest(manifest, TODAY)
    assert state["inflight"] == {}, "the reap drops the dispatched worker"
    assert state["reaped_count"] == 1
    assert len(state["recents"]) == 2
    assert state["recents"][0]["verb"] == "dispatch"
    assert state["recents"][1]["verb"] == "reap"


def test_attempt_str_from_rebuild_label() -> None:
    """`attempt N/3` is derived from the issue's `loop:rebuild-N` label."""
    assert sbs.attempt_str(None) == "1/3"
    assert sbs.attempt_str({"labels": []}) == "1/3"
    assert sbs.attempt_str({"labels": ["loop:rebuild-1"]}) == "2/3"
    assert sbs.attempt_str({"labels": ["loop:rebuild-2"]}) == "3/3"
    # The dispatcher caps rebuilds at 2 in practice, but if a higher count
    # ever appears we should clamp display to 3/3 rather than say 4/3.
    assert sbs.attempt_str({"labels": ["loop:rebuild-5"]}) == "3/3"


def test_field_status_picks_status_select() -> None:
    """`field_status` reads the `Status` single-select; defaults to Backlog."""
    node = {
        "fieldValues": {
            "nodes": [
                {"name": "Building", "field": {"name": "Status"}},
                {"name": "P1", "field": {"name": "Priority"}},
            ]
        }
    }
    assert sbs.field_status(node) == "Building"
    assert sbs.field_status({}) == "Backlog"


# ───────────────────────────── I7: slug sanitization ─────────────────────────────


def test_valid_slug_accepts_normal_slugs() -> None:
    assert sbs.valid_slug("my-project")
    assert sbs.valid_slug("nsadashboard-super-board")
    assert sbs.valid_slug("Project_1.0")
    assert sbs.valid_slug("a")


def test_valid_slug_rejects_path_traversal() -> None:
    assert not sbs.valid_slug("../etc/passwd")
    assert not sbs.valid_slug("..")
    assert not sbs.valid_slug("foo/bar")
    assert not sbs.valid_slug("foo\\bar")  # Windows path separator
    assert not sbs.valid_slug("")
    assert not sbs.valid_slug("foo bar")  # spaces
    assert not sbs.valid_slug("foo\x00bar")  # NUL byte


# ───────────────────────────── I8: title control-char strip ─────────────────────────────


def test_sanitize_title_strips_c0_and_del() -> None:
    """ANSI escapes, BS, CR, NUL — all gone. Visible chars preserved."""
    assert sbs.sanitize_title("normal title") == "normal title"
    assert sbs.sanitize_title("\x1b[2K\rOWNED") == "[2KOWNED"  # ESC + DEL-range bytes go
    assert sbs.sanitize_title("a\x00b\x7fc\tdef") == "abcdef"
    # Unicode (incl. emoji and CJK) must pass through unharmed.
    assert sbs.sanitize_title("漢字 + 🔨 build") == "漢字 + 🔨 build"


# ───────────────────────────── I2: pagination ─────────────────────────────


def _payload(nodes: list[dict], end_cursor: str | None, has_next: bool) -> dict:
    """Build a minimal GraphQL payload shaped like the real ITEMS_QUERY."""
    return {
        "data": {
            "repositoryOwner": {
                "projectV2": {
                    "items": {
                        "pageInfo": {"endCursor": end_cursor, "hasNextPage": has_next},
                        "nodes": nodes,
                    }
                }
            }
        }
    }


def test_paginate_items_single_page() -> None:
    """Project that fits in one page: one fetch, hit_cap=False."""
    calls: list[str | None] = []

    def fetch(after: str | None) -> dict:
        calls.append(after)
        return _payload([{"n": 1}, {"n": 2}], end_cursor=None, has_next=False)

    nodes, hit_cap = sbs.paginate_items(fetch)
    assert nodes == [{"n": 1}, {"n": 2}]
    assert hit_cap is False
    assert calls == [None]  # only the first page, no cursor


def test_paginate_items_multi_page() -> None:
    """Project that spans 3 pages: cursor threads through correctly."""
    pages = [
        _payload([{"n": 1}], end_cursor="cur1", has_next=True),
        _payload([{"n": 2}], end_cursor="cur2", has_next=True),
        _payload([{"n": 3}], end_cursor=None,  has_next=False),
    ]
    calls: list[str | None] = []

    def fetch(after: str | None) -> dict:
        calls.append(after)
        return pages.pop(0)

    nodes, hit_cap = sbs.paginate_items(fetch)
    assert [n["n"] for n in nodes] == [1, 2, 3]
    assert hit_cap is False
    assert calls == [None, "cur1", "cur2"]


def test_paginate_items_respects_max_pages() -> None:
    """Server says hasNextPage forever — we cap and report hit_cap=True."""
    def fetch(after: str | None) -> dict:
        return _payload([{"n": 42}], end_cursor="never-ending", has_next=True)

    nodes, hit_cap = sbs.paginate_items(fetch, max_pages=3)
    assert len(nodes) == 3
    assert hit_cap is True


def test_paginate_items_handles_missing_keys() -> None:
    """Malformed/empty server response shouldn't crash."""
    def fetch(after: str | None) -> dict:
        return {"data": {"repositoryOwner": None}}  # not found

    nodes, hit_cap = sbs.paginate_items(fetch)
    assert nodes == []
    assert hit_cap is False


def test_paginate_items_stops_when_cursor_missing() -> None:
    """has_next=True but endCursor=None: stop rather than loop with `after=None`.

    Without this guard, a server bug could send the loop into an infinite-
    same-page state — `after=None` requests the first page again.
    """
    def fetch(after: str | None) -> dict:
        return _payload([{"n": 1}], end_cursor=None, has_next=True)

    nodes, hit_cap = sbs.paginate_items(fetch)
    assert nodes == [{"n": 1}]
    assert hit_cap is False  # we returned early, not at the cap


def _run() -> int:
    tests = [
        (name, fn) for name, fn in globals().items()
        if name.startswith("test_") and callable(fn)
    ]
    passed = 0
    for name, fn in tests:
        try:
            fn()
        except AssertionError as e:
            print(f"FAIL {name}: {e}", file=sys.stderr)
            return 1
        except Exception as e:
            import traceback
            print(f"ERROR {name}: {e}", file=sys.stderr)
            traceback.print_exc()
            return 1
        passed += 1
        print(f"  ok  {name}")
    print(f"\n{passed}/{len(tests)} passed.")
    return 0


if __name__ == "__main__":
    sys.exit(_run())
