#!/usr/bin/env bash
# Tests super-board-throttle.sh — the GitHub-limit step-down written back into
# max_workers after a wave. No network: `gh` is a stub that answers the REST
# rate_limit and the GraphQL rateLimit reads from env vars.
set -euo pipefail
KIT=$(cd "$(dirname "$0")/.." && pwd)
S="$KIT/scripts/super-board-throttle.sh"
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
fail() { echo "FAIL: $1" >&2; exit 1; }
mkdir -p "$T/bin"
cat > "$T/bin/gh" <<'SH'
#!/usr/bin/env bash
# REST rate_limit always claims a full GraphQL bucket — the misreport the
# throttle must not believe. GraphQL's own rateLimit answers SB_TEST_GQL_REMAINING.
if [ "$1 $2" = "api rate_limit" ]; then
  echo '{"resources":{"core":{"limit":5000,"remaining":4900},"graphql":{"limit":5000,"remaining":4999,"used":1}}}'
elif [ "$1 $2" = "api graphql" ]; then
  [ -n "${SB_TEST_GQL_REMAINING:-}" ] || exit 1
  printf '{"data":{"rateLimit":{"limit":5000,"remaining":%s,"used":%s,"resetAt":"2026-10-04T12:00:00Z"}}}\n' \
    "$SB_TEST_GQL_REMAINING" "$((5000 - SB_TEST_GQL_REMAINING))"
else
  exit 2
fi
SH
chmod +x "$T/bin/gh"
export PATH="$T/bin:$PATH"
cfg() { echo "$1" > "$T/cfg.json"; }
run() { bash "$S" --config "$T/cfg.json" "$@"; }

# 1 — quota healthy, no failure text: no hit, config untouched.
cfg '{"max_workers":3}'
OUT=$(SB_TEST_GQL_REMAINING=1200 run)
echo "$OUT" | jq -e '.hit == false and .from == 3 and .to == 3 and .wrote == false' >/dev/null || fail "healthy: $OUT"
[ "$(jq .max_workers "$T/cfg.json")" = 3 ] || fail "healthy run must not write"

# 2 — REST says 4999, GraphQL's own rateLimit says 0: the GraphQL reading wins.
OUT=$(SB_TEST_GQL_REMAINING=0 run)
echo "$OUT" | jq -e '.hit and .why == "graphql remaining 0" and .from == 3 and .to == 2 and .wrote' >/dev/null || fail "gql 0: $OUT"
[ "$(jq .max_workers "$T/cfg.json")" = 2 ] || fail "hit must write max_workers 2"

# 3 — the ladder: unlimited (absent or 0) → 3; 1 stays 1 (floor) and writes nothing.
cfg '{"repo":{"path":"."}}'
OUT=$(SB_TEST_GQL_REMAINING=0 run)
echo "$OUT" | jq -e '.from == 0 and .to == 3 and .wrote' >/dev/null || fail "unlimited: $OUT"
jq -e '.max_workers == 3 and .repo.path == "."' "$T/cfg.json" >/dev/null || fail "write must keep other keys"
cfg '{"max_workers":1}'
OUT=$(SB_TEST_GQL_REMAINING=0 run)
echo "$OUT" | jq -e '.hit and .from == 1 and .to == 1 and .wrote == false' >/dev/null || fail "floor: $OUT"

# 4 — a lane result that failed on the limit is a hit even with quota showing.
cfg '{"max_workers":2}'
echo '[{"number":7,"detail":"gh: API rate limit exceeded for user"}]' > "$T/results.json"
OUT=$(SB_TEST_GQL_REMAINING=4000 run --results "$T/results.json")
echo "$OUT" | jq -e '.hit and (.why | test("lane result")) and .to == 1' >/dev/null || fail "results: $OUT"
echo '[{"number":7,"detail":"merged"}]' > "$T/results.json"
cfg '{"max_workers":2}'
OUT=$(SB_TEST_GQL_REMAINING=4000 run --results "$T/results.json")
echo "$OUT" | jq -e '.hit == false' >/dev/null || fail "clean results: $OUT"

# 5 — GraphQL read unavailable: falls back to the REST payload (4999 → no hit).
OUT=$(run)
echo "$OUT" | jq -e '.hit == false' >/dev/null || fail "gql unavailable: $OUT"

# 6 — --rate file and --dry-run: reports the step, writes nothing.
echo '{"resources":{"graphql":{"remaining":0}}}' > "$T/rate.json"
OUT=$(run --rate "$T/rate.json" --dry-run)
echo "$OUT" | jq -e '.hit and .to == 1 and .wrote == false' >/dev/null || fail "dry-run: $OUT"
[ "$(jq .max_workers "$T/cfg.json")" = 2 ] || fail "dry-run must not write"

# 7 — usage errors.
RC=0; bash "$S" --config "$T/missing.json" >/dev/null 2>&1 || RC=$?
[ "$RC" -eq 66 ] || fail "missing config should exit 66, got $RC"
RC=0; run --bogus >/dev/null 2>&1 || RC=$?
[ "$RC" -eq 64 ] || fail "unknown arg should exit 64, got $RC"

echo 'PASS: test-throttle.sh (graphql reading, ladder, floor, lane failures, dry-run)'
