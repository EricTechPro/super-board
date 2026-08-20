#!/usr/bin/env bash
# super-review-file-refactor.sh — file a deepening opportunity spotted during review.
#
# Super Review's gate is merge-or-bounce. A shallow module in an otherwise-correct
# diff is a future ticket, not a reason to hold a green PR — so this script files
# the card and gets out of the way. It NEVER fails the review: every failure below
# the issue-create call degrades to a warning on stderr, because a board-placement
# hiccup must not strand a mergeable PR in Review.
#
# Cards land in Backlog, not Ready. A refactor the reviewer noticed has had no human
# eyes on it and no acceptance criteria; auto-promoting it to Ready would feed the
# build lane work nobody asked for. It waits for `super-board lint` like any other
# unrefined ticket.
#
# Usage:
#   super-review-file-refactor.sh --config <config.json> \
#     --title "<one-line shape problem>" \
#     --body-file <path.md> \
#     --fingerprint "<module>|<shape-problem>" \
#     [--files "src/a.ts,src/b.ts"] [--strength strong|worth-exploring|speculative] \
#     [--area <area>] [--pr <number>] [--column <name>]
#
# Stdout: the issue number (new, or the existing one on a fingerprint hit).
set -euo pipefail

CONFIG=""; TITLE=""; BODY_FILE=""; FINGERPRINT=""
FILES=""; STRENGTH="worth-exploring"; AREA=""; PR=""; COLUMN="Backlog"

while [ $# -gt 0 ]; do
  case "$1" in
    --config)      CONFIG="$2"; shift 2 ;;
    --title)       TITLE="$2"; shift 2 ;;
    --body-file)   BODY_FILE="$2"; shift 2 ;;
    --fingerprint) FINGERPRINT="$2"; shift 2 ;;
    --files)       FILES="$2"; shift 2 ;;
    --strength)    STRENGTH="$2"; shift 2 ;;
    --area)        AREA="$2"; shift 2 ;;
    --pr)          PR="$2"; shift 2 ;;
    --column)      COLUMN="$2"; shift 2 ;;
    *) echo "unknown arg: $1" >&2; exit 64 ;;
  esac
done

[ -n "$CONFIG" ] && [ -e "$CONFIG" ] || { echo "config not found: ${CONFIG:-<unset>}" >&2; exit 66; }
[ -n "$TITLE" ]       || { echo "--title is required" >&2; exit 64; }
[ -n "$FINGERPRINT" ] || { echo "--fingerprint is required (dedupe key)" >&2; exit 64; }
[ -n "$BODY_FILE" ] && [ -r "$BODY_FILE" ] || { echo "--body-file missing or unreadable: ${BODY_FILE:-<unset>}" >&2; exit 66; }

# Enum-check loudly. A typo here becomes a label nobody filters on, and the card
# quietly never surfaces in an architecture sweep.
case "$STRENGTH" in
  strong|worth-exploring|speculative) ;;
  *) echo "--strength must be strong|worth-exploring|speculative (got: $STRENGTH)" >&2; exit 64 ;;
esac

CONFIG_JSON=$(cat "$CONFIG")
OWNER=$(echo "$CONFIG_JSON" | jq -r '.project.owner')
NUMBER=$(echo "$CONFIG_JSON" | jq -r '.project.number')
REPO=$(echo "$CONFIG_JSON" | jq -r '.repo.remote // empty')

# `gh issue` needs an -R when the CWD is a worktree of a different remote; the
# reviewer always runs from one, so resolve it rather than trusting the CWD.
if [ -n "$REPO" ]; then
  REPO_FLAG=(-R "$(echo "$REPO" | sed -E 's#(git@github\.com:|https://github\.com/)##; s#\.git$##')")
else
  REPO_FLAG=()
fi

