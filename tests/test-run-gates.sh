#!/usr/bin/env bash
# Gate tests for scripts/super-board-run.sh — closed-issue guard (#10) and the
# landed-work halt gate (#8). Deterministic, no network: `gh` is a stub on PATH
# and the board is a JSON fixture. Runs in well under 2s.
#
#   bash tests/test-run-gates.sh

set -uo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
STUB_DIR="$(mktemp -d)"
trap 'rm -rf "$STUB_DIR"' EXIT

PASS=0
FAIL=0
ok()   { PASS=$((PASS + 1)); printf '  ✅ %s\n' "$1"; }
bad()  { FAIL=$((FAIL + 1)); printf '  ❌ %s\n     expected: %s\n     actual:   %s\n' "$1" "$2" "$3"; }
is()   { [ "$2" = "$3" ] && ok "$1" || bad "$1" "$2" "$3"; }

# ── gh stub. CLOSED_ISSUES lists issue numbers the stub reports as closed.
# Every invocation is appended to $STUB_DIR/gh.log so tests can assert on calls.
cat > "$STUB_DIR/gh" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$GH_LOG"
case "$1 ${2:-}" in
  "issue view")
    for n in $CLOSED_ISSUES; do
      [ "$n" = "$3" ] && { echo "CLOSED"; exit 0; }
    done
    echo "OPEN" ;;
  "project item-edit") exit 0 ;;
  "project view")      echo '{"id":"PVT_stub"}' ;;
  "issue edit")        exit 0 ;;
  "api graphql")
    cat <<'JSON'
{"data":{"user":{"projectV2":{"field":{"id":"PVTSSF_stub",
 "options":[{"id":"opt_ready","name":"Ready"},{"id":"opt_done","name":"Done"},
            {"id":"opt_review","name":"Review"}]}}},"organization":null}}
JSON
    ;;
  *) exit 0 ;;
esac
STUB
chmod +x "$STUB_DIR/gh"
export PATH="$STUB_DIR:$PATH"
export GH_LOG="$STUB_DIR/gh.log"
export CLOSED_ISSUES=""

# ── Load the dispatcher's helpers without starting a run.
export SB_LIB_ONLY=1
# shellcheck disable=SC1091
. "$REPO_ROOT/scripts/super-board-run.sh"
# The dispatcher sets -e for its own run; the tests deliberately call functions that
# return non-zero as their verdict, so drop it after sourcing.
set +e

BOT_LOGIN=""
INFLIGHT_DIR="$STUB_DIR/inflight"; mkdir -p "$INFLIGHT_DIR"
WORKER_LOG_DIR="$STUB_DIR/workers"; mkdir -p "$WORKER_LOG_DIR"
RUN_MANIFEST="$STUB_DIR/run.md"

board() {
  # $1..$n = "number:status" triples → project item-list JSON
  local items="" n s
  for pair in "$@"; do
    n="${pair%%:*}"; s="${pair##*:}"
    items="${items}{\"id\":\"item_${n}\",\"status\":\"${s}\",\"content\":{\"type\":\"Issue\",\"number\":${n},\"assignees\":[]}},"
  done
  printf '{"items":[%s]}' "${items%,}"
}

echo "── done_signature (#8: progress = landed work)"
PROJECT_ITEMS_JSON=$(board 1:Done 2:Ready 3:Review)
is "counts only Done/Skipped" "1" "$(done_signature)"
PROJECT_ITEMS_JSON=$(board 1:Done 2:Skipped 3:Review)
is "Skipped is terminal too" "1,2" "$(done_signature)"
PROJECT_ITEMS_JSON=$(board 1:Review 2:QA 3:Ready)
is "nothing landed → empty signature" "" "$(done_signature)"

echo
echo "── record_cycle_progress (#8: halt is independent of lane occupancy)"
NO_PROGRESS_CYCLES=3; PREV_DONE_SIG="1"; NO_PROGRESS_CYCLE_COUNT=0; LANDED_COUNT=0
record_cycle_progress "1"; is "cycle 1 of 3 → keep running" "0" "$?"
record_cycle_progress "1"; is "cycle 2 of 3 → keep running" "0" "$?"
record_cycle_progress "1"; rc=$?
is "cycle 3 of 3 → HALT even though no lane state was consulted" "1" "$rc"
is "no card counted as landed" "0" "$LANDED_COUNT"

