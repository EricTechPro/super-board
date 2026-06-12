#!/usr/bin/env bash
# super-board-wave-plan.sh — compute the next workflow-backend wave from board state.
# Read-only: no gh writes, no locks. Mirrors run.md's lane-allocation model:
# base picks are one card per non-empty eligible column, downstream-first
# (Review → QA → Ready); remaining max_workers slots fill with extra cards
# from the most backlogged column first. Cards with assignees are skipped
# (assignee is the cross-machine mutex, claimed by the orchestrator before
# launch). Extra Review cards beyond the base pick are gated behind
# config.human_approves_merge (merge-race guard).
#
# Usage:
#   super-board-wave-plan.sh --config <config.json> [--items <project-items.json>]
# Without --items, fetches live board state via `gh project item-list`.
# Stdout: {"cards":[{"number":10,"status":"Review","title":"..."}]}
set -euo pipefail

CONFIG=""; ITEMS_FILE=""
while [ $# -gt 0 ]; do
  case "$1" in
    --config) CONFIG="$2"; shift 2 ;;
    --items)  ITEMS_FILE="$2"; shift 2 ;;
    *) echo "unknown arg: $1" >&2; exit 64 ;;
  esac
done
[ -n "$CONFIG" ] && [ -e "$CONFIG" ] || { echo "config not found: ${CONFIG:-<unset>}" >&2; exit 66; }

# Read the config ONCE — $CONFIG may be a process substitution (test mode),
# which is a FIFO and cannot be read twice.
CONFIG_JSON=$(cat "$CONFIG")
VARIANT=$(echo "$CONFIG_JSON" | jq -r '.variant')
MAX_WORKERS=$(echo "$CONFIG_JSON" | jq -r '.max_workers // 3')
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

# Merge-race guard: concurrent auto-merges into the same base branch can
# race, so extra Review cards (beyond the base 1) are only eligible when a
# human approves merges (config.human_approves_merge = true).
ALLOW_REVIEW_EXTRAS=$(echo "$CONFIG_JSON" | jq -r '.human_approves_merge // false')

echo "$ITEMS" | jq --argjson cols "$COLUMNS" --argjson cap "$MAX_WORKERS" --argjson revx "$ALLOW_REVIEW_EXTRAS" '
  [ $cols[] as $col
    | { col: $col,
        cands: [ .items[]
                 | select(.status == $col and .content.type == "Issue")
                 | select((.content.assignees // []) | length == 0)
                 | { number: .content.number, status: $col, title: .content.title } ] }
  ] as $bycol
  | [ $bycol[] | select((.cands | length) > 0) | .cands[0] ] as $base
  | ( [ $bycol[]
        | select(.col != "Review" or $revx)
        | { backlog: ((.cands | length) - 1), rest: .cands[1:] }
        | select(.backlog > 0)
      ]
      | sort_by(-.backlog)
      | map(.rest)
      | add // []
    ) as $extras
  | { cards: (($base + $extras) | .[:$cap]) }'
