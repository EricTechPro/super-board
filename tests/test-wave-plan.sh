#!/usr/bin/env bash
# Tests super-board-wave-plan.sh against fixtures. No gh calls, no network —
# the dependency graph is injected with --deps.
#
# The contract these tests pin down changed on 2026-08-20. A wave used to be
# "one card per column, then fill to max_workers". It is now "every Ready card
# the dependency graph says is free, plus everything already in flight", with
# max_workers demoted to an optional throttle. Several scenarios below exist
# because the old contract shipped a board where five cards sat in Blocked long
# after their blockers had closed.
set -euo pipefail
cd "$(dirname "$0")"
PLAN="../scripts/super-board-wave-plan.sh"
CFG=fixtures/wave-config.json
ITEMS=fixtures/wave-items.json
DEPS=fixtures/wave-deps.json

fail() { echo "FAIL: $1" >&2; exit 1; }
plan() { "$PLAN" --config "$1" --items "$ITEMS" --deps "$DEPS"; }

# Uncapped is the default shape, so every scenario runs without a cap unless it
# is specifically testing the throttle.
NOCAP=$(jq 'del(.max_workers)' "$CFG")
OUT=$(plan <(echo "$NOCAP"))

# 1 — width follows the graph, not a knob. Free Ready cards are #12 alone:
#     #11 is assigned, #14 waits on open #12, #15 is unreadable, the draft is not
#     an issue. In flight: Review #10 and QA #13. Total 3.
echo "$OUT" | jq -e '.cards | length == 3' >/dev/null || fail "expected 3 cards, got: $OUT"
echo "$OUT" | jq -e '[.cards[].number] | sort == [10,12,13]' >/dev/null || fail "wrong cards: $OUT"

# 2 — downstream-first: in-flight cards lead, so work already begun finishes
#     before new work starts.
echo "$OUT" | jq -e '[.cards[].status] | index("Ready") > index("Review")' >/dev/null \
  || fail "in-flight cards must precede Ready cards: $OUT"

# 3 — a Ready card with an OPEN blocker is not dispatched. This is the whole
#     point: #14 would previously have been picked as backlog fill, hit its own
#     preflight, and parked in Blocked.
echo "$OUT" | jq -e '[.cards[].number] | index(14) == null' >/dev/null \
  || fail "#14 waits on open #12 and must not be dispatched: $OUT"

# 4 — an unreadable dependency line is fail-safe: never dispatched, always flagged.
echo "$OUT" | jq -e '[.cards[].number] | index(15) == null' >/dev/null \
  || fail "#15 has an unreadable Blocked-by line and must not be dispatched"
echo "$OUT" | jq -e '[.flag[].number] == [15]' >/dev/null \
  || fail "#15 must be flagged so a human can fix the line, got: $(echo "$OUT" | jq -c .flag)"
echo "$OUT" | jq -e '.flag[0].why | test("None")' >/dev/null \
  || fail "the flag must carry the reason, not just the number"

# 5 — the sweep: a Blocked card whose blockers have all closed comes back.
#     #16 waits on #9, which is closed. #17 waits on #12, which is open.
echo "$OUT" | jq -e '[.sweep[].number] == [16]' >/dev/null \
  || fail "expected only #16 swept, got: $(echo "$OUT" | jq -c .sweep)"
echo "$OUT" | jq -e '.sweep[0].clearedBy == [9]' >/dev/null \
  || fail "the sweep must name what cleared the card, for the comment it will post"

# 6 — a swept card is NOT also dispatched in the same plan. The orchestrator moves
#     it to Ready first; dispatching it straight from Blocked would skip that move
#     and leave the board lying about where the card is.
echo "$OUT" | jq -e '[.cards[].number] | index(16) == null' >/dev/null \
  || fail "#16 must be swept, not dispatched from Blocked"

# 7 — max_workers still throttles when set. It is a safety valve now, not the
#     wave-sizing mechanism.
OUT7=$(plan <(jq '.max_workers = 1' "$CFG"))
echo "$OUT7" | jq -e '(.cards | length) == 1 and .cards[0].number == 10' >/dev/null \
  || fail "max_workers=1 should keep only the leading in-flight card, got: $OUT7"

# 8 — the throttle does not suppress the sweep. A capped wave still frees cards,
#     because sweeping is a board correction and costs no worker.
echo "$OUT7" | jq -e '[.sweep[].number] == [16]' >/dev/null \
  || fail "a capped wave must still sweep, got: $(echo "$OUT7" | jq -c .sweep)"

