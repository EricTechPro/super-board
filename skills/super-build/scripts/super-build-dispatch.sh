#!/usr/bin/env bash
# super-build-dispatch.sh — dispatch a single GitHub issue to a headless `claude -p` worker.
#
# Contract (per .claude/skills/super-build/SKILL.md):
#   - Arg: issue number N
#   - Env: BASE_BRANCH (required) — the branch the worktree is created from
#          REPO_DIR    (optional) — defaults to PWD; the working repo root
#          SKILL_DIR   (optional) — defaults to the dir this script lives in's parent
#          MAX_TURNS   (optional) — default 250
#   - Side effects:
#       * git worktree add -b loop/issue-N .worktrees/issue-N BASE_BRANCH
#       * runs `claude -p` inside that worktree with the composed prompt
#       * captures stdout+stderr to .planning/super-build-logs/issue-N.log
#   - Exit codes:
#       0  success           — worker produced `chore(loop): close #N` commit on loop/issue-N
#       2  worker non-zero   — `claude -p` exited non-zero AND no recognizable done/WIP marker
#       3  no done-commit    — `claude -p` exited zero but no `chore(loop): close #N` commit
#       4  HUMAN GATE        — log contains `HUMAN GATE TRIPPED:`
#       5  WIP-PARTIAL       — log final assistant message starts with `WIP-PARTIAL:` AND
#                              a `wip(loop): #N partial` commit exists on the branch
#
# Notes:
#   - The dispatcher never merges, never closes the issue, never edits labels — those
#     are the orchestrator's job. This script just runs the worker and reports outcome.
#   - The worktree is left intact in all exit paths so a human can inspect it.

set -uo pipefail

N="${1:-}"
if [[ -z "$N" ]]; then
  echo "usage: $0 <issue-number>" >&2
  exit 64
fi

if ! [[ "$N" =~ ^[0-9]+$ ]]; then
  echo "error: issue number must be numeric, got: $N" >&2
  exit 64
fi

BASE_BRANCH="${BASE_BRANCH:-}"
if [[ -z "$BASE_BRANCH" ]]; then
  echo "error: BASE_BRANCH env var is required" >&2
  exit 64
fi

REPO_DIR="${REPO_DIR:-$PWD}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SKILL_DIR="${SKILL_DIR:-$(cd "$SCRIPT_DIR/.." && pwd)}"
MAX_TURNS="${MAX_TURNS:-250}"

PREAMBLE="$SKILL_DIR/references/worker-preamble.md"
if [[ ! -f "$PREAMBLE" ]]; then
  echo "error: worker preamble not found at $PREAMBLE" >&2
  exit 64
fi

cd "$REPO_DIR" || { echo "error: cannot cd to REPO_DIR=$REPO_DIR" >&2; exit 64; }

# Verify we're in a git repo
if ! git rev-parse --git-dir >/dev/null 2>&1; then
  echo "error: $REPO_DIR is not a git repository" >&2
  exit 64
fi

# Verify base branch exists locally or on origin
if ! git rev-parse --verify "$BASE_BRANCH" >/dev/null 2>&1; then
  if ! git rev-parse --verify "origin/$BASE_BRANCH" >/dev/null 2>&1; then
    echo "error: base branch '$BASE_BRANCH' not found locally or on origin" >&2
    exit 64
  fi
fi

WORKTREE_DIR=".worktrees/issue-$N"
WORKER_BRANCH="loop/issue-$N"
LOG_DIR="$REPO_DIR/.planning/super-build-logs"
LOG_FILE="$LOG_DIR/issue-$N.log"
PROMPT_FILE="$LOG_DIR/issue-$N.prompt.md"

mkdir -p "$LOG_DIR"

# Refuse to clobber an existing worktree/branch silently
if [[ -e "$WORKTREE_DIR" ]]; then
  echo "error: worktree path $WORKTREE_DIR already exists — refusing to clobber" >&2
  echo "       (remove with: git worktree remove $WORKTREE_DIR && git branch -D $WORKER_BRANCH)" >&2
  exit 64
fi
if git rev-parse --verify "$WORKER_BRANCH" >/dev/null 2>&1; then
  echo "error: branch $WORKER_BRANCH already exists — refusing to clobber" >&2
  exit 64
fi

# Compose the worker prompt: preamble + issue body + working-dir footer
ISSUE_JSON=$(gh issue view "$N" --json number,title,body,labels 2>&1) || {
  echo "error: gh issue view #$N failed:" >&2
  echo "$ISSUE_JSON" >&2
  exit 64
}

