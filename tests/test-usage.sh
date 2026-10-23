#!/usr/bin/env bash
# Tests super-board-usage.sh — the Claude plan-usage guard the run loop checks
# before each wave. No network: the status-line JSON is fed on stdin and the
# snapshot lives in a temp file.
set -euo pipefail
cd "$(dirname "$0")"
U="../scripts/super-board-usage.sh"
TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT
export SB_USAGE_FILE="$TMP/usage.json"
fail() { echo "FAIL: $1" >&2; exit 1; }
NOW=$(date +%s); LATER=$((NOW + 3600)); WEEK=$((NOW + 86400))

feed() {  # $1 = five_hour %, $2 = seven_day %, $3 = five_hour resets_at (default LATER)
  printf '{"model":{"id":"x"},"rate_limits":{"five_hour":{"used_percentage":%s,"resets_at":%s},"seven_day":{"used_percentage":%s,"resets_at":%s}}}' \
    "$1" "${3:-$LATER}" "$2" "$WEEK" | "$U" record
}
check() { RC=0; OUT=$("$U" check "$@") || RC=$?; }

# 1 — no snapshot yet: unknown (3), and the reason says how to wire it up.
check
[ "$RC" -eq 3 ] || fail "no snapshot should exit 3, got $RC"
echo "$OUT" | jq -e '.reason | test("status-line")' >/dev/null || fail "reason must point at the status line: $OUT"

# 2 — record is silent: anything it printed would end up in the status line.
[ -z "$(printf '{"rate_limits":{"five_hour":{"used_percentage":1,"resets_at":%s}}}' "$LATER" | "$U" record)" ] \
  || fail "record must print nothing"

# 3 — under threshold: ok (0), reporting the highest window.
feed 40 70; check
[ "$RC" -eq 0 ] || fail "40/70 should be ok, got $RC: $OUT"
echo "$OUT" | jq -e '.window == "seven_day" and .used == 70' >/dev/null || fail "should report the highest window: $OUT"

# 4 — the 5-hour window at 95%: pause (10), with its reset time for the resume.
feed 95 70; check
[ "$RC" -eq 10 ] || fail "five_hour 95 should pause, got $RC: $OUT"
echo "$OUT" | jq -e --argjson t "$LATER" '.window == "five_hour" and .resets_at == $t' >/dev/null || fail "pause must name the window and reset: $OUT"

# 5 — weekly over too: resume waits for the LATER reset, or the next wave pauses again.
feed 97 96; check
[ "$RC" -eq 10 ] || fail "both over should pause"
echo "$OUT" | jq -e '.window == "seven_day"' >/dev/null || fail "resume must wait for the later reset: $OUT"

# 6 — threshold comes from config usage_pause_pct; an explicit flag wins.
feed 85 10
echo '{"usage_pause_pct":80}' > "$TMP/c.json"
check --config "$TMP/c.json"; [ "$RC" -eq 10 ] || fail "usage_pause_pct 80 should pause at 85, got $RC"
check --config "$TMP/c.json" --threshold 90; [ "$RC" -eq 0 ] || fail "--threshold must win over config, got $RC"

# 7 — a window whose reset time has passed is a fresh window, not 99% used.
feed 99 10 $((NOW - 5)); check
[ "$RC" -eq 0 ] || fail "a reset window must not pause, got $RC: $OUT"

# 8 — a session without rate_limits (API key) leaves the last good snapshot alone.
feed 96 10
echo '{"model":{"id":"x"}}' | "$U" record
check; [ "$RC" -eq 10 ] || fail "a rate_limits-less record must not erase the snapshot"

# 9 — stale under-threshold proves nothing (3); stale over-threshold still pauses,
#     because usage cannot fall inside a window before it resets.
feed 50 10
jq '.recorded_at -= 5000' "$SB_USAGE_FILE" > "$TMP/s" && mv "$TMP/s" "$SB_USAGE_FILE"
check; [ "$RC" -eq 3 ] || fail "stale ok must read unknown, got $RC: $OUT"
feed 98 10
jq '.recorded_at -= 5000' "$SB_USAGE_FILE" > "$TMP/s" && mv "$TMP/s" "$SB_USAGE_FILE"
check; [ "$RC" -eq 10 ] || fail "stale over-threshold must still pause, got $RC: $OUT"

# 10 — garbage snapshot: unknown, never a crash the loop reads as "ok".
echo 'not json' > "$SB_USAGE_FILE"; check
[ "$RC" -eq 3 ] || fail "unreadable snapshot should exit 3, got $RC"

