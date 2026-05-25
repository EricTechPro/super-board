#!/usr/bin/env bash
# super-board-stop.sh — graceful shutdown of an in-flight super-board run.
#
# What it does:
#   1. Find every in-flight worker (lock files under .claude/super-board/inflight/).
#   2. For each one, post a "stopped mid-flight" comment on the issue AND its PR
#      (with last commit, lane, and resume hint) — so context survives the kill.
#   3. Release the GitHub assignee mutex on each claimed issue.
#   4. SIGTERM → 1s → SIGKILL the worker PIDs.
#   5. Kill the dispatcher loop (super-board-run.sh).
#   6. Remove in-flight locks. Leave worktrees in place (Builder can resume).
#   7. Print summary + resume command.
#
# What it does NOT do:
#   - Wait for workers to reach a clean stopping point (claude -p has no SIGTERM
#     handler that flushes a partial commit). Any uncommitted edits are lost.
#   - Touch worktrees. Leaving them lets the next worker pick up faster.
#   - Touch branches or PRs. State lives on the GitHub Project board.
#
# Resume:
#   super-board run <slug>     — same command. The board is the state. Cards sit
#                                in whichever column they were in. Workers re-claim
#                                from the "stopped" comment context.
#
# Usage:
#   scripts/super-board-stop.sh [<config-slug>]
#
# Exit codes:
#   0  clean stop (or nothing to stop)
#   64 missing arg + no .claude/super-board/active
#   66 config not found

set -euo pipefail

# ───────────────────────────── args + paths ─────────────────────────────
CONFIG_SLUG="${1:-}"
if [ -z "$CONFIG_SLUG" ]; then
  if [ -f .claude/super-board/active ]; then
    CONFIG_SLUG=$(cat .claude/super-board/active)
  else
    echo "usage: $0 <config-slug>  (or set .claude/super-board/active)" >&2
    exit 64
  fi
fi

CONFIG_PATH=".claude/super-board/configs/${CONFIG_SLUG}.json"
if [ ! -f "$CONFIG_PATH" ]; then
  echo "config not found: $CONFIG_PATH" >&2
  exit 66
fi

# ───────────────────────────── config read ─────────────────────────────
BOT_LOGIN=$(jq -r '.notifications.bot_identity // .bot_identity // ""' "$CONFIG_PATH")
INFLIGHT_DIR=".claude/super-board/inflight"
RUN_DATE=$(date +%Y-%m-%d)
RUN_MANIFEST="docs/super-board/runs/${RUN_DATE}-${CONFIG_SLUG}.md"
TS=$(date -u +%Y-%m-%dT%H:%M:%SZ)

# ───────────────────────────── helpers ─────────────────────────────
log() {
  printf '[%s] %s\n' "$(date +%H:%M:%S)" "$*"
  [ -f "$RUN_MANIFEST" ] && printf '[%s] STOP %s\n' "$(date +%H:%M:%S)" "$*" >> "$RUN_MANIFEST" || true
}

# Source a lock file. Supports both v1.3.0+ (PID=/LANE=/STARTED= assignments)
# and pre-v1.3.0 (single-line PID) formats.
read_lock() {
  local lock="$INFLIGHT_DIR/$1"
  PID=""; LANE=""; STARTED=""
  [ -f "$lock" ] || return 1
  if grep -q '^PID=' "$lock" 2>/dev/null; then
    # shellcheck disable=SC1090
    . "$lock" 2>/dev/null || true
  else
    PID=$(cat "$lock" 2>/dev/null || echo "")
  fi
  return 0
}

# Look up the PR number for an issue's branch (if any). One gh call.
pr_for_issue() {
  local issue="$1"
  gh pr list --state open --json number,headRefName \
    --jq ".[] | select(.headRefName | startswith(\"issue-${issue}-\")) | .number" 2>/dev/null | head -1
}

# Latest commit on the issue's branch (local or remote). Best-effort.
last_commit_on_branch() {
  local issue="$1" branch
  branch=$(git branch -a --list "*issue-${issue}-*" 2>/dev/null | head -1 | sed 's|^[* ]*||;s|^remotes/[^/]*/||')
  [ -z "$branch" ] && { echo "(no branch yet)"; return; }
  git log -1 --format='%h %s' "$branch" 2>/dev/null || echo "(branch found but no commits)"
}

