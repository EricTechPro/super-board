#!/usr/bin/env bash
# super-board-usage.sh — Claude plan-usage guard for the run loop.
#
# WHERE THE NUMBER COMES FROM
#
# Claude Code exposes plan usage to exactly one scriptable place: the JSON it
# pipes into the status-line command. For claude.ai Pro/Max subscribers that
# JSON carries
#
#   rate_limits.five_hour.used_percentage   0-100
#   rate_limits.five_hour.resets_at         unix epoch seconds
#   rate_limits.seven_day.{used_percentage,resets_at}
#
# (code.claude.com/docs/en/statusline). `/usage` shows the same bars but is an
# interactive dialog, not a command a script can call. `ccusage` reads local
# transcripts and reports tokens/cost per 5-hour block, but not a percentage of
# the plan limit, so it cannot answer "are we at 95%".
#
# So this script has two halves:
#
#   record — called from the status-line script with the status-line JSON on
#            stdin. Saves `rate_limits` plus a timestamp to the snapshot file.
#            Prints nothing, so it never disturbs the status line.
#   check  — reads the snapshot and says ok / pause / unknown.
#
# LIMITS, STATED PLAINLY
#
# - The snapshot refreshes only while some interactive Claude Code session with
#   the record line is rendering its status line (after each API response).
#   Headless `claude -p` workers do not render one. The workflow backend's
#   orchestrator IS an interactive session, so its own turns keep it fresh.
# - API-key and Bedrock/Vertex users get no `rate_limits` at all → `unknown`.
# - Usage only grows inside a window until it resets. A stale reading at or
#   over the threshold is therefore still a valid "pause" until its resets_at;
#   a stale reading UNDER the threshold proves nothing and reads `unknown`.
#
# Usage:
#   <status-line json> | super-board-usage.sh record
#   super-board-usage.sh check [--config <cfg.json>] [--threshold 95] [--max-age 900]
#
# Snapshot: $SB_USAGE_FILE, default ~/.claude/super-board/usage.json (usage is
# per account, not per repo, so one file serves every board).
#
# check prints one JSON line:
#   {"state":"ok|pause|unknown","window":"five_hour|seven_day|null",
#    "used":96,"resets_at":1738425600,"age":42,"reason":"…"}
# Exit: 0 ok, 10 pause, 3 unknown, 64 usage error.
set -euo pipefail

FILE="${SB_USAGE_FILE:-$HOME/.claude/super-board/usage.json}"
MODE="${1:-}"; [ $# -gt 0 ] && shift

case "$MODE" in
  record)
    IN=$(cat)
    RL=$(printf '%s' "$IN" | jq -c '.rate_limits // empty' 2>/dev/null || true)
    # No rate_limits (API-key user, or before the session's first response):
    # keep the last good snapshot rather than overwrite it with nothing.
    [ -n "$RL" ] || exit 0
    mkdir -p "$(dirname "$FILE")"
    TMP="$FILE.$$"
    jq -n --argjson rl "$RL" '{recorded_at: now | floor, rate_limits: $rl}' > "$TMP" && mv "$TMP" "$FILE"
    exit 0 ;;
  check) ;;
  *) echo "usage: super-board-usage.sh record | check [--config f] [--threshold N] [--max-age S]" >&2; exit 64 ;;
esac

THRESHOLD=""; MAX_AGE=900; CONFIG=""
while [ $# -gt 0 ]; do
  case "$1" in
    --config)    CONFIG="$2"; shift 2 ;;
    --threshold) THRESHOLD="$2"; shift 2 ;;
    --max-age)   MAX_AGE="$2"; shift 2 ;;
    *) echo "unknown arg: $1" >&2; exit 64 ;;
  esac
done
if [ -z "$THRESHOLD" ] && [ -n "$CONFIG" ] && [ -f "$CONFIG" ]; then
  THRESHOLD=$(jq -r '.usage_pause_pct // empty' "$CONFIG")
fi
THRESHOLD="${THRESHOLD:-95}"

if [ ! -f "$FILE" ]; then
  echo '{"state":"unknown","window":null,"used":null,"resets_at":null,"age":null,"reason":"no usage snapshot — add the record line to your status-line script (run-workflow.md)"}'
  exit 3
fi

OUT=$(jq -c --argjson th "$THRESHOLD" --argjson maxage "$MAX_AGE" '
  (now | floor) as $now
  | ($now - (.recorded_at // 0)) as $age
  # A window whose reset time has passed is a fresh window: drop it.
  | [ (.rate_limits // {}) | to_entries[]
      | select(.key == "five_hour" or .key == "seven_day")
      | select((.value.used_percentage // null) != null)
      | select((.value.resets_at // 0) > $now)
      | { window: .key, used: .value.used_percentage, resets_at: .value.resets_at } ] as $w
  | ($w | map(select(.used >= $th)) | sort_by(.resets_at) | last) as $over
  | if $over != null then
      # Usage cannot fall inside a window, so a stale over-threshold reading holds.
      $over + { state: "pause", age: $age,
                reason: "\($over.window) at \($over.used)% (threshold \($th)%)" }
    elif $age > $maxage then
      { state: "unknown", window: null, used: null, resets_at: null, age: $age,
        reason: "snapshot is \($age)s old (max \($maxage)s) — no live status line is recording" }
    elif ($w | length) == 0 then
      { state: "ok", window: null, used: null, resets_at: null, age: $age,
        reason: "no active window in the snapshot" }
    else
      ($w | sort_by(.used) | last) + { state: "ok", age: $age,
        reason: "highest window \(($w | sort_by(.used) | last).window) at \(($w | sort_by(.used) | last).used)%" }
    end
  | { state, window, used, resets_at, age, reason }' "$FILE" 2>/dev/null) || {
  echo '{"state":"unknown","window":null,"used":null,"resets_at":null,"age":null,"reason":"usage snapshot is unreadable"}'
  exit 3; }

echo "$OUT"
case "$(echo "$OUT" | jq -r .state)" in
  ok) exit 0 ;;
  pause) exit 10 ;;
  *) exit 3 ;;
esac
