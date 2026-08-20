#!/usr/bin/env bash
# super-qa-file-bug.sh — file one Super QA finding as a GitHub issue on the
# Super Ultimate QA project board.
#
# The QA loop runs unattended, so this is the carved exception to "ask before
# `gh issue create`" — every issue it files carries the `source:qa` label so a
# human can triage the whole stream with `gh issue list -l source:qa`.
#
# The division of labour: the agent writes evidence, this script writes
# machinery. It prepends `## Board summary`, appends the hidden `super-qa-meta`
# block, derives a fingerprint when none is given, and refuses bodies that would
# leave a future headless session re-discovering the bug from scratch.
#
# Usage:
#   super-qa-file-bug.sh --title "<one-line>" --body-file <path.md> \
#     [--kind bug|feature|ux|tests|docs|tech-debt] \
#     [--priority high|medium|low] \
#     [--category functional|visual|network|console|i18n|a11y|data|testability] \
#     [--area <area>] [--route <route>] [--spec <path>] [--iter <n>] \
#     [--fingerprint "<slug>|<tc>|<signature>"] \
#     [--suggested-skill super-build|super-qa|super-ux|super-review]
#
# Project resolution (per super-qa/SKILL.md → "Project resolution"):
#   owner  $SUPER_QA_PROJECT_OWNER, else the current repo's owner
#   title  $SUPER_QA_PROJECT_TITLE, else "Super Ultimate QA"
# Never falls back to the repo's primary project — column semantics differ.
#
# Column: "Bug", override with $SUPER_QA_TARGET_OPTION_NAME.
# Body checks bypass: SUPER_QA_ALLOW_WEAK_BODY=1 (not during autonomous runs).
#
# Stdout: the issue number — new, or the existing one on a fingerprint hit.
# Exits:  0 ok · 64 bad args · 66 unreadable/weak body · 70 GH API failure
#         71 issue filed but board promote failed (number still on stdout)
set -uo pipefail

TITLE=""; BODY_FILE=""; KIND="bug"; PRIORITY="medium"; CATEGORY=""
AREA=""; ROUTE=""; SPEC=""; ITER=""; FINGERPRINT=""; SUGGESTED_SKILL=""

while [ $# -gt 0 ]; do
  case "$1" in
    --title)           TITLE="$2"; shift 2 ;;
    --body-file)       BODY_FILE="$2"; shift 2 ;;
    --kind)            KIND="$2"; shift 2 ;;
    --priority)        PRIORITY="$2"; shift 2 ;;
    --category)        CATEGORY="$2"; shift 2 ;;
    --area)            AREA="$2"; shift 2 ;;
    --route)           ROUTE="$2"; shift 2 ;;
    --spec)            SPEC="$2"; shift 2 ;;
    --iter)            ITER="$2"; shift 2 ;;
    --fingerprint)     FINGERPRINT="$2"; shift 2 ;;
    --suggested-skill) SUGGESTED_SKILL="$2"; shift 2 ;;
    *) echo "unknown arg: $1" >&2; exit 64 ;;
  esac
done

die() { echo "$1" >&2; exit "$2"; }

[ -n "$TITLE" ] || die "--title is required" 64
[ -n "$BODY_FILE" ] && [ -r "$BODY_FILE" ] || die "--body-file missing or unreadable: ${BODY_FILE:-<unset>}" 66

# Enum-check every controlled vocabulary. A typo becomes a label nobody filters
# on, and the finding silently drops out of triage.
case "$KIND" in bug|feature|ux|tests|docs|tech-debt) ;;
  *) die "--kind must be bug|feature|ux|tests|docs|tech-debt (got: $KIND)" 64 ;; esac
case "$PRIORITY" in high|medium|low) ;;
  *) die "--priority must be high|medium|low (got: $PRIORITY)" 64 ;; esac
if [ -n "$CATEGORY" ]; then
  case "$CATEGORY" in functional|visual|network|console|i18n|a11y|data|testability) ;;
    *) die "--category must be one of functional|visual|network|console|i18n|a11y|data|testability (got: $CATEGORY)" 64 ;; esac