NO_PROGRESS_CYCLES=3; PREV_DONE_SIG="1"; NO_PROGRESS_CYCLE_COUNT=0; LANDED_COUNT=0
record_cycle_progress "1" >/dev/null
record_cycle_progress "1,2"; is "a card reaching Done → no halt" "0" "$?"
is "counter reset after progress" "0" "$NO_PROGRESS_CYCLE_COUNT"
is "landed count incremented" "1" "$LANDED_COUNT"
record_cycle_progress "1,2"; record_cycle_progress "1,2"
record_cycle_progress "1,2"; is "stall after progress still halts" "1" "$?"

echo
echo "── dispatch_ceiling_hit (#8: bounded worst-case spend)"
MAX_DISPATCHES=0; DISPATCH_COUNT=999
dispatch_ceiling_hit; is "0 disables the ceiling" "1" "$?"
MAX_DISPATCHES=5; DISPATCH_COUNT=4
dispatch_ceiling_hit; is "under the ceiling → keep running" "1" "$?"
DISPATCH_COUNT=5
dispatch_ceiling_hit; is "at the ceiling → halt" "0" "$?"

echo
echo "── issue_is_open (#10)"
CLOSED_ISSUES="41 49 92"
issue_is_open 41; is "known-closed issue reads CLOSED" "1" "$?"
issue_is_open 7;  is "open issue reads OPEN" "0" "$?"

echo
echo "── top_card_in_column (#10: closed cards are reconciled, never dispatched)"
CLOSED_ISSUES="41"
PROJECT_ITEMS_JSON=$(board 41:Review 55:Review)
: > "$GH_LOG"
top_card_in_column "Review" >/dev/null; rc=$?
is "a dispatchable card was found" "0" "$rc"
is "skips the closed card, returns the next open one" "55" "$TOP_ISSUE"
grep -q 'project item-edit .*opt_done' "$GH_LOG" \
  && ok "closed card reconciled to Done via a name-resolved option ID" \
  || bad "closed card reconciled to Done" "an item-edit to opt_done" "$(tr '\n' '|' < "$GH_LOG")"

CLOSED_ISSUES=""
PROJECT_ITEMS_JSON=$(board 55:Review)
top_card_in_column "Review" >/dev/null
is "open card in Review is returned unchanged" "55" "$TOP_ISSUE"

CLOSED_ISSUES="41 55"
PROJECT_ITEMS_JSON=$(board 41:Review 55:Review)
top_card_in_column "Review" >/dev/null; rc=$?
is "all-closed column reports no dispatchable card (non-zero)" "1" "$rc"
is "all-closed column yields no card number" "" "$TOP_ISSUE"

echo
echo "── dispatch_lane (#10: the guard holds at the single choke point)"
CLOSED_ISSUES="41"
DISPATCH_COUNT=0; DISPATCH_LOG=""
: > "$GH_LOG"
dispatch_lane review 41 >/dev/null 2>&1
is "no worker dispatched for a CLOSED issue" "0" "$DISPATCH_COUNT"
grep -q 'issue edit 41 --add-assignee' "$GH_LOG" \
  && bad "closed issue is not claimed" "no assignee claim" "claim was attempted" \
  || ok "closed issue is not claimed either"

echo
echo "── status_option_id (#6 class of failure: resolve by name, fail loud)"
STATUS_FIELD_ID=""; STATUS_OPTIONS_JSON=""
resolve_status_field
is "resolves the live Status field id" "PVTSSF_stub" "$STATUS_FIELD_ID"
is "resolves 'Done' by name at runtime" "opt_done" "$(status_option_id Done)"
out=$(status_option_id "Nonexistent"); rc=$?
is "unknown option name fails loud (non-zero)" "1" "$rc"
is "unknown option name emits nothing" "" "$out"

echo
printf '\n%s passed, %s failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
