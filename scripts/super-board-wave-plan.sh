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
# Usage:
#   super-board-wave-plan.sh --config <config.json> [--items <project-items.json>]
#                            [--deps <deps.json>]
# Without --items, fetches live board state via `gh project item-list`.
# Without --deps, derives the graph via super-board-deps.sh. Pass --deps in tests
# to keep the script offline.
#
# Stdout:
#   { "cards": [ {"number":10,"status":"Review","title":"…"} ],
#     "sweep": [ {"number":37,"title":"…","clearedBy":[32]} ],
#     "flag":  [ {"number":82,"title":"…","why":"…"} ] }
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
VARIANT=$(echo "$CONFIG_JSON" | jq -r '.variant')
# 0 or absent = unlimited. A wave is sized by the dependency graph, not a knob.
MAX_WORKERS=$(echo "$CONFIG_JSON" | jq -r '.max_workers // 0')
OWNER=$(echo "$CONFIG_JSON" | jq -r '.project.owner')
NUMBER=$(echo "$CONFIG_JSON" | jq -r '.project.number')

if [ -n "$ITEMS_FILE" ]; then
  ITEMS=$(cat "$ITEMS_FILE")
else
  ITEMS=$(gh project item-list "$NUMBER" --owner "$OWNER" --format json --limit 500)
fi

# Validate loudly: a typo (or missing key → literal "null") must not silently
# drop the QA column from selection and strand cards there.
case "$VARIANT" in
  full)    COLUMNS='["Review","QA","Ready"]' ;;
  qa-only) COLUMNS='["Review","Ready"]' ;;
  *) echo "invalid variant in config: ${VARIANT} (expected full|qa-only)" >&2; exit 65 ;;
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
  # Unknown to the graph (closed, or beyond the fetch limit) is not "free".
  def free($n): (dep($n) | if . == null then false else .runnable end);

  [ .items[]
    | select(.content.type == "Issue")
    | select((.content.assignees // []) | length == 0)
    | { number: .content.number, status: .status, title: .content.title } ] as $all

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

      # Cards the graph could not read. Left where they are, reported so the
      # orchestrator can ask for the line to be fixed.
      flag:  [ $all[]
               | select(.status as $s | ["Ready","Blocked"] | index($s))
               | select(dep(.number) != null and (dep(.number).parseable | not))
               | { number, title, why: (dep(.number) | .why) } ] }'