# 11 — Antigravity: record recognises the agy status line (quota buckets as remaining
#      fractions + ISO reset times), keeps it in the agy snapshot, and leaves the Claude one alone.
export SB_USAGE_FILE_AGY="$TMP/agy.json"
feed 40 70
RESET=$(date -u -d "@$WEEK" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date -u -r "$WEEK" +%Y-%m-%dT%H:%M:%SZ)
agy_feed() {  # $1 = gemini-weekly remaining fraction, $2 = gemini-3.8-flash remaining fraction
  printf '{"model":{"id":"auto"},"quota":{"gemini-weekly":{"remaining_fraction":%s,"reset_time":"%s","reset_in_seconds":1000},"gemini-3.8-flash":{"remaining_fraction":%s,"reset_time":"%s"}}}' \
    "$1" "$RESET" "$2" "$RESET" | "$U" record
}
[ -z "$(agy_feed 0.938 0.5)" ] || fail "agy record must print nothing"
jq -e '.rate_limits["gemini-weekly"].used_percentage == 6.2 and .rate_limits["gemini-3.8-flash"].used_percentage == 50' "$SB_USAGE_FILE_AGY" >/dev/null || fail "agy record must convert fractions to used_percentage: $(cat "$SB_USAGE_FILE_AGY")"
check; [ "$RC" -eq 0 ] || fail "an agy record must not touch the Claude snapshot, got $RC: $OUT"

# 12 — check --host agy weighs every bucket by name: ok under threshold, pause over it.
check --host agy
[ "$RC" -eq 0 ] || fail "agy 6.2/50 should be ok, got $RC: $OUT"
echo "$OUT" | jq -e '.window == "gemini-3.8-flash" and .used == 50' >/dev/null || fail "agy check must report the highest bucket: $OUT"
agy_feed 0.03 0.5; check --host agy
[ "$RC" -eq 10 ] || fail "gemini-weekly at 97% should pause, got $RC: $OUT"
echo "$OUT" | jq -e '.window == "gemini-weekly" and .used == 97' >/dev/null || fail "agy pause must name the bucket: $OUT"
echo '{"usage_pause_pct":40}' > "$TMP/a.json"
agy_feed 0.9 0.5; check --host agy --config "$TMP/a.json"
[ "$RC" -eq 10 ] || fail "usage_pause_pct applies to the agy check too, got $RC"

# 13 — no agy snapshot reads unknown (3); a bad --host is a usage error (64).
rm -f "$SB_USAGE_FILE_AGY"; check --host agy
[ "$RC" -eq 3 ] || fail "no agy snapshot should exit 3, got $RC"
check --host gemini; [ "$RC" -eq 64 ] || fail "unknown host should exit 64, got $RC"

# 14 — quota is per model family: with the five buckets agy 1.4.6 reports, a gemini-3.8-flash
#      run ignores the exhausted Argon bucket and the third-party ones; an Argon run pauses on
#      it; a Claude slug reads the 3p buckets; agy.model in the config stands in for --model;
#      no model known weighs every bucket.
printf '{"quota":{"3p-5h":{"remaining_fraction":1,"reset_time":"%s"},"3p-weekly":{"remaining_fraction":0.446,"reset_time":"%s"},"gemini-5h":{"remaining_fraction":0.874,"reset_time":"%s"},"gemini-argon-wtu-weekly":{"remaining_fraction":0,"reset_time":"%s"},"gemini-weekly":{"remaining_fraction":0.13,"reset_time":"%s"}}}' \
  "$RESET" "$RESET" "$RESET" "$RESET" "$RESET" | "$U" record
check --host agy --model gemini-3.8-flash
[ "$RC" -eq 0 ] || fail "a flash run must ignore the Argon bucket, got $RC: $OUT"
echo "$OUT" | jq -e '.window == "gemini-weekly" and .used == 87' >/dev/null || fail "a flash run weighs the gemini buckets: $OUT"
check --host agy --model gemini-4-argon-high
[ "$RC" -eq 10 ] && echo "$OUT" | jq -e '.window == "gemini-argon-wtu-weekly"' >/dev/null || fail "an Argon run must pause on its bucket, got $RC: $OUT"
check --host agy --model claude-opus-5-5
[ "$RC" -eq 0 ] && echo "$OUT" | jq -e '.window == "3p-weekly" and .used == 55.4' >/dev/null || fail "a Claude slug reads the 3p buckets, got $RC: $OUT"
echo '{"agy":{"model":"gemini-3.8-flash"}}' > "$TMP/m.json"
check --host agy --config "$TMP/m.json"; [ "$RC" -eq 0 ] || fail "agy.model from the config must select the family, got $RC: $OUT"
check --host agy; [ "$RC" -eq 10 ] || fail "with no model every bucket counts, got $RC: $OUT"

echo "PASS: test-usage.sh (14 scenarios)"
