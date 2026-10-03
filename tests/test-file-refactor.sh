#!/usr/bin/env bash
# Tests scripts/super-review-file-refactor.sh. Deterministic, no network: `gh`
# is a stub on PATH. Covers arg validation, fingerprint dedupe, Backlog
# placement, and the guarantee that board failures never fail the script —
# a mergeable PR must not be stranded because a card would not place.
#
#   bash tests/test-file-refactor.sh

set -uo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SCRIPT="$REPO_ROOT/scripts/super-review-file-refactor.sh"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

PASS=0
FAIL=0
ok()  { PASS=$((PASS + 1)); printf '  ✅ %s\n' "$1"; }
bad() { FAIL=$((FAIL + 1)); printf '  ❌ %s\n     expected: %s\n     actual:   %s\n' "$1" "$2" "$3"; }
is()  { [ "$2" = "$3" ] && ok "$1" || bad "$1" "$2" "$3"; }
has() { case "$2" in *"$3"*) ok "$1" ;; *) bad "$1" "contains: $3" "$2" ;; esac; }

cat > "$WORK/config.json" <<'JSON'
{"version":1,"project":{"owner":"acme","title":"Board","number":7},
 "variant":"full","repo":{"path":".","remote":"https://github.com/acme/app.git"}}
JSON

# The Reviewer's part of the ticket format (writing-standard.md § 3).
printf '## Problem\nShallow module: interface nearly as complex as implementation.\n\n## Context\n- **Where:** `src/order-intake.ts`\n\n## Fix\nDeepen OrderIntake behind one entry point.\n' > "$WORK/body.md"

# ── gh stub. Behaviour switches on env so each case stays declarative.
#   DEDUPE_HIT   — issue number the fingerprint search should return ("" = none)
#   STATUS_OPTS  — Status option names the board exposes
#   FAIL_ITEMADD — non-empty makes `project item-add` fail
cat > "$WORK/gh" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$GH_LOG"
case "$1 ${2:-}" in
  "issue list")    echo "${DEDUPE_HIT:-}" ;;
  "issue comment") exit 0 ;;
  "issue create")
    # Keep the rendered body. The command log holds a temp path, not its
    # contents, so without this a test cannot see what was actually filed.
    prev=""
    for a in "$@"; do
      [ "$prev" = "--body-file" ] && [ -r "$a" ] && cat "$a" > "$BODY_LOG"
      prev="$a"
    done
    echo "https://github.com/acme/app/issues/412" ;;
  "label create")  exit 0 ;;
  "project item-add")
    [ -n "${FAIL_ITEMADD:-}" ] && exit 1
    echo "PVTI_stub" ;;
  "project view")  echo "PVT_stub" ;;
  "project field-list")
    OPTS=""
    for encoded in ${STATUS_OPTS:-Backlog Ready Done}; do
      name=$(echo "$encoded" | tr '_' ' ')
      OPTS="${OPTS}{\"id\":\"opt_${encoded}\",\"name\":\"${name}\"},"
    done
    echo "{\"fields\":[{\"id\":\"FLD_status\",\"name\":\"Status\",\"options\":[${OPTS%,}]}]}" ;;
  "project item-edit") exit 0 ;;
  *) exit 0 ;;
esac
STUB
chmod +x "$WORK/gh"
export PATH="$WORK:$PATH"
export GH_LOG="$WORK/gh.log"
BODY_LOG="$WORK/body.filed"
export BODY_LOG

run() { : > "$GH_LOG"; "$SCRIPT" "$@" 2>"$WORK/err"; }