ISSUE_TITLE=$(printf '%s' "$ISSUE_JSON" | jq -r '.title')
ISSUE_BODY=$(printf '%s' "$ISSUE_JSON" | jq -r '.body')

{
  cat "$PREAMBLE"
  printf '\n# Issue #%s — %s\n\n' "$N" "$ISSUE_TITLE"
  printf '%s\n' "$ISSUE_BODY"
  printf '\n---\n\n'
  printf 'Working directory: %s/%s (branch %s, based on %s)\n' "$REPO_DIR" "$WORKTREE_DIR" "$WORKER_BRANCH" "$BASE_BRANCH"
  printf 'Log file: %s/%s\n' "$REPO_DIR" "$LOG_FILE"
} > "$PROMPT_FILE"

# Create the worktree on a fresh branch off BASE_BRANCH
if ! git worktree add -b "$WORKER_BRANCH" "$WORKTREE_DIR" "$BASE_BRANCH" >>"$LOG_FILE" 2>&1; then
  echo "error: git worktree add failed — see $LOG_FILE" >&2
  exit 64
fi

# Record the base SHA so we can diff afterward
BASE_SHA=$(git -C "$WORKTREE_DIR" rev-parse HEAD)

echo "▶︎ dispatching worker for issue #$N — worktree $WORKTREE_DIR — base $BASE_BRANCH @ ${BASE_SHA:0:7}" | tee -a "$LOG_FILE"

# Run the worker. stdin gets the composed prompt; stdout+stderr both stream to the log.
# We do NOT use --output-format stream-json here because we want a plain-text log we
# can grep for the HUMAN GATE / WIP-PARTIAL markers. The orchestrator gets the same log.
WORKER_EXIT=0
(
  cd "$WORKTREE_DIR" || exit 99
  exec claude -p \
    --dangerously-skip-permissions \
    --max-turns "$MAX_TURNS" \
    < "$PROMPT_FILE"
) >>"$LOG_FILE" 2>&1 || WORKER_EXIT=$?

echo "▶︎ worker for issue #$N exited with code $WORKER_EXIT" | tee -a "$LOG_FILE"

# Inspect outcome on the worker branch
HEAD_SHA=$(git -C "$WORKTREE_DIR" rev-parse HEAD)
COMMITS_RANGE="${BASE_SHA}..${HEAD_SHA}"

CLOSE_COMMIT=""
WIP_COMMIT=""
if [[ "$BASE_SHA" != "$HEAD_SHA" ]]; then
  CLOSE_COMMIT=$(git -C "$WORKTREE_DIR" log --format="%H %s" "$COMMITS_RANGE" 2>/dev/null \
    | grep -E "^[0-9a-f]+ chore\(loop\): close #$N( |$)" | head -1 || true)
  WIP_COMMIT=$(git -C "$WORKTREE_DIR" log --format="%H %s" "$COMMITS_RANGE" 2>/dev/null \
    | grep -E "^[0-9a-f]+ wip\(loop\): #$N partial" | head -1 || true)
fi

# Detect HUMAN GATE in log
if grep -q "HUMAN GATE TRIPPED:" "$LOG_FILE"; then
  echo "▶︎ HUMAN GATE TRIPPED detected in log for issue #$N" | tee -a "$LOG_FILE"
  exit 4
fi

# Detect WIP-PARTIAL: requires both the literal log marker AND a wip commit
if [[ -n "$WIP_COMMIT" ]] && grep -q "^WIP-PARTIAL:" "$LOG_FILE"; then
  echo "▶︎ WIP-PARTIAL detected for issue #$N: $WIP_COMMIT" | tee -a "$LOG_FILE"
  exit 5
fi

# Detect success: chore(loop): close commit present
if [[ -n "$CLOSE_COMMIT" ]]; then
  if [[ "$WORKER_EXIT" -ne 0 ]]; then
    echo "▶︎ worker exited non-zero ($WORKER_EXIT) but produced close-commit; treating as success" | tee -a "$LOG_FILE"
  fi
  echo "▶︎ success: $CLOSE_COMMIT" | tee -a "$LOG_FILE"
  exit 0
fi

# No done-commit
if [[ "$WORKER_EXIT" -ne 0 ]]; then
  echo "▶︎ worker failed (exit $WORKER_EXIT) with no done-commit" | tee -a "$LOG_FILE"
  exit 2
fi

echo "▶︎ worker exited 0 but produced no chore(loop): close #$N commit" | tee -a "$LOG_FILE"
exit 3
