"""Format tests for the writing standard (skills/super-board/references/writing-standard.md).

Pins the shapes scripts and agents depend on: the commit subject, the ticket's required
sections, the comment header, the PR body markers. Each test reads the shipped docs and
scripts, so a template that drifts from the standard fails here.

Run directly:  python3 tests/test_writing_format.py
"""

from __future__ import annotations

import re
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
REF = ROOT / "skills" / "super-board" / "references"
STANDARD = (REF / "writing-standard.md").read_text(encoding="utf-8")

EMOJI = {
    "feat": "✨", "fix": "🐛", "chore": "🔧", "refactor": "♻️", "test": "🧪", "perf": "⚡",
    "docs": "📝", "ci": "👷", "ui": "💄", "security": "🔒", "revert": "⏪", "wip": "🚧",
}
SUBJECT = re.compile(
    r"^(?P<emoji>✨|🐛|🔧|♻️|🧪|⚡|📝|👷|💄|🔒|⏪|🚧) \[(?P<type>feat|fix|chore|refactor|test|perf|docs|ci|ui|security|revert|wip)\] "
    r"[a-z0-9][a-z0-9._/-]*: \S"
)
COMMENT_HEADER = re.compile(
    r"^\[(builder|qa|reviewer|collect|orchestrator)\] \[(blocker|issue|suggestion|nit|question|praise|report)\] \S"
)
TICKET_SECTIONS = ["Problem", "Context", "Fix", "Acceptance Criteria", "Risk", "Blocked by"]
EVIDENCE_ROWS = [
    "Error + stack", "Request / trace ID", "Sentry", "PostHog replay", "Logs", "Screenshots",
    "HAR / API sample", "Env + release", "First / last seen", "Users affected", "Steps",
    "Expected / actual",
]
PR_BLOCKS = ["status", "problem", "solution", "ac", "history", "visual", "risk"]


def subject_ok(s: str) -> bool:
    m = SUBJECT.match(s)
    return bool(m) and EMOJI[m["type"]] == m["emoji"] and len(s) <= 72


def fenced(text: str) -> list[str]:
    return re.findall(r"```[a-z]*\n(.*?)```", text, flags=re.S)


# ── commit ───────────────────────────────────────────────────────────────────

def test_subject_regex():
    good = [
        "🐛 [fix] receipts: show a size error over 10 MB",
        "🔧 [chore] loop: close #42 — stream replies",
        "🚧 [wip] loop: #42 partial — schema only",
        "🧪 [test] super-qa: iter 3 (2 bugs, 9 items, 1 PRs opened)",
        "💄 [ui] reports: before/after screenshots",
    ]
    bad = [
        "fix(receipts): show a size error",          # conventional commits
        "🐛 fix receipts: show a size error",          # no brackets
        "✨ [fix] receipts: show a size error",        # emoji does not match type
        "🐛 [bugfix] receipts: show a size error",     # unknown type
        "🐛 [fix] Receipts: show a size error",        # scope not lowercase
        "🐛 [fix] receipts: " + "x" * 80,              # too long
    ]
    for s in good:
        assert subject_ok(s), f"should pass: {s}"
    for s in bad:
        assert not subject_ok(s), f"should fail: {s}"


def test_emoji_map_matches_standard():
    rows = dict((t, e) for e, t in re.findall(r"^\| (\S+) \| `([a-z]+)` \|", STANDARD, flags=re.M))
    assert rows == EMOJI, f"writing-standard.md emoji table drifted: {rows}"
    claude_md = (ROOT / "CLAUDE.md").read_text(encoding="utf-8")
    for t, e in EMOJI.items():
        assert f"{e} {t}" in claude_md, f"CLAUDE.md writing table lacks '{e} {t}'"


def test_standard_examples_are_valid_subjects():
    seen = 0
    for block in fenced(STANDARD):
        first = block.splitlines()[0] if block.strip() else ""
        if re.match(r"^[^\s\[<]\S* \[[a-z]+\] ", first):
            if re.match(r"^\S+ \[(bug|feat|ui|test|docs|refactor|security)\] ", first) and "## Problem" in block:
                continue  # a ticket title, checked below
            assert subject_ok(first), f"example subject is off-standard: {first}"
            seen += 1
    assert seen >= 1, "expected a commit example in writing-standard.md"