# --- dedupe -----------------------------------------------------------------
# The fingerprint is stamped into the body as an HTML comment so it survives
# edits to the prose and stays invisible on the rendered issue.
STAMP="<!-- super-review-fingerprint: ${FINGERPRINT} -->"
EXISTING=$(gh issue list "${REPO_FLAG[@]}" \
  --label "source:review" --state open --limit 200 \
  --json number,body \
  --jq "[.[] | select(.body != null and (.body | contains(\"${FINGERPRINT}\"))) | .number] | first // empty" 2>/dev/null || true)

if [ -n "$EXISTING" ]; then
  # Same shape problem, seen again on a later PR. Add the sighting, don't stack cards.
  gh issue comment "$EXISTING" "${REPO_FLAG[@]}" \
    --body "Seen again during review${PR:+ of #${PR}}.

$(cat "$BODY_FILE")" >/dev/null 2>&1 \
    || echo "warn: could not comment on existing #${EXISTING}" >&2
  echo "$EXISTING"
  exit 0
fi

# --- create -----------------------------------------------------------------
BODY_TMP=$(mktemp)
trap 'rm -f "$BODY_TMP"' EXIT
{
  cat "$BODY_FILE"
  echo
  echo "---"
  echo
  if [ -n "$FILES" ]; then
    echo "**Files:** $(echo "$FILES" | tr ',' '\n' | sed 's/^/`/; s/$/`/' | paste -sd ', ' -)"
  fi
  if [ -n "$PR" ]; then echo "**Spotted reviewing:** #${PR}"; fi
  echo "**Recommendation strength:** ${STRENGTH}"
  echo
  echo "_Filed by Super Review. Not a merge blocker — the PR that surfaced this merged._"
  echo "_Run \`improve-codebase-architecture\` against this card to design the fix._"
  echo
  echo "$STAMP"
} > "$BODY_TMP"

LABELS=("refactor" "source:review" "strength:${STRENGTH}")
if [ -n "$AREA" ]; then LABELS+=("area:${AREA}"); fi

# Labels may not exist yet on a fresh repo. Create them best-effort; `gh issue
# create` hard-fails on an unknown label, which would lose the finding entirely.
for l in "${LABELS[@]}"; do
  gh label create "$l" "${REPO_FLAG[@]}" --color BFD4F2 --force >/dev/null 2>&1 || true
done

LABEL_ARGS=()
for l in "${LABELS[@]}"; do LABEL_ARGS+=(--label "$l"); done

ISSUE_URL=$(gh issue create "${REPO_FLAG[@]}" \
  --title "🏗 Refactor — ${TITLE}" \
  --body-file "$BODY_TMP" \
  "${LABEL_ARGS[@]}")

ISSUE_N=$(basename "$ISSUE_URL")

# --- place on the board -----------------------------------------------------
# Backlog is deliberately NOT in the config's managed `columns` list, so it may
# not exist as a Status option. Add the card either way and only then try to set
# Status; a board with no Backlog column leaves it status-less, which is visible
# in the UI and harmless. Never exit non-zero from here down.
place_card() {
  local item_id project_id field_json field_id option_id
  item_id=$(gh project item-add "$NUMBER" --owner "$OWNER" --url "$ISSUE_URL" --format json --jq '.id') || return 1
  project_id=$(gh project view "$NUMBER" --owner "$OWNER" --format json --jq '.id') || return 1
  field_json=$(gh project field-list "$NUMBER" --owner "$OWNER" --format json) || return 1
  field_id=$(echo "$field_json" | jq -r '.fields[] | select(.name=="Status") | .id')
  option_id=$(echo "$field_json" | jq -r --arg c "$COLUMN" \
    '.fields[] | select(.name=="Status") | .options[]? | select(.name==$c) | .id')

  if [ -n "$option_id" ] && [ "$option_id" != "null" ]; then
    gh project item-edit --id "$item_id" --project-id "$project_id" \
      --field-id "$field_id" --single-select-option-id "$option_id" >/dev/null || return 1
  else
    echo "warn: no '${COLUMN}' option on the Status field — #${ISSUE_N} added to the board without a status" >&2
  fi
}

place_card || echo "warn: filed #${ISSUE_N} but could not place it on project ${OWNER}/${NUMBER}" >&2

echo "$ISSUE_N"
