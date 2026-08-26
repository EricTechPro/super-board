#!/usr/bin/env bash
# Tests super-board-merge-gate.sh — the merge mutex and the freshness gate.
# No gh calls: every scenario stops at or before the first `gh pr view`.
#
# The gate exists because `mergeable: CLEAN` was trusted twice on 2026-08-20 and
# was wrong both times: the text did not conflict, but a shared interface had
# grown on the base since the branch was tested, so the merge would have turned
# the base branch red. These tests pin the two properties that prevent it — one
# merge at a time, and the proof happens under the lock.
set -euo pipefail
cd "$(dirname "$0")"
GATE="../scripts/super-board-merge-gate.sh"

fail() { echo "FAIL: $1" >&2; exit 1; }

setup() {  # $1 = verify_commands JSON array
  TMP=$(mktemp -d)
  mkdir -p "$TMP/.claude/super-board/inflight"
  printf '{"base_branch":"staging","repo":{"path":"%s","remote":"https://github.com/x/y.git"},"verify_commands":%s}' \
    "$TMP" "${1:-[]}" > "$TMP/c.json"
  LOCK="$TMP/.claude/super-board/inflight/merge.lock"
}
teardown() { rm -rf "$TMP"; }

# 1 — a held, fresh lock makes a second caller wait and then give up with 4.
#     Exit 4 is distinct on purpose: "someone else is merging" is not the same
#     answer as "this branch is broken", and the caller routes them differently.
setup
mkdir -p "$LOCK"; date +%s > "$LOCK/at"
RC=0; "$GATE" --config "$TMP/c.json" --pr 1 --lock-timeout 6 --stale-after 9999 >/dev/null 2>&1 || RC=$?
[ "$RC" -eq 4 ] || fail "a contended fresh lock should exit 4, got $RC"
[ -d "$LOCK" ] || fail "the loser must not delete the winner's lock"
teardown

# 2 — a lock older than --stale-after is reaped. A process that died holding it
#     would otherwise wedge every future merge on the board.
setup
mkdir -p "$LOCK"; echo $(( $(date +%s) - 99999 )) > "$LOCK/at"
OUT=$("$GATE" --config "$TMP/c.json" --pr 1 --lock-timeout 6 --stale-after 60 2>&1 || true)
echo "$OUT" | grep -q "reaping a lock abandoned" || fail "an abandoned lock should be reaped, got: $OUT"
teardown

# 3 — THE REGRESSION THIS FILE EXISTS FOR. --lock-timeout and --stale-after must
#     be independent. A caller willing to wait 20 minutes must NOT thereby decide
#     that a 20-minute-old lock is dead: that reaps the very merge it is queued
#     behind. With them collapsed into one number (the first implementation), a
#     lock aged just past the wait window was stolen.
setup
mkdir -p "$LOCK"; echo $(( $(date +%s) - 30 )) > "$LOCK/at"
OUT=$("$GATE" --config "$TMP/c.json" --pr 1 --lock-timeout 6 --stale-after 9999 2>&1 || true)
echo "$OUT" | grep -q "reaping" && fail "a 30s-old lock must survive a 6s waiter with stale-after 9999"
echo "$OUT" | grep -q "could not take the merge lock" || fail "the waiter should time out politely, got: $OUT"
teardown

# 4 — the default stale-after has an absolute floor, not just a multiple of the
#     wait. An impatient caller must not be able to reap by being impatient: with
#     only a 3x multiple, `--lock-timeout 6` outlived its own 18s threshold inside
#     the polling loop and stole a live lock.
setup
mkdir -p "$LOCK"; echo $(( $(date +%s) - 60 )) > "$LOCK/at"
OUT=$("$GATE" --config "$TMP/c.json" --pr 1 --lock-timeout 6 2>&1 || true)
echo "$OUT" | grep -q "reaping" && fail "a 60s-old lock must survive an impatient waiter (floor is 1800s)"
echo "$OUT" | grep -q "could not take the merge lock" || fail "the impatient waiter should time out, got: $OUT"
teardown

# 5 — an empty verify_commands list warns rather than implying a check it skipped.
#     Reaching the warning means the lock was taken, so this also proves the happy
#     path acquires cleanly on an uncontended lock.
setup '[]'
OUT=$("$GATE" --config "$TMP/c.json" --pr 1 --lock-timeout 6 2>&1 || true)
echo "$OUT" | grep -q "lock taken" || fail "an uncontended lock should be taken, got: $OUT"
teardown

# 6 — the lock is released on every exit path, including the failures above.
#     A gate that strands its own lock wedges the board it was written to protect.
setup
OUT=$("$GATE" --config "$TMP/c.json" --pr 1 --lock-timeout 6 2>&1 || true)
[ ! -d "$LOCK" ] || fail "the lock must be released on exit, even when the run fails"
teardown

# 7 — usage errors are distinct from operational ones, so a caller never reads a
#     typo as "the branch is broken".
setup
RC=0; "$GATE" --config "$TMP/c.json" >/dev/null 2>&1 || RC=$?
[ "$RC" -eq 64 ] || fail "a missing --pr should exit 64, got $RC"
RC=0; "$GATE" --config /nope/nope.json --pr 1 >/dev/null 2>&1 || RC=$?
[ "$RC" -eq 66 ] || fail "a missing config should exit 66, got $RC"
teardown

echo "PASS: test-merge-gate.sh (7 scenarios)"
