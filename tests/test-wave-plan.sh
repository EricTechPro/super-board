#!/usr/bin/env bash
# Tests super-board-wave-plan.sh against fixtures. No gh calls.
set -euo pipefail
cd "$(dirname "$0")"
PLAN="../scripts/super-board-wave-plan.sh"

fail() { echo "FAIL: $1" >&2; exit 1; }

OUT=$("$PLAN" --config fixtures/wave-config.json --items fixtures/wave-items.json)

# Scenario 1 — base picks, downstream-first order: Review #10, QA #13, Ready #12
echo "$OUT" | jq -e '.cards | length == 3' >/dev/null || fail "expected 3 cards, got: $OUT"
echo "$OUT" | jq -e '.cards[0].number == 10 and .cards[0].status == "Review"' >/dev/null || fail "card[0] should be Review #10"
echo "$OUT" | jq -e '.cards[1].number == 13 and .cards[1].status == "QA"' >/dev/null || fail "card[1] should be QA #13"
echo "$OUT" | jq -e '.cards[2].number == 12 and .cards[2].status == "Ready"' >/dev/null || fail "card[2] should be Ready #12 (skip assigned #11)"

# Scenario 2 — qa-only variant: Review + Ready base picks, then backlog fill adds Ready #14
QA_ONLY=$(jq '.variant = "qa-only"' fixtures/wave-config.json)
OUT2=$("$PLAN" --config <(echo "$QA_ONLY") --items fixtures/wave-items.json)
echo "$OUT2" | jq -e '.cards | length == 3' >/dev/null || fail "qa-only should select 3 cards (backlog fill), got: $OUT2"
echo "$OUT2" | jq -e '[.cards[].status] == ["Review","Ready","Ready"]' >/dev/null || fail "qa-only columns should be Review,Ready,Ready"

# Scenario 3 — max_workers cap
CAPPED=$(jq '.max_workers = 1' fixtures/wave-config.json)
OUT3=$("$PLAN" --config <(echo "$CAPPED") --items fixtures/wave-items.json)
echo "$OUT3" | jq -e '.cards | length == 1 and .[0].number == 10' >/dev/null || fail "cap=1 should keep only Review #10"

# Scenario 4 — backlog fill on full variant: cap 5 adds Ready #14 after the base 3
WIDE=$(jq '.max_workers = 5' fixtures/wave-config.json)
OUT4=$("$PLAN" --config <(echo "$WIDE") --items fixtures/wave-items.json)
echo "$OUT4" | jq -e '.cards | length == 4' >/dev/null || fail "cap=5 should select 4 cards (3 base + 1 backlog), got: $OUT4"
echo "$OUT4" | jq -e '.cards[3].number == 14 and .cards[3].status == "Ready"' >/dev/null || fail "card[3] should be backlog-fill Ready #14"

# Scenario 5 — merge-race guard: extra Review cards excluded by default
OUT5=$("$PLAN" --config fixtures/wave-config.json --items fixtures/wave-items-review-heavy.json)
echo "$OUT5" | jq -e '[.cards[] | select(.status == "Review")] | length == 1' >/dev/null || fail "default config should allow only 1 Review card, got: $OUT5"

# Scenario 6 — human_approves_merge=true unlocks extra Review cards
HUMAN=$(jq '.human_approves_merge = true' fixtures/wave-config.json)
OUT6=$("$PLAN" --config <(echo "$HUMAN") --items fixtures/wave-items-review-heavy.json)
echo "$OUT6" | jq -e '[.cards[] | select(.status == "Review")] | length >= 2' >/dev/null || fail "human_approves_merge should allow extra Review cards, got: $OUT6"

# Scenario 7 — invalid variant fails loudly (exit 65), never silently qa-only
BAD=$(jq '.variant = "fulll"' fixtures/wave-config.json)
RC=0; "$PLAN" --config <(echo "$BAD") --items fixtures/wave-items.json >/dev/null 2>&1 || RC=$?
[ "$RC" -eq 65 ] || fail "invalid variant should exit 65, got $RC"

# Scenario 8 — empty board → cards:[] (run-workflow.md done condition depends on this shape)
OUT8=$("$PLAN" --config fixtures/wave-config.json --items <(echo '{"items":[]}'))
echo "$OUT8" | jq -e '.cards == []' >/dev/null || fail "empty board should yield cards:[], got: $OUT8"

echo "PASS: test-wave-plan.sh (8 scenarios)"