def test_dispatcher_greps_the_standard_loop_subjects():
    src = (ROOT / "skills" / "super-build" / "scripts" / "super-build-dispatch.sh").read_text(encoding="utf-8")
    pats = re.findall(r'grep -E "\^\[0-9a-f\]\+ (.*?)" \| head', src)
    assert len(pats) == 2, f"expected the close and wip greps, found {pats}"
    close_pat, wip_pat = (p.replace("$N", "42").replace("\\\\", "\\") for p in pats)

    def grep(pat: str, subject: str) -> bool:
        r = subprocess.run(["grep", "-E", "^[0-9a-f]+ " + pat], input=f"abc123 {subject}\n",
                           capture_output=True, text=True)
        return r.returncode == 0

    assert grep(close_pat, "🔧 [chore] loop: close #42 — add streaming")
    assert not grep(close_pat, "🔧 [chore] loop: close #421 — other card")
    assert grep(wip_pat, "🚧 [wip] loop: #42 partial — schema only")
    assert grep(close_pat, "chore(loop): close #42 — legacy branch")


def test_no_old_commit_shapes_in_templates():
    old = re.compile(r"chore\(loop\)|wip\(loop\)|fix\(super-qa\)|feat\(super-qa\)|refine\(\$?\{?[a-z<]")
    allowed = {"super-build-dispatch.sh"}  # documents and still accepts the legacy shapes
    for p in list((ROOT / "skills").rglob("*.md")) + list((ROOT / "skills").rglob("*.sh")) + list((ROOT / "workflows").glob("*.js")):
        if p.name in allowed or "visual" in p.parts:
            continue
        for n, line in enumerate(p.read_text(encoding="utf-8").splitlines(), 1):
            assert not old.search(line), f"old commit shape at {p.relative_to(ROOT)}:{n}: {line.strip()}"


# ── ticket ───────────────────────────────────────────────────────────────────

def headings(text: str) -> list[str]:
    return re.findall(r"^## (.+?)\s*$", text, flags=re.M)


def test_ticket_template_has_required_sections_in_order():
    for name, text in [("ticket-format.md", (REF / "ticket-format.md").read_text(encoding="utf-8")),
                       ("writing-standard.md example", next(b for b in fenced(STANDARD) if "## Problem" in b and "## Blocked by" in b))]:
        h = [x for x in headings(text) if x in TICKET_SECTIONS]
        assert h == TICKET_SECTIONS, f"{name}: sections {h} != {TICKET_SECTIONS}"
        assert re.search(r"^- \[ \] ", text, flags=re.M), f"{name}: Acceptance Criteria must be a checklist"
        assert re.search(r"^- \*\*Where:\*\*.*\n(  - [a-z]\. .+\n)+", text, flags=re.M), f"{name}: Context needs lettered steps under Where"


def test_bug_filer_matches_the_standard():
    src = (ROOT / "scripts" / "super-qa-file-bug.sh").read_text(encoding="utf-8")
    for s in ["Problem", "Context", "Evidence", "Fix", "Acceptance Criteria", "Risk"]:
        assert f'"{s}"' in src, f"super-qa-file-bug.sh does not require {s}"
    rows = re.search(r'EVIDENCE_ROWS="([^"]+)"', src)[1].split("|")
    assert rows == [r.lower() for r in EVIDENCE_ROWS], f"filer evidence rows drifted: {rows}"
    table = re.findall(r"^\| ([A-Za-z][^|]+?) \| ", STANDARD.split("**Bug Evidence**", 1)[1], flags=re.M)
    table = [t for t in table if t != "Row"][:12]
    assert table == EVIDENCE_ROWS, f"writing-standard.md evidence rows drifted: {table}"


