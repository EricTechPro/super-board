#!/usr/bin/env bash
# super-board-wave-plan.sh — compute the next workflow-backend wave from board state.
# Read-only: no gh writes, no locks. The orchestrator owns every mutation; this
# script only says what the next wave should contain and what should be swept.
#
# WAVE SHAPE (changed 2026-08-20 — see "why" below)
#
# A wave is no longer a fixed number of slots. It is:
#
#   every Ready card whose `## Blocked by` list is fully closed,
#   plus every card already in flight in QA or Review,
#   minus anything already claimed by an assignee.
#
# Width therefore follows the dependency graph rather than a tuning knob. On a
# board with 19 free cards the wave is 19; on a board with 2 it is 2. The
# workflow runtime caps *concurrent* agents (min(16, cpus-2)) and queues the
# rest, so dispatching wide costs nothing and finishes sooner.
#
# WHY THE OLD FIXED CAP WAS WRONG, MEASURED. On a real board on 2026-08-20,
# `max_workers` was 7 and 23 of 32 Ready cards were waiting on an open blocker.
# A cap that does not look at dependencies spends its slots on cards that will
# hit their own preflight and park — so it throttled the free cards while doing
# nothing about the blocked ones. Filtering first and then not capping is
# strictly better: fewer wasted dispatches AND more real work per wave.
#
# `max_workers` is kept as a safety valve. Absent or 0 means unlimited, which is
# the default. Set it only to deliberately throttle a machine.
#
# THE BLOCKED SWEEP. `Blocked` used to be terminal: a card parked naming the
# issue it waited on, that issue later closed, and nothing ever read the note
# back. Cards sat until a human noticed — five of them did, on the board above.
# This script now reports, in `sweep`, every Blocked card whose blockers have all
# closed. The orchestrator moves them to Ready before launching, so they join the
# very next wave.
#
# FAIL SAFE ON AN UNREADABLE DEPENDENCY LINE. A card whose `## Blocked by`
# section cannot be parsed confidently is never treated as free. It is reported
# in `flag` so the orchestrator can comment on it, and it is left where it is.
# Guessing "runnable" is how a card gets built against a base branch that does
# not have what it needs. See super-board-deps.sh for what "unreadable" means and
# the three shapes that produce it.
#
# STRANDED BUILDING CARDS. No lane selects from Building: a Builder moves its card
# Ready → Building and on to QA in one lifecycle. A wave stopped (or crashed) in
# between leaves the card in Building, and nothing ever picks it up again. The
# planner runs only between waves, after the crash-recovery sweep has stripped
# leaked claims, so a Building card with no assignee has no live worker. It is
# reported in `stranded`; the orchestrator checks its branch and worktree and
# moves it back to Ready, keeping the branch.
#
# LABEL ROUTING (v3.0.0). One board shape for every project; a card's label picks
# its lane. Three labels: `qa`, `bug`, `feature`. A Ready card labelled `qa` skips
# the Builder and goes straight to the Tester (lane "qa"); every other Ready card,
# labelled or not, is built first (lane "build"). Each picked card carries `lane`
# and its `labels`. The old per-board `variant` is gone: a config still saying
# "qa-only" is refused (exit 65) until `super-board onboard` upgrades it, because
# reading it as "full" would start building on a board meant only for testing.
#
# Usage:
#   super-board-wave-plan.sh --config <config.json> [--items <project-items.json>]
#                            [--deps <deps.json>]
# Without --items, fetches live board state via `gh project item-list`.
# Without --deps, derives the graph via super-board-deps.sh. Pass --deps in tests
# to keep the script offline.
#
# Stdout:
#   { "cards": [ {"number":10,"status":"Review","title":"…","lane":"review","labels":[]} ],
#     "sweep": [ {"number":37,"title":"…","clearedBy":[32]} ],
#     "resume": [ {"number":51,"title":"…"} ],
#     "flag":  [ {"number":82,"title":"…","why":"…"} ],
#     "stranded": [ {"number":44,"title":"…"} ] }
set -euo pipefail

CONFIG=""; ITEMS_FILE=""; DEPS_FILE=""
while [ $# -gt 0 ]; do
  case "$1" in
    --config) CONFIG="$2"; shift 2 ;;
    --items)  ITEMS_FILE="$2"; shift 2 ;;
    --deps)   DEPS_FILE="$2"; shift 2 ;;
    *) echo "unknown arg: $1" >&2; exit 64 ;;
  esac
done
[ -n "$CONFIG" ] && [ -e "$CONFIG" ] || { echo "config not found: ${CONFIG:-<unset>}" >&2; exit 66; }

# Read the config ONCE — $CONFIG may be a process substitution (test mode),
# which is a FIFO and cannot be read twice.
CONFIG_JSON=$(cat "$CONFIG")
VARIANT=$(echo "$CONFIG_JSON" | jq -r '.variant // ""')
# 0 or absent = unlimited. A wave is sized by the dependency graph, not a knob.
MAX_WORKERS=$(echo "$CONFIG_JSON" | jq -r '.max_workers // 0')
OWNER=$(echo "$CONFIG_JSON" | jq -r '.project.owner')
NUMBER=$(echo "$CONFIG_JSON" | jq -r '.project.number')