# 9 — assignee is the cross-machine mutex and still wins over everything.
echo "$OUT" | jq -e '[.cards[].number] | index(11) == null' >/dev/null \
  || fail "#11 is assigned and must never be dispatched"

# 10 — reviews are no longer gated behind human_approves_merge. The merge race is
#      guarded where it happens (the merge lock plus the freshness gate inside the
#      wave workflow), so a second Review card is free to run here.
OUT10=$("$PLAN" --config <(echo "$NOCAP") --items fixtures/wave-items-review-heavy.json --deps "$DEPS")
echo "$OUT10" | jq -e '[.cards[] | select(.status == "Review")] | length >= 2' >/dev/null \
  || fail "reviews should run in parallel now, got: $OUT10"

# 11 — qa-only has no Builder lane, so the QA column is not an in-flight source.
OUT11=$("$PLAN" --config <(echo "$NOCAP" | jq '.variant = "qa-only"') --items "$ITEMS" --deps "$DEPS")
echo "$OUT11" | jq -e '[.cards[].status] | index("QA") == null' >/dev/null \
  || fail "qa-only must not select from the QA column, got: $OUT11"
echo "$OUT11" | jq -e '[.cards[].number] | index(12) != null' >/dev/null \
  || fail "qa-only must still select free Ready cards, got: $OUT11"

# 12 — invalid variant fails loudly (exit 65), never silently qa-only.
RC=0; "$PLAN" --config <(jq '.variant = "fulll"' "$CFG") --items "$ITEMS" --deps "$DEPS" >/dev/null 2>&1 || RC=$?
[ "$RC" -eq 65 ] || fail "invalid variant should exit 65, got $RC"

# 13 — empty board → empty everything (run-workflow.md's done condition depends
#      on this shape).
OUT13=$("$PLAN" --config <(echo "$NOCAP") --items <(echo '{"items":[]}') --deps "$DEPS")
echo "$OUT13" | jq -e '.cards == [] and .sweep == [] and .flag == [] and .stranded == []' >/dev/null \
  || fail "empty board should yield empty cards/sweep/flag/stranded, got: $OUT13"

# 14 — a card the graph has never heard of is not treated as free. An issue beyond
#      the fetch limit, or closed out from under the board, must not be dispatched
#      on the strength of a missing entry.
OUT14=$("$PLAN" --config <(echo "$NOCAP") --items "$ITEMS" --deps <(echo '{}'))
echo "$OUT14" | jq -e '[.cards[] | select(.status == "Ready")] | length == 0' >/dev/null \
  || fail "an empty graph must yield no Ready picks, got: $OUT14"

# 15 — a graph that cannot be derived is a hard failure, not an empty graph.
#      Without --deps and without config.repo.remote there is nothing to derive from.
RC=0; "$PLAN" --config <(jq 'del(.repo)' "$CFG") --items "$ITEMS" >/dev/null 2>&1 || RC=$?
[ "$RC" -eq 66 ] || fail "a missing repo remote should exit 66, got $RC"

# 16 — a Building card with no claim is stranded: a stopped wave left it there and
#      no lane selects from Building. A claimed one (#19) has a live worker.
echo "$OUT" | jq -e '[.stranded[].number] == [18]' >/dev/null \
  || fail "expected only #18 stranded, got: $(echo "$OUT" | jq -c .stranded)"
echo "$OUT" | jq -e '[.cards[].number] | index(18) == null' >/dev/null \
  || fail "#18 must be moved to Ready first, not dispatched from Building"

# 17 — qa-only boards have no Building lane, so nothing is ever stranded there.
echo "$OUT11" | jq -e '.stranded == []' >/dev/null \
  || fail "qa-only must report no stranded cards, got: $(echo "$OUT11" | jq -c .stranded)"

# 18 — resume: a 🙋 Blocked card whose human step is done (#20) is reported for
#      the move back to Review; one still waiting (#21) is not. Neither is swept
#      to Ready or dispatched from Blocked.
echo "$OUT" | jq -e '[.resume[].number] == [20]' >/dev/null \
  || fail "expected only #20 resumed, got: $(echo "$OUT" | jq -c .resume)"
echo "$OUT" | jq -e '[.sweep[].number, .cards[].number] | (index(20) == null and index(21) == null)' >/dev/null \
  || fail "🙋 cards must not be swept to Ready or dispatched"

echo "PASS: test-wave-plan.sh (18 scenarios)"