def test_ticket_title_shape():
    title = re.compile(r"^(🐛 \[bug\]|✨ \[feat\]|💄 \[ui\]|🧪 \[test\]|📝 \[docs\]|♻️ \[refactor\]|🔒 \[security\]) [a-z0-9][a-z0-9._/-]*: \S")
    assert title.match("🐛 [bug] receipts: spinner never stops over 10 MB")
    assert not title.match("🐛 Bug /imports — CSV upload silently drops rows")
    src = (ROOT / "scripts" / "super-qa-file-bug.sh").read_text(encoding="utf-8")
    assert 'FULL_TITLE="${BADGE} ${SCOPE}: ${TITLE}"' in src


# ── comment ──────────────────────────────────────────────────────────────────

def test_comment_header_regex():
    assert COMMENT_HEADER.match("[qa] [report] ❌ failing · round 1")
    assert COMMENT_HEADER.match("[reviewer] [blocker] 🛑 blocked · 🔐 missing key")
    assert not COMMENT_HEADER.match("🔍 super-board · QA fail · v1")
    assert not COMMENT_HEADER.match("[QA] [report] ❌ failing")
    assert not COMMENT_HEADER.match("[qa] [fyi] ❌ failing")


def test_comment_examples_follow_the_header():
    """Every comment sample in the standard and run.md starts with a valid header, ≤ 8 prose lines."""
    machine = re.compile(r"^(Local tests|gh-quota-on-exit|blocked-by|root-cause-hash):|^\||^$|^<!--")
    run_md = (REF / "run.md").read_text(encoding="utf-8")
    checked = 0
    for text in (STANDARD, run_md):
        for block in fenced(text):
            lines = block.splitlines()
            lines = [l for l in lines if not l.startswith("<!-- super-review:report")]
            if not lines or not re.match(r"^\[[a-z<]", lines[0]) or lines[0].startswith("[<"):
                continue
            assert COMMENT_HEADER.match(lines[0]), f"bad comment header: {lines[0]}"
            prose = [l for l in lines if not machine.match(l)]
            assert len(prose) <= 8, f"comment over 8 lines: {lines[0]}"
            checked += 1
    assert checked >= 6, f"expected comment samples, checked {checked}"


def test_block_template_uses_the_header():
    text = (REF / "block-template.md").read_text(encoding="utf-8")
    heads = [b.splitlines()[0] for b in fenced(text) if b.startswith("[")]
    assert heads, "block-template.md has no header line"
    for h in heads:
        assert re.match(r"^\[(<role>|builder|qa|reviewer|collect|orchestrator)\] \[blocker\] \S", h), h
    assert "Reason tag:" in text, "super-board-deps.sh parses 'Reason tag:'"


# ── PR body ──────────────────────────────────────────────────────────────────

def test_pr_body_markers():
    out = subprocess.run(["bash", str(ROOT / "scripts" / "super-board-pr-body.sh"), "--skeleton"],
                         capture_output=True, text=True, check=True).stdout
    for b in PR_BLOCKS:
        assert f"<!-- sb:{b} -->" in out and f"<!-- /sb:{b} -->" in out, f"skeleton lacks {b}"
    run_md = (REF / "run.md").read_text(encoding="utf-8")
    for b in ["status", "problem", "solution", "ac", "history", "risk"]:
        assert f"<!-- sb:{b} -->" in run_md and f"<!-- /sb:{b} -->" in run_md, f"run.md PR template lacks {b}"
    assert "## Not verified" not in run_md and "**Status:**" not in run_md


def test_status_alerts():
    for alert in ("> [!NOTE]", "> [!TIP]", "> [!WARNING]"):
        assert alert in STANDARD, f"writing-standard.md lacks {alert}"


TESTS = [v for k, v in sorted(globals().items()) if k.startswith("test_") and callable(v)]

if __name__ == "__main__":
    failed = 0
    for t in TESTS:
        try:
            t()
            print(f"  ✅ {t.__name__}")
        except AssertionError as e:
            failed += 1
            print(f"  ❌ {t.__name__}: {e}")
    print(f"\n{len(TESTS) - failed}/{len(TESTS)} passed.")
    sys.exit(1 if failed else 0)
