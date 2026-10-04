#!/usr/bin/env bash
# super-board-gh-guard.sh — worker-side rate-limit etiquette.
#
# Sourced by super-board workers (Builder / Tester / Reviewer) before any
# burst of gh calls. The dispatcher's gh_rate_guard only protects the
# dispatcher's own ticks; workers run as independent claude -p sessions and
# share the same gh-auth bucket. Without this guard, a single Reviewer in
# adversarial mode can drain the 5000/hr GraphQL bucket and the next tick
# of the dispatcher (and every other worker on the same machine) opens to
# "0 remaining".
#
# Usage from a worker:
#   source scripts/super-board-gh-guard.sh
#   sb_gh_guard_check 200     # sleep until reset if GraphQL remaining < 200
#   sb_gh_budget_spend 5      # decrement worker-local call budget; halt if 0
#   sb_gh_guard_summary       # log remaining quota; safe to call frequently
#
# Constants
SB_GH_GUARD_MIN_REMAINING_DEFAULT=200
SB_GH_GUARD_REST_MIN_REMAINING=500
SB_GH_GUARD_BUDGET_DEFAULT=150     # per-worker soft cap on gh calls
SB_GH_GUARD_SUBAGENT_BUDGET=50     # per adversarial-mode sub-agent cap
SB_GH_GUARD_STATE_FILE="${SB_GH_GUARD_STATE_FILE:-${TMPDIR:-/tmp}/super-board-gh-budget-$$}"

SB_GITHUB_READ="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/super-board-github-read.py"
sb_gh_required_read() { local kind="$1"; shift; python3 "$SB_GITHUB_READ" --kind "$kind" -- "$@"; }
sb_gh_halt_check() { python3 "$SB_GITHUB_READ" --check; }

# `gh api rate_limit` (REST) misreports the GraphQL bucket. Measured 2026-10-04,
# back to back on one token: REST said graphql used=2 remaining=4998 while
# GraphQL's own rateLimit said used=930 — and an hour earlier REST said 4999
# while the board was stalled at 0. So the GraphQL numbers come from GraphQL's
# rateLimit object (a rateLimit-only query is not charged), the core numbers
# from REST. Arg 1: the REST payload; prints it with .resources.graphql replaced
# when the GraphQL read succeeds, unchanged when it does not.
sb_gh_quota_merge() {
  local rest="$1" gql
  gql=$(gh api graphql -f query='query{rateLimit{limit remaining used resetAt}}' 2>/dev/null) || { echo "$rest"; return 0; }
  echo "$rest" | jq --argjson g "$gql" '
    ($g.data.rateLimit // null) as $r
    | if $r == null then . else
        .resources.graphql = { limit: $r.limit, remaining: $r.remaining, used: $r.used,
                               reset: ($r.resetAt | fromdateiso8601) } end' 2>/dev/null || echo "$rest"
}

sb_gh_guard_check() {
  # Sleep until GraphQL quota recovers. Also checks REST.
  # Arg 1: optional minimum-remaining threshold (default 200).
  local min="${1:-$SB_GH_GUARD_MIN_REMAINING_DEFAULT}"
  local payload graphql_remaining graphql_reset rest_remaining now wait
  payload=$(sb_gh_required_read quota api rate_limit) || return $?
  payload=$(sb_gh_quota_merge "$payload")
  graphql_remaining=$(echo "$payload" | jq -r '.resources.graphql.remaining // 5000')
  rest_remaining=$(echo "$payload" | jq -r '.resources.core.remaining // 5000')

  if [ "$graphql_remaining" -lt "$min" ]; then
    graphql_reset=$(echo "$payload" | jq -r '.resources.graphql.reset // 0')
    now=$(date +%s)
    wait=$((graphql_reset - now + 10))
    [ "$wait" -lt 60 ] && wait=60
    [ "$wait" -gt 3600 ] && wait=3600
    echo "[gh-guard] GraphQL low: ${graphql_remaining} left (<${min}); sleeping ${wait}s" >&2
    sleep "$wait"
    return 0
  fi

  if [ "$rest_remaining" -lt "$SB_GH_GUARD_REST_MIN_REMAINING" ]; then
    echo "[gh-guard] REST low: ${rest_remaining} left — pausing 60s to let the token breathe" >&2
    sleep 60
  fi
}

sb_gh_guard_summary() {
  # One-line snapshot. Use in worker exit messages for trend tracking.
  local payload
  payload=$(sb_gh_quota_merge "$(gh api rate_limit 2>/dev/null || echo '{}')")
  echo "[gh-guard] $(echo "$payload" | jq -r '"graphql=\(.resources.graphql.remaining // "?")/\(.resources.graphql.limit // "?") rest=\(.resources.core.remaining // "?")/\(.resources.core.limit // "?")"')"
}

sb_gh_budget_init() {
  # Initialize per-worker budget. Call once at worker start.
  local budget="${1:-$SB_GH_GUARD_BUDGET_DEFAULT}"
  echo "$budget" > "$SB_GH_GUARD_STATE_FILE"
}

sb_gh_budget_spend() {
  # Decrement budget by N (default 1). If exhausted, halt the worker.
  local cost="${1:-1}" remaining
  [ -f "$SB_GH_GUARD_STATE_FILE" ] || sb_gh_budget_init
  remaining=$(cat "$SB_GH_GUARD_STATE_FILE")
  remaining=$((remaining - cost))
  echo "$remaining" > "$SB_GH_GUARD_STATE_FILE"
  if [ "$remaining" -le 0 ]; then
    echo "[gh-guard] worker gh-call budget exhausted — halting to protect shared quota" >&2
    return 73
  fi
}

sb_gh_budget_remaining() {
  [ -f "$SB_GH_GUARD_STATE_FILE" ] || sb_gh_budget_init
  cat "$SB_GH_GUARD_STATE_FILE"
}