fi
if [ -n "$SUGGESTED_SKILL" ]; then
  case "$SUGGESTED_SKILL" in super-build|super-qa|super-ux|super-review) ;;
    *) die "--suggested-skill must be super-build|super-qa|super-ux|super-review (got: $SUGGESTED_SKILL)" 64 ;; esac
fi

BODY_RAW=$(cat "$BODY_FILE")

# --- body guardrails --------------------------------------------------------
# A ticket that a future headless session cannot act on is worse than no ticket:
# it looks like tracked work while carrying none of the context. Reject early.
if [ "${SUPER_QA_ALLOW_WEAK_BODY:-0}" != "1" ]; then
  MISSING=""
  for section in "Summary" "Repro steps" "Expected behavior" "Actual behavior" \
                 "Evidence" "Suggested fix path" "Acceptance criteria"; do
    echo "$BODY_RAW" | grep -qiE "^#{1,3}[[:space:]]+${section}[[:space:]]*$" || MISSING="${MISSING}${MISSING:+, }${section}"
  done
  [ -z "$MISSING" ] || die "body is missing required section(s): ${MISSING}" 66

  # Placeholder sweep, outside fenced code (a HAR snippet legitimately contains
  # angle brackets; an unfilled `<one sentence: what is wrong>` does not).
  PROSE=$(echo "$BODY_RAW" | awk '/^```/{f=!f; next} !f' | sed 's/`[^`]*`//g')
  LEFTOVER=""
  echo "$PROSE" | grep -qE '(^|[^[:alnum:]])(TBD|TODO:)' && LEFTOVER="TBD/TODO:"
  # Template placeholders read like prose in angle brackets; real inline HTML is
  # a short known tag. Anything else with a space or a colon inside is a leftover.
  echo "$PROSE" | grep -qE '<[a-zA-Z][^>]*[[:space:]:][^>]*>' && LEFTOVER="${LEFTOVER}${LEFTOVER:+ and }<placeholder>"
  [ -z "$LEFTOVER" ] || die "body still contains unfilled placeholders (${LEFTOVER}) — fill them or set SUPER_QA_ALLOW_WEAK_BODY=1" 66
fi

# --- fingerprint ------------------------------------------------------------
# Deterministic by construction: the same finding on a later iteration must
# derive the same key, so iteration number is deliberately NOT an input.
if [ -z "$FINGERPRINT" ]; then
  FINGERPRINT="${KIND}|${ROUTE:-noroute}|${CATEGORY:-uncategorized}|$(echo "$TITLE" \
    | tr '[:upper:]' '[:lower:]' | sed -E 's/[^a-z0-9]+/-/g; s/^-|-$//g')"
fi

# --- project resolution -----------------------------------------------------
OWNER="${SUPER_QA_PROJECT_OWNER:-}"
if [ -z "$OWNER" ]; then
  OWNER=$(gh repo view --json owner -q .owner.login 2>/dev/null) \
    || die "cannot resolve project owner: set SUPER_QA_PROJECT_OWNER or run inside a repo" 70
fi
PROJECT_TITLE="${SUPER_QA_PROJECT_TITLE:-Super Ultimate QA}"
TARGET_COLUMN="${SUPER_QA_TARGET_OPTION_NAME:-Bug}"

PROJECT_LIST=$(gh project list --owner "$OWNER" --format json 2>/dev/null) \
  || die "cannot list projects for owner ${OWNER}" 70
NUMBER=$(echo "$PROJECT_LIST" | jq -r --arg t "$PROJECT_TITLE" \
  '[.projects[] | select((.title // "" | ascii_downcase) == ($t | ascii_downcase))] | first | .number // empty')
# Do NOT silently fall back to the repo's primary project — its columns mean
# different things, and QA cards would enter a lane that never expects them.
[ -n "$NUMBER" ] || die "no project titled '${PROJECT_TITLE}' under ${OWNER} — create one, or set SUPER_QA_PROJECT_TITLE" 70

# --- dedupe -----------------------------------------------------------------
EXISTING=$(gh issue list --label "source:qa" --state open --limit 200 \
  --json number,body \
  --jq "[.[] | select(.body != null and (.body | contains(\"${FINGERPRINT}\"))) | .number] | first // empty" 2>/dev/null || true)

if [ -n "$EXISTING" ]; then
  gh issue comment "$EXISTING" --body "Seen again${ITER:+ on iteration ${ITER}}.

