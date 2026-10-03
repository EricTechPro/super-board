#!/usr/bin/env bash
# super-review-file-refactor.sh — file a deepening opportunity spotted during review.
#
# Super Review's gate is merge-or-bounce. A shallow module in an otherwise-correct
# diff is a future ticket, not a reason to hold a green PR — so this script files
# the card and gets out of the way. Missing optional column configuration is a
# warning; unavailable required evidence or an unknown write outcome pauses the
# run (79) while preserving any issue already created. No mutation is retried.
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
FILES=""; STRENGTH="worth-exploring"; AREA=""; PR=""; COLUMN=""

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

# Ticket format: writing-standard.md § 3. The Reviewer writes Problem, Context and
# Fix; Acceptance Criteria, Risk and Blocked by are appended below when absent.
MISSING=""
for s in "Problem" "Context" "Fix"; do
  grep -qiE "^#{1,3}[[:space:]]+${s}[[:space:]]*$" "$BODY_FILE" || MISSING="${MISSING}${MISSING:+, }${s}"
done
[ -z "$MISSING" ] || { echo "body is missing required section(s): ${MISSING} (writing-standard.md § 3)" >&2; exit 66; }

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

GITHUB_READ="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/super-board-github-read.py"
python3 "$GITHUB_READ" --check || exit $?

# --- dedupe -----------------------------------------------------------------
# The fingerprint is stamped into the body as an HTML comment so it survives
# edits to the prose and stays invisible on the rendered issue.
STAMP="<!-- super-review-fingerprint: ${FINGERPRINT} -->"
ISSUES_JSON=$(python3 "$GITHUB_READ" --kind dedupe -- issue list "${REPO_FLAG[@]}" --label "source:review" --state open --limit 200 --json number,body) || exit $?
EXISTING=$(printf '%s' "$ISSUES_JSON" | jq -r --arg fingerprint "$FINGERPRINT" '[.[] | select(.body | contains($fingerprint)) | .number] | first // empty')

if [ -n "$EXISTING" ]; then
  # Same shape problem, seen again on a later PR. Add the sighting, don't stack cards.
  python3 "$GITHUB_READ" --check || exit $?
  gh issue comment "$EXISTING" "${REPO_FLAG[@]}" \
    --body "Seen again during review${PR:+ of #${PR}}.

$(cat "$BODY_FILE")" >/dev/null 2>&1 \
    || { python3 "$GITHUB_READ" --halt "Comment outcome unknown for #${EXISTING}; inspect before retrying"; exit 79; }
  echo "$EXISTING"
  exit 0
fi

# Where the card lands, and it is decided by the card, not by a default.
#
# A card with real acceptance criteria is buildable, so it goes to `Ready` and the
# next wave takes it. A card without them is a note, and `Ready` feeds the Builder
# lane directly — so it goes to the holding column and waits for `super-board
# lint` like any other unrefined ticket.
#
# This used to be an unconditional `Backlog`, which was wrong twice over: it fed
# nothing to the loop even when the card was ready, and on a board with no
# `Backlog` column it produced cards with no Status at all.
if [ -z "$COLUMN" ]; then
  if grep -qiE '^## +Acceptance criteria *$' "$BODY_FILE"; then COLUMN="Ready"; else COLUMN="Backlog"; fi
fi