echo "── arg validation"
DEDUPE_HIT="" run --config "$WORK/config.json" --title T --body-file "$WORK/body.md" >/dev/null
is "fingerprint required" 64 "$( DEDUPE_HIT="" "$SCRIPT" --config "$WORK/config.json" --title T --body-file "$WORK/body.md" >/dev/null 2>&1; echo $? )"
is "title required"       64 "$( DEDUPE_HIT="" "$SCRIPT" --config "$WORK/config.json" --fingerprint f --body-file "$WORK/body.md" >/dev/null 2>&1; echo $? )"
is "config must exist"    66 "$( DEDUPE_HIT="" "$SCRIPT" --config /nope.json --title T --fingerprint f --body-file "$WORK/body.md" >/dev/null 2>&1; echo $? )"
is "body-file must exist" 66 "$( DEDUPE_HIT="" "$SCRIPT" --config "$WORK/config.json" --title T --fingerprint f --body-file /nope.md >/dev/null 2>&1; echo $? )"
is "strength is an enum"  64 "$( DEDUPE_HIT="" "$SCRIPT" --config "$WORK/config.json" --title T --fingerprint f --body-file "$WORK/body.md" --strength huge >/dev/null 2>&1; echo $? )"

echo "── happy path"
OUT=$(DEDUPE_HIT="" run --config "$WORK/config.json" --title "OrderIntake is shallow" \
  --body-file "$WORK/body.md" --fingerprint "OrderIntake|shallow" --files "src/a.ts,src/b.ts" \
  --strength strong --pr 99)
is  "returns the new issue number" "412" "$OUT"
has "files render as a list"       "$(cat "$GH_LOG")" "issue create"
has "lands in Backlog, not Ready"  "$(cat "$GH_LOG")" "opt_Backlog"
has "labels the source"            "$(cat "$GH_LOG")" "source:review"
has "labels the strength"          "$(cat "$GH_LOG")" "strength:strong"
has "title in ticket format"       "$(cat "$GH_LOG")" "♻️ [refactor] orderintake: OrderIntake is shallow"
printf 'just a note\n' > "$WORK/nosections.md"
is "refuses a body without Problem/Context/Fix" 66 "$( DEDUPE_HIT="" "$SCRIPT" --config "$WORK/config.json" --title T --fingerprint f --body-file "$WORK/nosections.md" >/dev/null 2>&1; echo $? )"

echo "── dedupe"
OUT=$(DEDUPE_HIT="301" run --config "$WORK/config.json" --title "Seen before" \
  --body-file "$WORK/body.md" --fingerprint "OrderIntake|shallow" --pr 99)
is  "returns the existing issue" "301" "$OUT"
has "comments instead of creating" "$(cat "$GH_LOG")" "issue comment 301"
case "$(cat "$GH_LOG")" in
  *"issue create"*) bad "no duplicate card created" "no 'issue create'" "found one" ;;
  *) ok "no duplicate card created" ;;
esac

echo "── the two machine-read sections, and where the card lands"

# A card filed mid-wave by an agent is the one most likely to arrive without a
# `## Blocked by` section or acceptance criteria. Six did on 2026-08-21 and every
# one had to be completed by hand before the loop could pick it up.

# 1 — a bare note gains BOTH sections, and lands in the holding column. `Ready`
#     feeds the Builder lane, and a card nobody wrote criteria for is not
#     buildable no matter how good the prose is.
printf '## Problem\nThe Window rule is written twice.\n\n## Context\n- **Where:** `src/window.ts`\n\n## Fix\nOne rule.\n' > "$WORK/bare.md"
OUT=$(DEDUPE_HIT="" STATUS_OPTS="Backlog Ready Done" run --config "$WORK/config.json" \
  --title "Bare note" --body-file "$WORK/bare.md" --fingerprint "bare|note")
has "appends Blocked by when absent"      "$(cat "$BODY_LOG")" "## Blocked by"
has "states None explicitly"              "$(cat "$BODY_LOG")" "- None."
has "appends a criteria placeholder"      "$(cat "$BODY_LOG")" "## Acceptance Criteria"
has "appends a Risk line"                 "$(cat "$BODY_LOG")" "## Risk"
has "sends a bare note to the holding column" "$(cat "$GH_LOG")" "opt_Backlog"

