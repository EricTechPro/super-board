#!/usr/bin/env bash
# super-board-run.sh — headless autonomous runner.
# Spawned as `nohup scripts/super-board-run.sh <config-slug> &`.
# Pure shell while-loop. Dispatches `claude -p` workers per lane.
# Holds NO Claude session state — re-reads GitHub on every tick.
#
# Anti-zombie controls (added 2026-05-22 after #381 worker-storm incident):
#   1. Orphan scan on startup — refuses to start if super-board claude workers already running.
#   2. Issue-level lock files in .claude/super-board/inflight/<N> — survives runner restart.
#   3. Atomic GitHub assignee claim BEFORE spawning worker (closes 10-30s claude -p cold-start race).
#   4. Rate-limit guard — sleeps until reset when GraphQL remaining < 200.
#   5. Per-tick project-items cache — one gh call per tick, not per column lookup.
#   6. Tick interval bumped from 30s → 120s (GraphQL ProjectsV2 query is ~103 pts; 120s keeps usage <3.1k/hr vs 5k budget).
#   7. Lane-zombie watchdog (added 2026-05-24 after fitbox-v4 first-run hang) — kills lane PIDs whose
#      claimed issue has already moved out of the lane's expected source column. The worker's logical
#      work is done; if the claude -p process lingers, lane appears busy forever and downstream cards
#      pile up unprocessed. Uses the project-items cache so it costs zero extra API calls per tick.

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
VARIANT=$(jq -r '.variant' "$CONFIG_PATH")
PROJECT_OWNER=$(jq -r '.project.owner' "$CONFIG_PATH")
PROJECT_NUMBER=$(jq -r '.project.number' "$CONFIG_PATH")
BASE_BRANCH=$(jq -r '.base_branch // "main"' "$CONFIG_PATH")
HUMAN_APPROVES=$(jq -r '.human_approves_merge // false' "$CONFIG_PATH")
REBUILD_CAP=$(jq -r '.rebuild_cap // 2' "$CONFIG_PATH")
BLOCK_ALERT_PCT=$(jq -r '.block_rate_alert_pct // 30' "$CONFIG_PATH")
TICK_SECONDS=$(jq -r '.tick_seconds // 120' "$CONFIG_PATH")
MAX_WORKERS=$(jq -r '.max_workers // 3' "$CONFIG_PATH")
BOT_LOGIN=$(jq -r '.notifications.bot_identity // .bot_identity // ""' "$CONFIG_PATH")
WORKER_BACKEND=$(jq -r '.worker_backend // "workflow"' "$CONFIG_PATH")

# Workflow is the default backend (v1.6.0). This legacy dispatcher only runs
# when the config opts in explicitly — never by accident or stale habit.
if [ "$WORKER_BACKEND" != "claude-p" ]; then
  echo "🛑 board '${CONFIG_SLUG}' uses the workflow backend (worker_backend=${WORKER_BACKEND})." >&2
  echo "    Run it in-session: /super-board run ${CONFIG_SLUG}  (see references/run-workflow.md)" >&2
  echo "    To use this legacy dispatcher, set \"worker_backend\": \"claude-p\" in the config." >&2
  exit 78
fi

RUN_DATE=$(date +%Y-%m-%d)
RUN_MANIFEST="docs/super-board/runs/${RUN_DATE}-${CONFIG_SLUG}.md"
INFLIGHT_DIR=".claude/super-board/inflight"
mkdir -p "docs/super-board/runs" .worktrees "$INFLIGHT_DIR"

# ───────────────────────────── helpers ─────────────────────────────
log() { printf '[%s] %s\n' "$(date +%H:%M:%S)" "$*" | tee -a "$RUN_MANIFEST"; }

PROJECT_ITEMS_JSON=""
fetch_project_items() {
  # One gh call per tick; all column lookups read from this cache.
  PROJECT_ITEMS_JSON=$(gh project item-list "$PROJECT_NUMBER" --owner "$PROJECT_OWNER" --format json --limit 500 2>/dev/null || echo '{"items":[]}')
}

column_count() {
  echo "$PROJECT_ITEMS_JSON" | jq --arg col "$1" '[.items[] | select(.status == $col)] | length'
}

