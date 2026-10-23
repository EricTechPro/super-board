#!/usr/bin/env bash
# super-board-usage.sh — plan-usage guard for the run loop (Claude Code, or Antigravity).
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
# The Antigravity CLI (agy) does the same with its own status line
# (antigravity.google/docs/cli/statusline): `quota.<bucket>.{remaining_fraction 0-1,
# reset_time ISO-8601, reset_in_seconds}`, one bucket per plan window or model
# (observed on 1.4.6: `gemini-5h`, `gemini-weekly`, `gemini-argon-wtu-weekly`, `3p-5h`,
# `3p-weekly`; "3p" is the third-party models, Claude and GPT). `record` recognises that
# shape by itself, converts every bucket to {used_percentage, resets_at} and saves it to
# the agy snapshot. Quota is per model family, so `check --host agy` weighs only the
# buckets of the model the lanes use (`--model <slug>`, else the config's `agy.model`):
# the family's own buckets (`gemini-5h`, `gemini-weekly` for a `gemini-*` slug; `3p-*`
# for `claude-*` / `gpt-*`) plus a model-specific one (`gemini-argon-…`) only when the
# slug names that model. No model known → every bucket counts. Only an interactive agy
# session renders a status line; headless `agy -p` lanes do not.
#
# So this script has two halves:
#
#   record — called from the status-line script with the status-line JSON on
#            stdin. Saves `rate_limits` (Claude) or the converted `quota` (agy)
#            plus a timestamp to that host's snapshot file. Prints nothing, so it
#            never disturbs the status line.
#   check  — reads the snapshot and says ok / pause / unknown.
#
# LIMITS, STATED PLAINLY
#
# - The snapshot refreshes only while some interactive session with the record
#   line is rendering its status line (after each API response). Headless
#   workers do not render one. The workflow backend's orchestrator IS an
#   interactive session, so its own turns keep it fresh.
# - API-key and Bedrock/Vertex users get no `rate_limits` at all → `unknown`.
# - Usage only grows inside a window until it resets. A stale reading at or
#   over the threshold is therefore still a valid "pause" until its resets_at;
#   a stale reading UNDER the threshold proves nothing and reads `unknown`.
#
# Usage:
#   <status-line json> | super-board-usage.sh record
#   super-board-usage.sh check [--host claude|agy] [--model <agy slug>] [--config <cfg.json>] [--threshold 95] [--max-age 900]
#
# Snapshots: $SB_USAGE_FILE, default ~/.claude/super-board/usage.json (Claude) and
# $SB_USAGE_FILE_AGY, default ~/.gemini/super-board/usage.json (agy). Usage is per
# account, not per repo, so one file per host serves every board.
#
# check prints one JSON line:
#   {"state":"ok|pause|unknown","window":"five_hour|seven_day|<agy bucket>|null",
#    "used":96,"resets_at":1738425600,"age":42,"reason":"…"}
# Exit: 0 ok, 10 pause, 3 unknown, 64 usage error.
set -euo pipefail

FILE="${SB_USAGE_FILE:-$HOME/.claude/super-board/usage.json}"
AGY_FILE="${SB_USAGE_FILE_AGY:-$HOME/.gemini/super-board/usage.json}"
MODE="${1:-}"; [ $# -gt 0 ] && shift

case "$MODE" in
  record)
    IN=$(cat)
    RL=$(printf '%s' "$IN" | jq -c '.rate_limits // empty' 2>/dev/null || true)
    if [ -z "$RL" ]; then
      # Antigravity status line: quota buckets as remaining fractions + ISO reset times.
      RL=$(printf '%s' "$IN" | jq -c '
        (.quota // empty) | select(type == "object" and length > 0)
        | with_entries(select(.value.remaining_fraction != null and .value.reset_time != null)
            | .value = { used_percentage: (((1 - .value.remaining_fraction) * 1000 | round) / 10),
                         resets_at: (.value.reset_time | sub("\\.[0-9]+"; "") | fromdateiso8601) })
        | select(length > 0)' 2>/dev/null || true)
      [ -n "$RL" ] && FILE="$AGY_FILE"
    fi
    # No rate_limits and no quota (API-key user, or before the session's first
    # response): keep the last good snapshot rather than overwrite it with nothing.
    [ -n "$RL" ] || exit 0
    mkdir -p "$(dirname "$FILE")"
    TMP="$FILE.$$"
    jq -n --argjson rl "$RL" '{recorded_at: now | floor, rate_limits: $rl}' > "$TMP" && mv "$TMP" "$FILE"
    exit 0 ;;
  check) ;;
  *) echo "usage: super-board-usage.sh record | check [--host claude|agy] [--model slug] [--config f] [--threshold N] [--max-age S]" >&2; exit 64 ;;
esac

THRESHOLD=""; MAX_AGE=900; CONFIG=""; HOST=claude; MODEL=""
while [ $# -gt 0 ]; do
  case "$1" in
    --host)      HOST="$2"; shift 2 ;;
    --model)     MODEL="$2"; shift 2 ;;
    --config)    CONFIG="$2"; shift 2 ;;
    --threshold) THRESHOLD="$2"; shift 2 ;;
    --max-age)   MAX_AGE="$2"; shift 2 ;;
    *) echo "unknown arg: $1" >&2; exit 64 ;;
  esac
done
case "$HOST" in
  claude) ANY_WINDOW=false ;;
  agy) FILE="$AGY_FILE"; ANY_WINDOW=true ;;
  *) echo "--host must be claude or agy" >&2; exit 64 ;;
esac
if [ -z "$THRESHOLD" ] && [ -n "$CONFIG" ] && [ -f "$CONFIG" ]; then
  THRESHOLD=$(jq -r '.usage_pause_pct // empty' "$CONFIG")
fi
THRESHOLD="${THRESHOLD:-95}"
if [ "$HOST" = agy ] && [ -z "$MODEL" ] && [ -n "$CONFIG" ] && [ -f "$CONFIG" ]; then
  MODEL=$(jq -r '.agy.model // empty' "$CONFIG")
fi
# The bucket family of the model in use: gemini-* slugs draw on the gemini buckets, every
# other slug (claude-*, gpt-*) on the third-party ones. Empty = weigh every bucket.
FAMILY=""
case "$MODEL" in
  '') ;;
  gemini-*) FAMILY=gemini ;;
  *) FAMILY=3p ;;
esac

if [ ! -f "$FILE" ]; then
  echo '{"state":"unknown","window":null,"used":null,"resets_at":null,"age":null,"reason":"no usage snapshot — add the record line to your status-line script (run-workflow.md)"}'
  exit 3
fi

OUT=$(jq -c --argjson th "$THRESHOLD" --argjson maxage "$MAX_AGE" --argjson any "$ANY_WINDOW" \
         --arg family "$FAMILY" --arg model "$MODEL" '
  (now | floor) as $now
  | ($now - (.recorded_at // 0)) as $age
  # A window whose reset time has passed is a fresh window: drop it. Claude has two
  # fixed windows; an agy snapshot names its buckets: the family'"'"'s own (<family>-5h,
  # <family>-weekly) always count, a model-specific one (<family>-<model>-…) only when
  # the slug names that model, and with no known family every bucket counts.
  | [ (.rate_limits // {}) | to_entries[]
      | select($any or .key == "five_hour" or .key == "seven_day")
      | select($family == ""
               or ((.key | startswith($family + "-"))
                   and ((.key | test("^" + $family + "-(5h|weekly)$"))
                        or ((.key | capture("^" + $family + "-(?<m>[a-z0-9.]+)-") | .m) as $m
                            | ($model | ascii_downcase | contains($m))))))
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