# 2 — a card that already carries criteria is buildable, so it goes straight to
#     Ready and the next wave takes it.
printf '## Problem\nBody.\n\n## Context\n- **Where:** `src/x.ts`\n\n## Fix\nOne.\n\n## Acceptance Criteria\n\n- [ ] one real thing\n\n## Risk\n🟢 **Low** · one file.\n\n## Blocked by\n\n- None.\n' > "$WORK/full.md"
OUT=$(DEDUPE_HIT="" STATUS_OPTS="Backlog Ready Done" run --config "$WORK/config.json" \
  --title "Complete card" --body-file "$WORK/full.md" --fingerprint "full|card")
has "a card with criteria lands in Ready" "$(cat "$GH_LOG")" "opt_Ready"
case "$(grep -c '## Blocked by' "$BODY_LOG")" in
  1) ok "does not duplicate a section the caller wrote" ;;
  *) bad "does not duplicate a section the caller wrote" "1" "$(grep -c '## Blocked by' "$BODY_LOG")" ;;
esac

# 3 — THE ONE THAT MATTERS. The fallback chain degrades DOWNWARD in commitment.
#     A holding-column request on a board with no holding column must never land
#     in Ready: that would build a note nobody graded. Briefly it did.
OUT=$(DEDUPE_HIT="" STATUS_OPTS="Ready Done" run --config "$WORK/config.json" \
  --title "No holding column" --body-file "$WORK/bare.md" --fingerprint "no|holding")
case "$(cat "$GH_LOG")" in
  *opt_Ready*) bad "a bare note must never fall back into Ready" "no opt_Ready" "found it" ;;
  *) ok "a bare note never falls back into Ready" ;;
esac

echo "── degradation (must never fail the review)"
# A board with NO holding column at all: warn loudly, because a status-less card
# sits in a No Status group nobody opens. Observed for real on 2026-08-20, where
# every reviewer-filed card vanished this way.
OUT=$(DEDUPE_HIT="" STATUS_OPTS="Ready Done" run --config "$WORK/config.json" --title "No backlog column" \
  --body-file "$WORK/body.md" --fingerprint "X|y")
is  "still returns the issue number" "412" "$OUT"
has "warns about the missing column" "$(cat "$WORK/err")" "none of the usual aliases"
has "says what the consequence is"   "$(cat "$WORK/err")" "will not appear in any column"

# A board that calls its holding column `Todo` rather than `Backlog` must still
# receive the card. This is the finfluencer board's exact shape.
OUT=$(DEDUPE_HIT="" STATUS_OPTS="Todo Ready Done" run --config "$WORK/config.json" --title "Todo board" \
  --body-file "$WORK/body.md" --fingerprint "X|z")
is  "files onto a Todo-column board" "412" "$OUT"
has "reports the alias it used"      "$(cat "$WORK/err")" "filed #412 into 'Todo'"
case "$(cat "$WORK/err")" in
  *"NO status"*) bad "alias board must not warn about no status" "no warning" "warned" ;;
  *) ok "alias board places the card properly" ;;
esac

# Multi-word option names must stay intact while walking the fallback list.
OUT=$(DEDUPE_HIT="" STATUS_OPTS="To_do Ready Done" run --config "$WORK/config.json" --title "To do board" \
  --body-file "$WORK/body.md" --fingerprint "X|to-do")
has "files onto a To do-column board" "$(cat "$GH_LOG")" "opt_To_do"
has "reports the multi-word alias intact" "$(cat "$WORK/err")" "filed #412 into 'To do'"

OUT=$(DEDUPE_HIT="" FAIL_ITEMADD=1 run --config "$WORK/config.json" --title "Board down" \
  --body-file "$WORK/body.md" --fingerprint "X|z")
is  "survives a board failure" "412" "$OUT"
has "warns about placement"    "$(cat "$WORK/err")" "could not place it"

printf '\n%s passed, %s failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