top_card_in_column() {
  # Returns the FIRST issue number in $1 with no assignee AND no local in-flight lock.
  local col="$1" issue
  for issue in $(echo "$PROJECT_ITEMS_JSON" | jq -r --arg col "$col" '
        .items[]
        | select(.status == $col and .content.type == "Issue")
        | select((.content.assignees // []) | length == 0)
        | .content.number'); do
    if ! issue_locked "$issue"; then
      echo "$issue"
      return 0
    fi
  done
}

read_lock() {
  # Reads $INFLIGHT_DIR/$1 (bash-assignment format) into PID/LANE/STARTED.
  # Sets empty strings if the file is missing or legacy single-PID format.
  local lock="$INFLIGHT_DIR/$1"
  PID=""; LANE=""; STARTED=""
  [ -f "$lock" ] || return 1
  if grep -q '^PID=' "$lock" 2>/dev/null; then
    # shellcheck disable=SC1090
    . "$lock" 2>/dev/null || true
  else
    # Legacy format (pre v1.3.0): single line PID only.
    PID=$(cat "$lock" 2>/dev/null || echo "")
  fi
  return 0
}

issue_locked() {
  # Returns 0 if the issue has a live in-flight lock; cleans stale locks.
  local issue="$1" lock="$INFLIGHT_DIR/$1"
  [ -f "$lock" ] || return 1
  read_lock "$issue"
  if [ -n "$PID" ] && kill -0 "$PID" 2>/dev/null; then
    return 0
  fi
  rm -f "$lock"
  return 1
}

lane_idle() {
  local pid="${1:-}"
  [ -z "$pid" ] || ! kill -0 "$pid" 2>/dev/null
}

gh_rate_guard() {
  # Sleep until rate limit resets if GraphQL remaining < 200.
  local payload remaining reset now wait
  payload=$(gh api rate_limit 2>/dev/null || echo '{"resources":{"graphql":{"remaining":5000,"reset":0}}}')
  remaining=$(echo "$payload" | jq -r '.resources.graphql.remaining // 5000')
  if [ "$remaining" -lt 200 ]; then
    reset=$(echo "$payload" | jq -r '.resources.graphql.reset // 0')
    now=$(date +%s)
    wait=$((reset - now + 10))
    [ "$wait" -lt 60 ] && wait=60
    log "⚠ GraphQL rate limit low (${remaining} left) — sleeping ${wait}s until reset"
    sleep "$wait"
  fi
}

try_claim_assignee() {
  # Atomic claim. Returns 0 if we won the claim, 1 if someone else beat us.
  # Skipped when bot_identity is unset (solo single-user runs rely on local locks only).
  # We rely on `top_card_in_column` having already filtered out cards with assignees
  # from the cached project item-list — so we attempt the edit directly without a
  # pre-check `gh issue view`. Saves one GraphQL call per dispatch. The edit is
  # idempotent for self-assign; on race-loss, gh returns non-zero and we skip.
  local issue="$1"
  [ -z "$BOT_LOGIN" ] && return 0
  gh issue edit "$issue" --add-assignee "$BOT_LOGIN" >/dev/null 2>&1 || {
    log "claim failed on #${issue} (race or gh api error) — skipping this tick"
    return 1
  }
  return 0
}

dispatch_lane() {
  # $1 = lane (build|qa|review); $2 = issue number
  local lane="$1" issue="$2" prompt pid
  if issue_locked "$issue"; then
    log "skip dispatch lane=${lane} issue=#${issue} — already locked"
    return 0
  fi
  if ! try_claim_assignee "$issue"; then
    return 0
  fi
  case "$lane" in
    build)  prompt="Run super-build on issue #${issue} for super-board run. Read .claude/skills/super-board/references/run.md → Builder lifecycle. Config: ${CONFIG_PATH}." ;;
    qa)     prompt="Run super-qa on issue #${issue} for super-board run. Read .claude/skills/super-board/references/run.md → Tester lifecycle. Config: ${CONFIG_PATH}." ;;
    review) prompt="Run super-review on issue #${issue} for super-board run. Read .claude/skills/super-board/references/run.md → Reviewer lifecycle. Config: ${CONFIG_PATH}." ;;
    *) log "unknown lane: $lane"; return 1 ;;
  esac
  nohup claude -p "$prompt" >/dev/null 2>&1 &
  pid=$!
  # v1.3.0+ lock format: bash-assignment style so `super-board stop` can source it
  # to recover lane + dispatch time. issue_locked()/reap_finished_locks() still work
  # because PID= is the first line.
  printf 'PID=%s\nLANE=%s\nSTARTED=%s\n' "$pid" "$lane" "$(date -u +%FT%TZ)" > "$INFLIGHT_DIR/$issue"
  case "$lane" in
    build) BUILD_PID="$pid"; BUILD_ISSUE="$issue" ;;
    qa) QA_PID="$pid"; QA_ISSUE="$issue" ;;
    review) REVIEW_PID="$pid"; REVIEW_ISSUE="$issue" ;;
  esac
  log "dispatch lane=${lane} issue=#${issue} pid=${pid} claim=${BOT_LOGIN:-local-only}"
}