post_stop_comment() {
  local issue="$1" lane="$2" pid="$3" pr commit body
  commit=$(last_commit_on_branch "$issue")
  pr=$(pr_for_issue "$issue" || echo "")

  body="🛑 super-board · stopped mid-flight

\`\`\`
Lane:        ${lane:-unknown}
Worker PID:  ${pid:-unknown} (terminated by super-board stop at ${TS})
Last commit: ${commit}
\`\`\`

The dispatcher was halted by \`super-board stop\`. Any uncommitted edits in the
worker's worktree were discarded; the last pushed commit above is the resume
point.

**Resume:** \`super-board run ${CONFIG_SLUG}\` — the board is the state. This
card will be re-claimed and the ${lane:-target} lane will start over from the
last pushed commit. AC review / test rerun is idempotent."

  gh issue comment "$issue" --body "$body" >/dev/null 2>&1 \
    && log "  💬 issue comment posted on #${issue}" \
    || log "  ⚠ failed to comment on issue #${issue} (continuing)"

  if [ -n "$pr" ]; then
    gh pr comment "$pr" --body "$body" >/dev/null 2>&1 \
      && log "  💬 PR comment posted on #${pr}" \
      || log "  ⚠ failed to comment on PR #${pr} (continuing)"
  fi
}

release_claim() {
  local issue="$1"
  [ -z "$BOT_LOGIN" ] && return 0
  gh issue edit "$issue" --remove-assignee "$BOT_LOGIN" >/dev/null 2>&1 || true
  for label in loop:in-build loop:in-qa loop:in-review; do
    gh issue edit "$issue" --remove-label "$label" >/dev/null 2>&1 || true
  done
  log "  🔓 released assignee + lane labels on #${issue}"
}

kill_pid() {
  local pid="$1" name="${2:-process}"
  if [ -z "$pid" ] || ! kill -0 "$pid" 2>/dev/null; then
    log "  ⊘ ${name} pid=${pid:-empty} already dead"
    return 0
  fi
  kill -TERM "$pid" 2>/dev/null || true
  sleep 1
  if kill -0 "$pid" 2>/dev/null; then
    kill -KILL "$pid" 2>/dev/null || true
    log "  ☠ ${name} pid=${pid} SIGKILLed (didn't respond to SIGTERM)"
  else
    log "  ☠ ${name} pid=${pid} SIGTERMed"
  fi
}

# ───────────────────────────── main ─────────────────────────────
echo "════════════════════════════════════════════════════════"
echo "  super-board stop · ${CONFIG_SLUG}"
echo "════════════════════════════════════════════════════════"

# 1. Inventory in-flight workers BEFORE killing anything.
WORKERS=()
if [ -d "$INFLIGHT_DIR" ]; then
  for lock in "$INFLIGHT_DIR"/*; do
    [ -e "$lock" ] || continue
    issue=$(basename "$lock")
    read_lock "$issue"
    WORKERS+=("${issue}|${LANE:-unknown}|${PID:-}")
  done
fi

DISPATCHER_PIDS=$(pgrep -f 'super-board-run\.sh' 2>/dev/null || true)
ORPHAN_WORKERS=$(pgrep -f 'claude -p .*super-board' 2>/dev/null || true)

if [ "${#WORKERS[@]}" -eq 0 ] && [ -z "$DISPATCHER_PIDS" ] && [ -z "$ORPHAN_WORKERS" ]; then
  echo "  ✓ nothing to stop — no dispatcher, no in-flight workers, no orphans"
  echo "════════════════════════════════════════════════════════"
  exit 0
fi

# 2. Per-worker wrap-up: comment, release claim, kill.
if [ "${#WORKERS[@]}" -gt 0 ]; then
  log "📋 ${#WORKERS[@]} in-flight worker(s) to wrap up"
  for entry in "${WORKERS[@]}"; do
    IFS='|' read -r issue lane pid <<< "$entry"
    log ""
    log "─── #${issue} (lane=${lane}, pid=${pid:-unknown}) ───"
    post_stop_comment "$issue" "$lane" "$pid"
    release_claim "$issue"
    kill_pid "$pid" "worker(${lane}/#${issue})"
  done
fi

# 3. Sweep any untracked claude -p super-board workers.
if [ -n "$ORPHAN_WORKERS" ]; then
  log ""
  log "🧹 sweeping untracked claude -p super-board workers"
  for pid in $ORPHAN_WORKERS; do
    kill_pid "$pid" "orphan-worker"
  done
fi

# 4. Kill the dispatcher loop.
if [ -n "$DISPATCHER_PIDS" ]; then
  log ""
  log "🛑 stopping dispatcher loop"
  for pid in $DISPATCHER_PIDS; do
    kill_pid "$pid" "dispatcher"
  done
fi

# 5. Clear in-flight locks (PIDs are dead now).
if [ -d "$INFLIGHT_DIR" ] && [ -n "$(ls -A "$INFLIGHT_DIR" 2>/dev/null)" ]; then
  rm -f "$INFLIGHT_DIR"/*
  log ""
  log "🧽 cleared $INFLIGHT_DIR"
fi

# 6. Summary.
DISP_COUNT=$(echo "$DISPATCHER_PIDS" | tr ' ' '\n' | grep -c . || true)
echo ""
echo "════════════════════════════════════════════════════════"
echo "  ✅ stopped: ${#WORKERS[@]} worker(s), ${DISP_COUNT} dispatcher(s)"
echo "  📝 wrap-up comments posted on each in-flight issue + PR"
echo "  ▶  Resume: super-board run ${CONFIG_SLUG}"
echo "════════════════════════════════════════════════════════"