if [ -n "$ITEMS_FILE" ]; then
  ITEMS=$(cat "$ITEMS_FILE")
else
  ITEMS=$(gh project item-list "$NUMBER" --owner "$OWNER" --format json --limit 500)
fi

# `variant` was removed in v3.0.0 (labels route cards now). Absent or "full" is
# fine. Anything else — "qa-only", or a typo — is refused loudly rather than
# guessed: a guess either builds on a test-only board or strands the QA column.
case "$VARIANT" in
  ""|full) COLUMNS='["Review","QA","Ready"]' ;;
  qa-only) echo "config still says variant \"qa-only\" — removed in v3.0.0. Run /super-board onboard: it upgrades the config and labels those cards qa." >&2; exit 65 ;;
  *) echo "invalid variant in config: ${VARIANT} (variant was removed in v3.0.0 — delete the key)" >&2; exit 65 ;;
esac

# The dependency graph. Only Ready and Blocked cards are gated by it — a card in
# QA or Review already passed its own preflight and is mid-flight.
if [ -n "$DEPS_FILE" ]; then
  DEPS=$(cat "$DEPS_FILE")
else
  REPO=$(echo "$CONFIG_JSON" | jq -r '.repo.remote // ""' \
           | sed -E 's#^https?://github\.com/##; s#\.git$##')
  [ -n "$REPO" ] || { echo "config.repo.remote is required to derive dependencies" >&2; exit 66; }
  HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
  # A graph we cannot fetch is not a graph of zero blockers. Fail rather than
  # plan a wave that treats every card as free.
  DEPS=$("$HERE/super-board-deps.sh" --repo "$REPO" --limit 300) || {
    echo "could not derive the dependency graph for ${REPO}" >&2; exit 69; }
fi

# Review extras used to be gated behind human_approves_merge, because concurrent
# auto-merges into one base branch race. That guard now lives where the race
# actually is — the merge step takes a lock inside the wave workflow and the
# freshness gate re-verifies under it — so reviews may run in parallel here.
echo "$ITEMS" | jq --argjson cols "$COLUMNS" --argjson cap "$MAX_WORKERS" --argjson deps "$DEPS" '
  def dep($n): $deps[($n | tostring)];
  # gh project item-list puts label names on the item (`labels`); some shapes put
  # them on the content, as strings or {name}. Lower-cased, names only.
  def labels_of: [ ((.labels // []) + (.content.labels // []))[]
                   | (if type == "object" then .name else . end) | ascii_downcase ] | unique;
  def lane_of($status; $labels):
    if $status == "Review" then "review"
    elif $status == "QA" then "qa"
    elif ($labels | index("qa")) then "qa"
    else "build" end;
  # Unknown to the graph (closed, or beyond the fetch limit) is not "free".
  def free($n): (dep($n) | if . == null then false else .runnable end);

  [ .items[]
    | select(.content.type == "Issue")
    | select((.content.assignees // []) | length == 0)
    | labels_of as $l
    | { number: .content.number, status: .status, title: .content.title,
        lane: lane_of(.status; $l), labels: $l } ] as $all

  # In flight: already past preflight, so the graph does not gate them. Iterated
  # in $cols order (Review, then QA) rather than board order, so a throttled wave
  # spends its slots on the work closest to Done.
  | [ $cols[] as $c | $all[] | select(.status == $c and $c != "Ready") ] as $flight

  # Ready: only the ones the graph says are actually free.
  | [ $all[] | select(.status == "Ready") | select(free(.number)) ] as $ready

  # Downstream-first, so work already begun finishes before new work starts.
  | ($flight + $ready) as $picked
  | { cards: (if $cap > 0 then ($picked | .[:$cap]) else $picked end),

      # Blocked cards whose blockers have all closed. The orchestrator moves
      # these to Ready before launching, so they join this very wave.
      sweep: [ $all[]
               | select(.status == "Blocked")
               | select(free(.number))
               | { number, title,
                   clearedBy: (dep(.number) | .blockers) } ],

      # 🙋 Blocked cards whose human step is confirmed done (needs-you:done
      # label, or a "done" comment after the 🙋 block). The orchestrator moves
      # them to Review and labels the PR needs-you:done; the Reviewer re-runs
      # the merge gate, which re-verifies and merges.
      resume: [ $all[]
                | select(.status == "Blocked")
                | select(dep(.number) != null and (dep(.number).needsYouDone // false))
                | { number, title } ],

      # Cards the graph could not read. Left where they are, reported so the
      # orchestrator can ask for the line to be fixed.
      flag:  [ $all[]
               | select(.status as $s | ["Ready","Blocked"] | index($s))
               | select(dep(.number) != null and (dep(.number).parseable | not))
               | { number, title, why: (dep(.number) | .why) } ],

      # Building with no claim between waves = no live worker. Back to Ready.
      stranded: [ $all[] | select(.status == "Building") | { number, title } ] }'