issue_status() {
  # Lookup issue #$1 in the cached project items; emit its current column name (or empty).
  echo "$PROJECT_ITEMS_JSON" | jq -r --arg n "$1" '
    .items[] | select(.content.number == ($n | tonumber)) | .status' | head -1
}

check_lane_zombie() {
  # $1 = lane name (build|qa|review); $2 = space-separated list of expected source columns.
  # If the lane's worker PID is alive but its claimed issue has already moved to a column
  # NOT in the expected source set, the worker's logical work is done — kill the zombie
  # process and free the lane. Uses cached project items only (no extra API calls).
  local lane="$1" expected="$2" pid="" issue=""
  case "$lane" in
    build)  pid="$BUILD_PID";  issue="$BUILD_ISSUE" ;;
    qa)     pid="$QA_PID";     issue="$QA_ISSUE" ;;
    review) pid="$REVIEW_PID"; issue="$REVIEW_ISSUE" ;;
    *) return 1 ;;
  esac
  [ -z "$pid" ] && return 0
  [ -z "$issue" ] && return 0
  kill -0 "$pid" 2>/dev/null || return 0   # already dead → reap_finished_locks handles it
  local cur found=0 col
  cur=$(issue_status "$issue")
  [ -z "$cur" ] && return 0                # not in cache (closed/deleted/race) → don't kill
  for col in $expected; do
    [ "$cur" = "$col" ] && found=1
  done
  if [ "$found" -eq 0 ]; then
    log "💀 zombie ${lane} worker on #${issue} (pid=${pid}) — card moved to '${cur}'; killing"
    kill "$pid" 2>/dev/null || true
    sleep 1
    kill -9 "$pid" 2>/dev/null || true
    rm -f "$INFLIGHT_DIR/$issue"
    [ -n "$BOT_LOGIN" ] && gh issue edit "$issue" --remove-assignee "$BOT_LOGIN" >/dev/null 2>&1 || true
    case "$lane" in
      build)  BUILD_PID="";  BUILD_ISSUE="" ;;
      qa)     QA_PID="";     QA_ISSUE="" ;;
      review) REVIEW_PID=""; REVIEW_ISSUE="" ;;
    esac
  fi
}

sweep_lane_zombies() {
  check_lane_zombie build  "Ready Building"
  check_lane_zombie qa     "QA"
  check_lane_zombie review "Review"
}