# --- create -----------------------------------------------------------------
BODY_TMP=$(mktemp)
trap 'rm -f "$BODY_TMP"' EXIT
{
  cat "$BODY_FILE"

  # Every card the loop can pick up needs these two sections, and a card filed
  # mid-wave by an agent is the one most likely to arrive without them. Six were
  # filed that way on 2026-08-21 and every one had to be completed by hand before
  # it could move: a missing `## Blocked by` is not the same as `- None.`, so the
  # wave planner correctly refuses to guess and the card sits in Todo forever.
  #
  # Appended only when absent, so a caller that wrote its own keeps it.
  if ! grep -qiE '^## +Acceptance criteria *$' "$BODY_FILE"; then
    echo
    echo "## Acceptance Criteria"
    echo
    echo "- [ ] _Not written by the Reviewer that filed this. Run \`super-board lint\` on this card"
    echo "      before it is built — a card graded against criteria nobody wrote is graded against"
    echo "      nothing._"
  fi
  if ! grep -qiE '^## +Risk *$' "$BODY_FILE"; then
    echo
    echo "## Risk"
    echo
    echo "🟡 **Medium** · not assessed by the Reviewer that filed this; lint sets it."
  fi
  if ! grep -qiE '^## +Blocked by *$' "$BODY_FILE"; then
    echo
    echo "## Blocked by"
    echo
    echo "- None."
    echo
    echo "> Filed mid-review with nothing blocking it. Stated explicitly rather than left silent:"
    echo "> the wave planner treats a missing section as unreadable, not as None."
  fi

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
  python3 "$GITHUB_READ" --check || exit $?
  gh label create "$l" "${REPO_FLAG[@]}" --color BFD4F2 --force >/dev/null 2>&1 || true
done

LABEL_ARGS=()
for l in "${LABELS[@]}"; do LABEL_ARGS+=(--label "$l"); done

# Title: `♻️ [refactor] <scope>: <title>`; scope = --area, else the fingerprint's module.
SCOPE="${AREA:-${FINGERPRINT%%|*}}"
SCOPE=$(echo "${SCOPE:-code}" | tr '[:upper:]' '[:lower:]' | sed -E 's#[^a-z0-9._/-]+#-#g; s#^-+|-+$##g')
python3 "$GITHUB_READ" --check || exit $?
ISSUE_URL=$(gh issue create "${REPO_FLAG[@]}" \
  --title "♻️ [refactor] ${SCOPE:-code}: ${TITLE}" \
  --body-file "$BODY_TMP" \
  "${LABEL_ARGS[@]}") || { python3 "$GITHUB_READ" --halt "Issue creation response failed; reconcile fingerprint ${FINGERPRINT} before retrying"; exit 79; }

ISSUE_N=$(basename "$ISSUE_URL")

# --- place on the board -----------------------------------------------------
# The holding column is deliberately NOT in the config's managed `columns` list,
# so the board may name it something else. Add the card either way and only then
# try to set Status. Exit 71 means filed but placement failed; 79 is a paused run.
#
# A CARD WITH NO STATUS IS NOT HARMLESS, which the first version of this comment
# claimed. Observed on a real board on 2026-08-20: the board's holding column was
# called `Todo`, this script asked for `Backlog`, and every card it filed landed
# with no Status at all. On a Kanban view that is not "visible" — it is in a
# No Status group nobody opens, which is strictly worse than the wrong column.
# So: try the requested name, then the known aliases, and only give up after all
# of them miss.
place_card() {
  local item_id project_id field_json field_id option_id candidate
  local -a candidates
  python3 "$GITHUB_READ" --check || return $?
  item_id=$(gh project item-add "$NUMBER" --owner "$OWNER" --url "$ISSUE_URL" --format json --jq '.id') || { python3 "$GITHUB_READ" --halt "Project item add outcome unknown for issue #${ISSUE_N}; reconcile before retrying"; return 79; }
  project_id=$(python3 "$GITHUB_READ" --kind scalar -- project view "$NUMBER" --owner "$OWNER" --format json --jq '.id') || return $?
  field_json=$(python3 "$GITHUB_READ" --kind fields -- project field-list "$NUMBER" --owner "$OWNER" --format json) || return $?
  field_id=$(echo "$field_json" | jq -r '.fields[] | select(.name=="Status") | .id')
  # The requested name first, then the conventional aliases for "not started".
  # Ordered by intent: a holding column beats Ready, because a card filed by a
  # reviewer has no acceptance criteria and Ready feeds the build lane directly.
  # The fallback chain runs DOWNWARD in commitment, never upward. A request for
  # the holding column degrades to another holding column; it must never degrade
  # into `Ready`, because `Ready` feeds the Builder lane and the whole reason a
  # card was sent to a holding column is that nobody has written its criteria yet.
  # (Briefly it did degrade upward, and a note-quality card would have been built
  # on a board that happens to have no Backlog column — which is this repo's.)
  if [ "$COLUMN" = "Ready" ]; then
    candidates=("Ready" "Backlog" "Todo" "To do" "Triage" "Inbox")
  else
    candidates=("$COLUMN" "Backlog" "Todo" "To do" "Triage" "Inbox")
  fi
  for candidate in "${candidates[@]}"; do
    option_id=$(echo "$field_json" | jq -r --arg c "$candidate" \
      '.fields[] | select(.name=="Status") | .options[]? | select(.name==$c) | .id')
    if [ -n "$option_id" ] && [ "$option_id" != "null" ]; then
      [ "$candidate" = "$COLUMN" ] || \
        echo "note: no '${COLUMN}' column on this board — filed #${ISSUE_N} into '${candidate}'" >&2
      break
    fi
  done

  if [ -n "$option_id" ] && [ "$option_id" != "null" ]; then
    python3 "$GITHUB_READ" --check || return $?
    gh project item-edit --id "$item_id" --project-id "$project_id" \
      --field-id "$field_id" --single-select-option-id "$option_id" >/dev/null || { python3 "$GITHUB_READ" --halt "Project column move outcome unknown for issue #${ISSUE_N}; reconcile before retrying"; return 79; }
  else
    echo "warn: this board has no '${COLUMN}' column and none of the usual aliases" >&2
    echo "warn: (Backlog, Todo, To do, Triage, Inbox) — #${ISSUE_N} is on the board with NO status," >&2
    echo "warn: which means it will not appear in any column. Add a holding column or pass --column." >&2
  fi
}

if ! place_card; then
  echo "$ISSUE_N"
  python3 "$GITHUB_READ" --check || exit 79
  echo "warn: filed #${ISSUE_N} but could not place it on project ${OWNER}/${NUMBER}; inspect before retrying" >&2
  exit 71
fi

echo "$ISSUE_N"