${BODY_RAW}" >/dev/null 2>&1 || echo "warn: could not comment on existing #${EXISTING}" >&2
  echo "$EXISTING"
  exit 0
fi

# --- compose ----------------------------------------------------------------
case "$KIND" in
  bug) BADGE="🐛 Bug" ;; ux) BADGE="🎨 UX" ;; feature) BADGE="✨ Feature" ;;
  tests) BADGE="🧪 Tests" ;; docs) BADGE="📝 Docs" ;; tech-debt) BADGE="🧹 Tech debt" ;;
esac
FULL_TITLE="${BADGE}${ROUTE:+ ${ROUTE}} — ${TITLE}"

BODY_TMP=$(mktemp)
trap 'rm -f "$BODY_TMP"' EXIT
{
  # Board summary sits first so the project card is readable without opening it.
  echo "## Board summary"
  echo "**${PRIORITY}** ${KIND}${CATEGORY:+ (${CATEGORY})}${ROUTE:+ on \`${ROUTE}\`}${AREA:+ — area \`${AREA}\`} · owner \`${SUGGESTED_SKILL:-unassigned}\`"
  echo
  echo "$BODY_RAW"
  echo
  echo "<!-- super-qa-meta"
  echo "route: ${ROUTE:-none}"
  echo "spec: ${SPEC:-none}"
  echo "iteration: ${ITER:-none}"
  echo "area: ${AREA:-none}"
  echo "category: ${CATEGORY:-none}"
  echo "priority: ${PRIORITY}"
  echo "type: ${KIND}"
  echo "fingerprint: ${FINGERPRINT}"
  echo "-->"
} > "$BODY_TMP"

LABELS=("$KIND" "source:qa" "priority:${PRIORITY}")
if [ -n "$AREA" ]; then LABELS+=("area:${AREA}"); fi
if [ -n "$CATEGORY" ]; then LABELS+=("qa:${CATEGORY}"); fi
if [ -n "$SUGGESTED_SKILL" ]; then LABELS+=("skill:${SUGGESTED_SKILL}"); fi

# `gh issue create` hard-fails on an unknown label, which would lose the finding
# entirely. Create them best-effort first.
for l in "${LABELS[@]}"; do
  gh label create "$l" --color D93F0B --force >/dev/null 2>&1 || true
done
LABEL_ARGS=()
for l in "${LABELS[@]}"; do LABEL_ARGS+=(--label "$l"); done

ISSUE_URL=$(gh issue create --title "$FULL_TITLE" --body-file "$BODY_TMP" "${LABEL_ARGS[@]}") \
  || die "gh issue create failed" 70
ISSUE_N=$(basename "$ISSUE_URL")

# --- promote onto the board -------------------------------------------------
# Past this point the issue exists, so the number goes to stdout no matter what:
# exit 71 tells the caller "filed, needs a manual move" rather than losing it.
promote() {
  local item_id project_id field_json field_id option_id
  item_id=$(gh project item-add "$NUMBER" --owner "$OWNER" --url "$ISSUE_URL" --format json --jq '.id') || return 1
  project_id=$(gh project view "$NUMBER" --owner "$OWNER" --format json --jq '.id') || return 1
  field_json=$(gh project field-list "$NUMBER" --owner "$OWNER" --format json) || return 1
  field_id=$(echo "$field_json" | jq -r '.fields[] | select(.name=="Status") | .id')
  option_id=$(echo "$field_json" | jq -r --arg c "$TARGET_COLUMN" \
    '.fields[] | select(.name=="Status") | .options[]? | select(.name==$c) | .id')
  [ -n "$option_id" ] && [ "$option_id" != "null" ] || { echo "warn: no '${TARGET_COLUMN}' option on the Status field" >&2; return 1; }
  gh project item-edit --id "$item_id" --project-id "$project_id" \
    --field-id "$field_id" --single-select-option-id "$option_id" >/dev/null || return 1
}

if promote; then
  echo "$ISSUE_N"
else
  echo "warn: #${ISSUE_N} filed but not moved to '${TARGET_COLUMN}' on ${OWNER}/${NUMBER} — manual move required" >&2
  echo "$ISSUE_N"
  exit 71
fi