reap_finished_locks() {
  # Sweep inflight/ for dead PIDs; remove locks AND sweep stale assignees so the
  # next dispatch can re-claim the card if the worker crashed without releasing.
  # The assignee remove is idempotent — no-op if the worker exited cleanly.
  local lock issue
  for lock in "$INFLIGHT_DIR"/*; do
    [ -f "$lock" ] || continue
    issue=$(basename "$lock")
    # Issue locks only: basenames are issue numbers. Anything else (e.g. the
    # workflow backend's workflow-wave.lock) is not ours to reap — deleting it
    # would dissolve the backend mutual exclusion mid-run.
    case "$issue" in *[!0-9]*|'') continue ;; esac
    read_lock "$issue"
    if [ -z "$PID" ] || ! kill -0 "$PID" 2>/dev/null; then
      rm -f "$lock"
      if [ -n "$BOT_LOGIN" ]; then
        gh issue edit "$issue" --remove-assignee "$BOT_LOGIN" >/dev/null 2>&1 || true
        log "reaped stale lock + swept assignee on #${issue} (pid=${PID:-empty})"
      else
        log "reaped stale lock for #${issue} (pid=${PID:-empty})"
      fi
    fi
  done
}

# ───────────────────────────── preconditions ─────────────────────────────
log "super-board run started — config=${CONFIG_SLUG} variant=${VARIANT} base=${BASE_BRANCH} tick=${TICK_SECONDS}s max_workers=${MAX_WORKERS}"

# Orphan-worker guard. `|| true` defends against pipefail when pgrep finds nothing.
ORPHANS=$(pgrep -f 'claude -p .*super-board run' 2>/dev/null | grep -v "^$$\$" | wc -l | tr -d ' ' || true)
ORPHANS=${ORPHANS:-0}
if [ "$ORPHANS" -gt 0 ]; then
  log "🛑 refusing to start: ${ORPHANS} super-board claude workers already running."
  log "    Stop them first: pkill -f 'claude -p .*super-board run'"
  log "    Then re-run: $0 $CONFIG_SLUG"
  exit 73
fi

# Workflow-backend mutual exclusion (see references/run-workflow.md §Preconditions).
WAVE_LOCK=".claude/super-board/inflight/workflow-wave.lock"
if [ -f "$WAVE_LOCK" ]; then
  log "🛑 refusing to start: workflow-backend wave in flight ($WAVE_LOCK exists)."
  log "    If no wave is actually running, remove the stale lock: rm $WAVE_LOCK"
  exit 74
fi

# Production-merge guard.
if [ "$BASE_BRANCH" = "main" ] && [ "$HUMAN_APPROVES" = "false" ]; then
  if rg -qU 'on:\s*\n?\s*push:\s*\n?\s*branches:[^a-z]*main' .github/workflows 2>/dev/null \
     || [ -f vercel.json ] || [ -f netlify.toml ]; then
    log "🛡 refusing to start: would auto-merge to production main."
    exit 75
  fi
fi

# Stale-worktree scan.
if [ -d .worktrees ]; then
  for wt in .worktrees/*/; do
    [ -d "$wt" ] || continue
    branch=$(git -C "$wt" rev-parse --abbrev-ref HEAD 2>/dev/null || echo "")
    if [ -z "$branch" ] || ! git rev-parse --verify "$branch" >/dev/null 2>&1; then
      log "stale worktree: $wt (branch '$branch' missing) — removing"
      git worktree remove --force "$wt" 2>/dev/null || rm -rf "$wt"
    fi
  done
fi

# Reap any leftover stale locks from a previous crashed run.
reap_finished_locks

# ───────────────────────────── main loop ─────────────────────────────
gh_rate_guard
fetch_project_items
INITIAL_READY=$(column_count "Ready")
log "initial Ready count: $INITIAL_READY"

NO_PROGRESS_TICKS=0
BUILD_PID=""; BUILD_ISSUE=""
QA_PID=""; QA_ISSUE=""
REVIEW_PID=""; REVIEW_ISSUE=""

while true; do
  # Workflow-backend mutual exclusion, re-checked every tick: the startup
  # check alone leaves a TOCTOU window where a workflow run starting at the
  # same moment as this dispatcher is never detected by either side.
  if [ -f "$WAVE_LOCK" ]; then
    log "🛑 workflow-backend wave appeared mid-run ($WAVE_LOCK) — halting for mutual exclusion."
    log "    Resume after the wave: $0 $CONFIG_SLUG"
    exit 74
  fi

  reap_finished_locks  # cheap local sweep; runs every tick

  # ── Zombie sweep against the LAST cached project state (no extra API).
  #    Catches workers whose card already moved out of the lane's source column
  #    but whose claude -p process didn't exit. Runs every tick, even cheap ones,
  #    so a cap-reached pipeline can still self-heal when one lane is a zombie.
  sweep_lane_zombies

  # ── Free pre-check: count active lanes from local PIDs (no API calls).
  BUILD_IDLE=1; QA_IDLE=1; REVIEW_IDLE=1
  lane_idle "$BUILD_PID" || BUILD_IDLE=0
  lane_idle "$QA_PID" || QA_IDLE=0
  lane_idle "$REVIEW_PID" || REVIEW_IDLE=0

  ACTIVE_WORKERS=0
  [ "$BUILD_IDLE" -eq 1 ] || ACTIVE_WORKERS=$((ACTIVE_WORKERS + 1))
  [ "$QA_IDLE" -eq 1 ] || ACTIVE_WORKERS=$((ACTIVE_WORKERS + 1))
  [ "$REVIEW_IDLE" -eq 1 ] || ACTIVE_WORKERS=$((ACTIVE_WORKERS + 1))

  # ── Cheap-tick path: workers at cap → skip GraphQL fetch entirely.
  #    The board can't change in a way that helps us until a lane frees up.
  if [ "$ACTIVE_WORKERS" -ge "$MAX_WORKERS" ]; then
    log "tick — cap reached (${ACTIVE_WORKERS}/${MAX_WORKERS} busy) — skipping GraphQL fetch, sleeping ${TICK_SECONDS}s"
    sleep "$TICK_SECONDS"
    continue
  fi

  # ── Expensive-tick path: we have capacity, fetch real state.
  gh_rate_guard
  fetch_project_items

  # Re-sweep zombies against fresh cache; the previous sweep used stale data.
  sweep_lane_zombies
  BUILD_IDLE=1; QA_IDLE=1; REVIEW_IDLE=1
  lane_idle "$BUILD_PID" || BUILD_IDLE=0
  lane_idle "$QA_PID" || QA_IDLE=0
  lane_idle "$REVIEW_PID" || REVIEW_IDLE=0
  ACTIVE_WORKERS=0
  [ "$BUILD_IDLE" -eq 1 ] || ACTIVE_WORKERS=$((ACTIVE_WORKERS + 1))
  [ "$QA_IDLE" -eq 1 ] || ACTIVE_WORKERS=$((ACTIVE_WORKERS + 1))
  [ "$REVIEW_IDLE" -eq 1 ] || ACTIVE_WORKERS=$((ACTIVE_WORKERS + 1))

  READY=$(column_count "Ready")
  BUILDING=0
  [ "$VARIANT" = "full" ] && BUILDING=$(column_count "Building")
  QA=$(column_count "QA")
  REVIEW=$(column_count "Review")
  BLOCKED=$(column_count "Blocked")

  log "tick — Ready=$READY Building=$BUILDING QA=$QA Review=$REVIEW Blocked=$BLOCKED lanes: b_idle=$BUILD_IDLE(#${BUILD_ISSUE:-_}) q_idle=$QA_IDLE(#${QA_ISSUE:-_}) r_idle=$REVIEW_IDLE(#${REVIEW_ISSUE:-_})"

  if [ "$READY" -eq 0 ] && [ "$BUILDING" -eq 0 ] && [ "$QA" -eq 0 ] && [ "$REVIEW" -eq 0 ] \
     && [ "$BUILD_IDLE" -eq 1 ] && [ "$QA_IDLE" -eq 1 ] && [ "$REVIEW_IDLE" -eq 1 ]; then
    log "✅ all active-pipeline columns empty and all lanes idle — exiting cleanly"
    break
  fi

  if [ "${BLOCK_ALERT_SENT:-0}" -eq 0 ] && [ "$INITIAL_READY" -gt 0 ] && [ "$BLOCK_ALERT_PCT" -gt 0 ]; then
    PCT=$(( BLOCKED * 100 / INITIAL_READY ))
    if [ "$PCT" -ge "$BLOCK_ALERT_PCT" ]; then
      log "⚠ block-rate alert: ${BLOCKED}/${INITIAL_READY} (${PCT}%)"
      BLOCK_ALERT_SENT=1
    fi
  fi

  PROGRESS=0

  # ACTIVE_WORKERS already computed at top of loop (free pre-check).
  can_dispatch() {
    [ "$ACTIVE_WORKERS" -lt "$MAX_WORKERS" ]
  }

  if can_dispatch && [ "$REVIEW" -gt 0 ] && [ "$REVIEW_IDLE" -eq 1 ]; then
    card=$(top_card_in_column "Review")
    if [ -n "${card:-}" ]; then
      dispatch_lane review "$card"
      PROGRESS=1
      ACTIVE_WORKERS=$((ACTIVE_WORKERS + 1))
    fi
  fi
  if can_dispatch && [ "$QA" -gt 0 ] && [ "$QA_IDLE" -eq 1 ]; then
    card=$(top_card_in_column "QA")
    if [ -n "${card:-}" ]; then
      dispatch_lane qa "$card"
      PROGRESS=1
      ACTIVE_WORKERS=$((ACTIVE_WORKERS + 1))
    fi
  fi
  if can_dispatch && [ "$VARIANT" = "full" ] && [ "$READY" -gt 0 ] && [ "$BUILD_IDLE" -eq 1 ]; then
    card=$(top_card_in_column "Ready")
    if [ -n "${card:-}" ]; then
      dispatch_lane build "$card"
      PROGRESS=1
      ACTIVE_WORKERS=$((ACTIVE_WORKERS + 1))
    fi
  fi
  if can_dispatch && [ "$VARIANT" = "qa-only" ] && [ "$READY" -gt 0 ] && [ "$QA_IDLE" -eq 1 ]; then
    card=$(top_card_in_column "Ready")
    if [ -n "${card:-}" ]; then
      dispatch_lane qa "$card"
      PROGRESS=1
      ACTIVE_WORKERS=$((ACTIVE_WORKERS + 1))
    fi
  fi

  if [ "$PROGRESS" -eq 0 ]; then
    if [ "$BUILD_IDLE" -eq 0 ] || [ "$QA_IDLE" -eq 0 ] || [ "$REVIEW_IDLE" -eq 0 ]; then
      NO_PROGRESS_TICKS=0
    else
      NO_PROGRESS_TICKS=$((NO_PROGRESS_TICKS + 1))
      if [ "$NO_PROGRESS_TICKS" -ge 3 ]; then
        log "🛑 halt — no card progressed for 3 ticks while all lanes idle"
        break
      fi
    fi
  else
    NO_PROGRESS_TICKS=0
  fi

  sleep "$TICK_SECONDS"
done

log "super-board run finished. manifest: $RUN_MANIFEST"
