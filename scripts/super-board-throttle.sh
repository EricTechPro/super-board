#!/usr/bin/env bash
# super-board-throttle.sh — step the wave width down after a wave hits GitHub's hourly limit.
#
# WHY. On 2026-10-03 one 14-card wave spent the whole 5000/hr GraphQL bucket in about 40
# minutes; every later `gh issue/pr/project` call failed until the reset. The owner's rule:
# a wave that hits the hourly limit makes the next wave narrower — `max_workers` 3 → 2 → 1,
# floor 1 — and the step is written into the config so the next run starts narrow too.
#
# WHAT COUNTS AS A HIT. Either signal is enough:
#   - GraphQL remaining is 0, or
#   - the wave's lane results mention a rate-limit failure (`--results`, any text or JSON).
# The reading is `gh api rate_limit` passed through sb_gh_quota_merge (super-board-gh-guard.sh),
# which swaps in GraphQL's own `rateLimit` numbers: REST's `rate_limit` misreports the GraphQL
# bucket (measured 2026-10-04: REST said used=2 while GraphQL said used=930). Neither read
# costs quota. The failure text is still trusted over any reading: right after a reset
# `rate_limit` has been seen reporting 4999 while calls still failed.
#
# Usage:
#   super-board-throttle.sh --config <cfg.json> [--results <file>] [--rate <rate_limit.json>] [--dry-run]
#
# Stdout, one JSON line:
#   {"hit":true,"why":"graphql remaining 0","from":3,"to":2,"wrote":true}
# `from` 0 means unlimited; a hit on an unlimited config starts the ladder at 3.
# Exit 0 whether or not it hit (read `hit`) · 64 usage · 66 config missing.
set -euo pipefail

CONFIG=""; RESULTS=""; RATE=""; DRY=0
while [ $# -gt 0 ]; do
  case "$1" in
    --config)  CONFIG="$2"; shift 2 ;;
    --results) RESULTS="$2"; shift 2 ;;
    --rate)    RATE="$2"; shift 2 ;;
    --dry-run) DRY=1; shift ;;
    *) echo "unknown arg: $1" >&2; exit 64 ;;
  esac
done
[ -n "$CONFIG" ] && [ -f "$CONFIG" ] || { echo "config not found: ${CONFIG:-<unset>}" >&2; exit 66; }

if [ -n "$RATE" ]; then
  PAYLOAD=$(cat "$RATE")
else
  # shellcheck source=super-board-gh-guard.sh
  . "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/super-board-gh-guard.sh"
  PAYLOAD=$(sb_gh_quota_merge "$(gh api rate_limit 2>/dev/null || echo '{}')")
fi
REMAINING=$(printf '%s' "$PAYLOAD" | jq -r '.resources.graphql.remaining // "unknown"' 2>/dev/null || echo unknown)

WHY=""
[ "$REMAINING" = "0" ] && WHY="graphql remaining 0"
if [ -z "$WHY" ] && [ -n "$RESULTS" ] && [ -f "$RESULTS" ] \
   && grep -Eqi 'rate.?limit(ed)? (exceeded|hit|reached)|api rate limit|secondary rate limit|graphql.{0,40}(quota|rate.?limit)|was submitted too quickly' "$RESULTS"; then
  WHY="a lane result reports a GitHub rate-limit failure"
fi

FROM=$(jq -r '.max_workers // 0' "$CONFIG")
if [ -z "$WHY" ]; then
  jq -nc --argjson f "$FROM" '{hit:false,why:null,from:$f,to:$f,wrote:false}'
  exit 0
fi

if [ "$FROM" -le 0 ]; then TO=3; elif [ "$FROM" -gt 1 ]; then TO=$((FROM - 1)); else TO=1; fi
WROTE=false
if [ "$DRY" -eq 0 ] && [ "$TO" -ne "$FROM" ]; then
  TMP=$(mktemp "${CONFIG}.XXXXXX")
  jq --argjson n "$TO" '.max_workers = $n' "$CONFIG" > "$TMP" && mv "$TMP" "$CONFIG"
  WROTE=true
fi
jq -nc --arg w "$WHY" --argjson f "$FROM" --argjson t "$TO" --argjson wr "$WROTE" \
  '{hit:true,why:$w,from:$f,to:$t,wrote:$wr}'
