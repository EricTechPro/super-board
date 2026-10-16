#!/usr/bin/env bash
# super-collect-file.sh — file one collected item onto the super-board project,
# into the holding column only. Dry-run unless --yes.
#
# This is a router, not a third filer. Bugs, features and recurring-problem fixes go
# through super-qa-file-bug.sh; refactors through super-review-file-refactor.sh.
# What it adds on top of them:
#   1. a repo-wide fingerprint dedupe (theirs only see their own source label),
#   2. holding-column resolution BEFORE dispatch — both filers fall back toward
#      Ready when the requested column is missing, and super-collect must never
#      put a card in Ready. No holding column → refuse (exit 65).
#   3. `--adopt N` for a user-filed issue that is not on the board yet: place the
#      existing issue instead of filing a copy of it.
#   4. one fingerprint shape per source, so the same problem keys the same way on
#      every run: sentry `err|sentry|<issue-id>`, posthog `posthog|<signal>|<key>`
#      (tracking gaps: `gap|<workflow>`),
#      github `github|<issue#>`, prs `prs|<boundary>|<cause>`,
#      architecture `arch|<module>|<problem>`.
#
# Usage:
#   super-collect-file.sh --config <cfg.json> --type bug|feature|refactor|fix \
#     --source sentry|posthog|github|prs|architecture|custom --title "<one line>" --body-file <md> \
#     --fingerprint "<stable key>" [--priority high|medium|low] [--area <a>] \
#     [--label <l>]... [--yes]          # e.g. --label needs-triage --label ux
#   super-collect-file.sh --config <cfg.json> --adopt <issue#> --type bug|feature|refactor [--yes]
#
# Stdout: dry-run → one `would-file|duplicate|recurrence|would-adopt` plan line;
#         --yes   → the issue number (new, existing on a dedupe hit, or adopted).
# Exits:  0 ok · 64 bad args · 65 no holding column · 66 unreadable/weak body
#         70 gh failure · 71 filed but not placed (number still on stdout)
#         79 repository paused (existing issue number still on stdout after discovery)
set -uo pipefail

ORIGINAL_ARGS=("$@")
CONFIG=""; TYPE=""; SOURCE=""; TITLE=""; BODY_FILE=""; FP=""
PRIORITY="medium"; AREA=""; ADOPT=""; YES=0; EXTRA_LABELS=()

while [ $# -gt 0 ]; do
  case "$1" in
    --config)      CONFIG="$2"; shift 2 ;;
    --type)        TYPE="$2"; shift 2 ;;
    --source)      SOURCE="$2"; shift 2 ;;
    --title)       TITLE="$2"; shift 2 ;;
    --body-file)   BODY_FILE="$2"; shift 2 ;;
    --fingerprint) FP="$2"; shift 2 ;;
    --priority)    PRIORITY="$2"; shift 2 ;;
    --area)        AREA="$2"; shift 2 ;;
    --adopt)       ADOPT="$2"; shift 2 ;;
    --label)       EXTRA_LABELS+=("$2"); shift 2 ;;
    --yes)         YES=1; shift ;;
    *) echo "unknown arg: $1" >&2; exit 64 ;;
  esac
done

die() { echo "$1" >&2; exit "$2"; }

[ -n "$CONFIG" ] && [ -r "$CONFIG" ] || die "config not found: ${CONFIG:-<unset>}" 66
case "$TYPE" in bug|feature|refactor|fix) ;; *) die "--type must be bug|feature|refactor|fix (got: ${TYPE:-<unset>})" 64 ;; esac
case "$PRIORITY" in high|medium|low) ;; *) die "--priority must be high|medium|low (got: $PRIORITY)" 64 ;; esac

if [ -z "$ADOPT" ]; then
  case "$SOURCE" in
    sentry) FP_PREFIX="err|sentry|" ;; posthog) FP_PREFIX="posthog|" ;; github) FP_PREFIX="github|" ;;
    prs) FP_PREFIX="prs|" ;; architecture) FP_PREFIX="arch|" ;;
    custom) FP_PREFIX="custom|" ;;   # onboard's "➕ Add another source": custom|<name>|<key>
    *) die "--source must be sentry|posthog|github|prs|architecture|custom (got: ${SOURCE:-<unset>})" 64 ;;
  esac
  [ -n "$TITLE" ] || die "--title is required" 64
  [ -n "$FP" ]    || die "--fingerprint is required (dedupe key)" 64
  case "$FP" in *[[:space:]]*) die "--fingerprint must be one token without whitespace" 64;; esac
  case "$FP" in *'"'*|*'\\'*) die "--fingerprint may not contain quotes or backslashes" 64 ;; esac
  case "$SOURCE|$FP" in "posthog|gap|"?*) FP_PREFIX="gap|" ;; esac
  case "$FP" in "$FP_PREFIX"?*) ;; *) die "--fingerprint for source ${SOURCE} must start with '${FP_PREFIX}' (got: $FP)" 64 ;; esac
  [ -n "$BODY_FILE" ] && [ -r "$BODY_FILE" ] || die "--body-file missing or unreadable: ${BODY_FILE:-<unset>}" 66
else
  case "$ADOPT" in *[!0-9]*|"") die "--adopt takes an issue number (got: $ADOPT)" 64 ;; esac
  [ "$TYPE" != "fix" ] || die "--adopt takes bug|feature|refactor" 64
fi

OWNER=$(jq -r '.project.owner // empty' "$CONFIG")
NUMBER=$(jq -r '.project.number // empty' "$CONFIG")
PTITLE=$(jq -r '.project.title // empty' "$CONFIG")
REMOTE=$(jq -r '.repo.remote // empty' "$CONFIG")
[ -n "$OWNER" ] && [ -n "$NUMBER" ] || die "config lacks project.owner / project.number" 66
REPO_FLAG=()
[ -z "$REMOTE" ] || REPO_FLAG=(-R "$(echo "$REMOTE" | sed -E 's#(git@github\.com:|https://github\.com/)##; s#\.git$##')")

BIN="${SUPER_BOARD_BIN:-}"
if [ -z "$BIN" ]; then
  # Installed: .claude/skills/super-collect/scripts → .claude/bin. Pack: skills/… → scripts/.
  ROOT3=$(cd "$(dirname "$0")/../../.." 2>/dev/null && pwd)
  for d in ".claude/bin" "$ROOT3/bin" "$ROOT3/scripts"; do
    [ -x "$d/super-qa-file-bug.sh" ] && { BIN="$d"; break; }
  done
fi
[ -n "$BIN" ] || die "cannot find super-qa-file-bug.sh — set SUPER_BOARD_BIN or run install.sh" 70

# Router-owned duplicate/adopt writes share the same halt as the child filers.
GITHUB_READ="$BIN/super-board-github-read.py"
GITEA_READ="$BIN/super-board-gitea-read.py"
FORGE_KIND=github
if [ -f "$BIN/super-board-forge.sh" ]; then
  # shellcheck source=/dev/null
  . "$BIN/super-board-forge.sh"
  sb_forge_resolve "$CONFIG" || exit $?
  FORGE_KIND="$SB_FORGE_KIND"
fi
if [ "$FORGE_KIND" = gitea ]; then
  READ_PY="$GITEA_READ"
  # shellcheck source=/dev/null
  . "$BIN/super-board-gitea-api.sh"
else
  READ_PY="$GITHUB_READ"
fi
python3 "$READ_PY" --check || exit $?
if [ "$FORGE_KIND" = gitea ]; then
  REPO_NAME="$SB_FORGE_OWNER/$SB_FORGE_REPO"
else
  REPO_NAME="${REPO_FLAG[1]:-}"
  if [ -z "$REPO_NAME" ]; then
    REPO_NAME=$(python3 "$GITHUB_READ" --kind scalar -- repo view --json nameWithOwner --jq .nameWithOwner) || exit $?
  fi
fi
case "$REPO_NAME" in */*) ;; *) die "cannot resolve owner/name for collector" 70;; esac
STATE="$BIN/super-board-collect-state.py"
LOCK_KEY=$(printf '%s' "$REPO_NAME" | python3 -c 'import hashlib,sys; print(hashlib.sha256(sys.stdin.read().lower().encode()).hexdigest())')
if [ "${SB_COLLECT_LOCK_HELD:-}" != "$LOCK_KEY" ]; then
  exec python3 "$STATE" --repo "$REPO_NAME" --lock -- "$0" "${ORIGINAL_ARGS[@]}"
fi
state() { python3 "$STATE" --repo "$REPO_NAME" --action "$1" --fingerprint "${FP:-adopt|$ADOPT}" --digest "${DIGEST:-}" --issue "${2:-}"; }
DIGEST=""
if [ -n "$BODY_FILE" ]; then
  DIGEST=$(python3 -c 'import hashlib,sys; print(hashlib.sha256((sys.argv[1]+"\0").encode()+open(sys.argv[2],"rb").read()).hexdigest())' "$SOURCE" "$BODY_FILE") || exit 70
fi

# --- body sections ----------------------------------------------------------
# The ticket format is writing-standard.md § 3. super-qa-file-bug.sh enforces the
# full bug shape (lettered steps, the 12-row Evidence table). Features and
# recurring-problem fixes are not repro-shaped, so they get their own minimum here
# and the QA filer's repro check is bypassed for them. Refactors: the review filer.
need_sections() {
  local missing="" s
  for s in "$@"; do
    grep -qiE "^#{1,3}[[:space:]]+${s}[[:space:]]*$" "$BODY_FILE" || missing="${missing}${missing:+, }${s}"
  done
  [ -z "$missing" ] || die "body is missing required section(s): ${missing} (writing-standard.md § 3)" 66
}
need_checklist() {
  awk '/^#+[[:space:]]+/ { h = tolower($0); on = (h ~ /^#+[[:space:]]+acceptance criteria[[:space:]]*$/); next }
       on && /^[[:space:]]*- \[[ xX]\] / { found = 1 } END { exit !found }' "$BODY_FILE" \
    || die "Acceptance Criteria needs a checklist: one '- [ ] <checkable outcome>' per line" 66
}
if [ -z "$ADOPT" ]; then
  case "$TYPE" in
    bug) "$BIN/super-qa-file-bug.sh" --title "$TITLE" --body-file "$BODY_FILE" --check-body || exit $? ;;
    feature)  need_sections "Problem" "Context" "Fix" "Acceptance Criteria" "Risk"; need_checklist ;;
    fix)      need_sections "Problem" "Context" "Evidence" "Fix" "Acceptance Criteria" "Risk"; need_checklist ;;
    refactor) need_sections "Problem" "Context" "Fix" ;;
  esac
fi

# --- holding column ---------------------------------------------------------
if [ "$FORGE_KIND" = gitea ]; then
  FIELDS=$(python3 "$GITEA_READ" --kind fields --fields "$REPO_NAME/$NUMBER") || exit $?
else
  FIELDS=$(python3 "$GITHUB_READ" --kind fields -- project field-list "$NUMBER" --owner "$OWNER" --format json) || exit $?
fi
HOLD=""
for c in Backlog Todo "To do" Triage Inbox; do
  hit=$(echo "$FIELDS" | jq -r --arg c "$c" '.fields[] | select(.name=="Status") | .options[]? | select(.name==$c) | .name' | head -1)
  if [ -n "$hit" ]; then HOLD="$hit"; break; fi
done
[ -n "$HOLD" ] || die "project ${OWNER}/${NUMBER} has no holding column (Backlog, Todo, To do, Triage, Inbox) — refusing: the filers would fall back to Ready" 65

place() { # $1 = issue url (github) — gitea uses place_gitea with the global id
  local item_id project_id field_id option_id
  python3 "$GITHUB_READ" --check || return $?
  item_id=$(gh project item-add "$NUMBER" --owner "$OWNER" --url "$1" --format json --jq '.id') || return 1
  python3 "$GITHUB_READ" --check || return $?
  project_id=$(gh project view "$NUMBER" --owner "$OWNER" --format json --jq '.id') || return 1
  field_id=$(echo "$FIELDS" | jq -r '.fields[] | select(.name=="Status") | .id')
  option_id=$(echo "$FIELDS" | jq -r --arg c "$HOLD" '.fields[] | select(.name=="Status") | .options[] | select(.name==$c) | .id')
  python3 "$GITHUB_READ" --check || return $?
  gh project item-edit --id "$item_id" --project-id "$project_id" \
    --field-id "$field_id" --single-select-option-id "$option_id" >/dev/null
}

place_gitea() { # $1 = issue global id — one add-to-column call places the card
  local option_id
  python3 "$READ_PY" --check || return $?
  option_id=$(echo "$FIELDS" | jq -r --arg c "$HOLD" '.fields[] | select(.name=="Status") | .options[] | select(.name==$c) | .id')
  [ -n "$option_id" ] && [ "$option_id" != "null" ] || return 1
  sb_gitea_api POST "repos/$REPO_NAME/projects/$NUMBER/columns/$option_id/issues/$1" >/dev/null
}

tag() { # $1 = issue number, rest = labels; best-effort
  local n="$1"; shift
  if [ "$FORGE_KIND" = gitea ]; then
    local l lid
    for l in "$@"; do
      python3 "$READ_PY" --check || return $?
      lid=$(sb_gitea_api GET "repos/$REPO_NAME/labels" 2>/dev/null | jq -r --arg n "$l" '[.[] | select(.name == $n) | .id][0] // empty')
      [ -n "$lid" ] || sb_gitea_api POST "repos/$REPO_NAME/labels" \
        "$(jq -cn --arg n "$l" '{name:$n,color:"#5319e7"}')" >/dev/null 2>&1 || true
    done
    for l in "$@"; do
      python3 "$READ_PY" --check || return $?
      sb_gitea_label_add "$n" "$l" >/dev/null 2>&1 || echo "warn: could not label #${n} ${l}" >&2
    done
    return 0
  fi
  for l in "$@"; do
    python3 "$GITHUB_READ" --check || return $?
    gh label create "$l" ${REPO_FLAG[@]+"${REPO_FLAG[@]}"} --color 5319E7 --force >/dev/null 2>&1 || true
  done
  for l in "$@"; do
    python3 "$GITHUB_READ" --check || return $?
    gh issue edit "$n" ${REPO_FLAG[@]+"${REPO_FLAG[@]}"} --add-label "$l" >/dev/null 2>&1 || echo "warn: could not label #${n} ${l}" >&2
  done
  return 0
}

# --- adopt ------------------------------------------------------------------
if [ -n "$ADOPT" ]; then
  if [ "$YES" -ne 1 ]; then echo "would-adopt|#${ADOPT}|${TYPE}|${HOLD}"; exit 0; fi
  GITEA_GID=""
  if [ "$FORGE_KIND" = gitea ]; then
    ADOPT_JSON=$(python3 "$READ_PY" --kind issue --issue "$ADOPT") || exit $?
    URL=$(echo "$ADOPT_JSON" | jq -r .url)
    GITEA_GID=$(echo "$ADOPT_JSON" | jq -r .id)
    BOARD=$(python3 "$READ_PY" --kind items --items "$REPO_NAME/$NUMBER") || exit $?
  else
    URL=$(python3 "$GITHUB_READ" --kind scalar -- issue view "$ADOPT" ${REPO_FLAG[@]+"${REPO_FLAG[@]}"} --json url --jq .url) || exit $?
    BOARD=$(python3 "$GITHUB_READ" --kind items -- project item-list "$NUMBER" --owner "$OWNER" --format json --limit 500) || exit $?
  fi
  # A matching issue number without its repository URL cannot prove whether
  # this is already our card. Preserve potentially live work until reconciled.
  AMBIGUOUS=$(printf '%s' "$BOARD" | jq -r --argjson n "$ADOPT" '[.items[] | select(.content.type == "Issue" and .content.number == $n and ((.content.url // "") == ""))] | length') || exit 70
  if [ "$AMBIGUOUS" != 0 ]; then
    python3 "$READ_PY" --halt "Board identity is incomplete for issue #${ADOPT}; reconcile before adoption"
    exit 79
  fi
  # Never reset a card already on the board to Backlog, especially live work.
  ON_BOARD=$(printf '%s' "$BOARD" | jq -r --arg u "$URL" '[.items[] | select(.content.url == $u)] | length') || exit 70
  if [ "$ON_BOARD" != 0 ]; then echo "$ADOPT"; exit 0; fi
  state begin "$ADOPT" || exit $?
  tag "$ADOPT" "$TYPE" "source:collect" ${EXTRA_LABELS[@]+"${EXTRA_LABELS[@]}"} || { RC=$?; echo "$ADOPT"; exit "$RC"; }
  if [ "$FORGE_KIND" = gitea ]; then
    place_gitea "$GITEA_GID" || { RC=$?; echo "$ADOPT"; [ "$RC" -eq 79 ] && exit 79; echo "warn: #${ADOPT} not placed in '${HOLD}'" >&2; exit 71; }
  else
    place "$URL" || { RC=$?; echo "$ADOPT"; [ "$RC" -eq 79 ] && exit 79; echo "warn: #${ADOPT} not placed in '${HOLD}'" >&2; exit 71; }
  fi
  state success "$ADOPT" || exit $?
  echo "$ADOPT"; exit 0
fi

# --- dedupe -----------------------------------------------------------------
# Repo-wide, any label, any state. An open hit is a duplicate; a closed-only hit
# is a recurrence — file again, but name the issue that claimed the fix.
# Exact match on a whitespace-delimited token: `err|sentry|441` must not hit `err|sentry|4411`.
ISSUES_JSON=$(python3 "$READ_PY" --issue-history "$REPO_NAME") || exit $?
HITS=$(printf '%s' "$ISSUES_JSON" | jq -r --arg fp "$FP" '[.[] | select(any(.body | splits("\\s+"); . == $fp))] | sort_by(.state != "OPEN") | map("\(.number) \(.state)") | .[]') || exit 70

OPEN_HIT=$(echo "$HITS" | awk '$2=="OPEN"{print $1; exit}')
CLOSED_HIT=$(echo "$HITS" | awk '$2!="OPEN" && $1!=""{print $1; exit}')

if [ -n "$OPEN_HIT" ]; then
  if [ "$YES" -ne 1 ]; then echo "duplicate|#${OPEN_HIT}|${TYPE}|${TITLE}"; exit 0; fi
  python3 "$READ_PY" --check || { RC=$?; echo "$OPEN_HIT"; exit "$RC"; }
  SEEN=$(state seen "$OPEN_HIT") || exit $?
  if [ "$SEEN" = unchanged ]; then echo "$OPEN_HIT"; exit 0; fi
  state begin "$OPEN_HIT" || exit $?
  SEEN_BODY="Seen again by super-collect (${SOURCE}).

$(cat "$BODY_FILE")"
  if [ "$FORGE_KIND" = gitea ]; then
    sb_gitea_api POST "repos/$REPO_NAME/issues/${OPEN_HIT}/comments" \
      "$(jq -cn --arg b "$SEEN_BODY" '{body:$b}')" >/dev/null 2>&1 \
      || { python3 "$READ_PY" --halt "Collector comment outcome unknown for #${OPEN_HIT}; reconcile before retrying"; echo "$OPEN_HIT"; exit 79; }
  else
    gh issue comment "$OPEN_HIT" ${REPO_FLAG[@]+"${REPO_FLAG[@]}"} --body "$SEEN_BODY" >/dev/null 2>&1 \
      || { python3 "$READ_PY" --halt "Collector comment outcome unknown for #${OPEN_HIT}; reconcile before retrying"; echo "$OPEN_HIT"; exit 79; }
  fi
  state success "$OPEN_HIT" || exit $?
  echo "$OPEN_HIT"; exit 0
fi

if [ "$YES" -ne 1 ]; then
  # A bug's full shape is the QA filer's check; run it now so the plan never says
  # would-file for a body --yes would refuse with 66.
  if [ "$TYPE" = bug ]; then "$BIN/super-qa-file-bug.sh" --title "$TITLE" --body-file "$BODY_FILE" --check-body || exit $?; fi
  if [ -n "$CLOSED_HIT" ]; then echo "recurrence|#${CLOSED_HIT}|${TYPE}|${TITLE}|${HOLD}"
  else echo "would-file|${TYPE}|${TITLE}|${HOLD}"; fi
  exit 0
fi

state begin || exit $?

# --- compose + dispatch -----------------------------------------------------
BODY_TMP=$(mktemp)
trap 'rm -f "$BODY_TMP"' EXIT
{
  cat "$BODY_FILE"
  if [ -n "$CLOSED_HIT" ]; then
    echo; echo "> Recurrence: this fingerprint was last filed as #${CLOSED_HIT}, which is closed."
  fi
  echo; echo "<!-- super-collect-fingerprint: ${FP} -->"
  echo "<!-- super-collect-source: ${SOURCE} -->"
} > "$BODY_TMP"

ERR=$(mktemp)
case "$TYPE" in
  refactor)
    OUT=$("$BIN/super-review-file-refactor.sh" --config "$CONFIG" --title "$TITLE" \
      --body-file "$BODY_TMP" --fingerprint "$FP" --column "$HOLD" ${AREA:+--area "$AREA"} 2>"$ERR"); RC=$? ;;
  *)
    case "$TYPE" in bug) KIND=bug; WEAK=0 ;; feature) KIND=feature; WEAK=1 ;; fix) KIND=tech-debt; WEAK=1 ;; esac
    OUT=$(SUPER_QA_PROJECT_OWNER="$OWNER" SUPER_QA_PROJECT_TITLE="$PTITLE" \
      SUPER_QA_TARGET_OPTION_NAME="$HOLD" SUPER_QA_ALLOW_WEAK_BODY="$WEAK" SUPER_QA_REPO="$REPO_NAME" \
      SB_FORGE="$FORGE_KIND" SB_CONFIG="$CONFIG" \
      "$BIN/super-qa-file-bug.sh" --title "$TITLE" --body-file "$BODY_TMP" --kind "$KIND" \
      --priority "$PRIORITY" --fingerprint "$FP" ${AREA:+--area "$AREA"} 2>"$ERR"); RC=$? ;;
esac
cat "$ERR" >&2; rm -f "$ERR"
N=$(echo "$OUT" | tail -1)
# A child may have created the issue before a required placement read failed.
# Preserve its identity without tagging or making further writes after the halt.
if [ "$RC" -eq 79 ]; then [ -z "$N" ] || echo "$N"; exit 79; fi
if [ "$RC" -eq 64 ] || [ "$RC" -eq 66 ]; then state known-failure || true; fi
case "$N" in ''|*[!0-9]*) die "filer failed (exit ${RC})" "$([ "$RC" -ne 0 ] && echo "$RC" || echo 70)" ;; esac
if [ "$RC" -ne 0 ]; then
  python3 "$READ_PY" --halt "Collector filing/placement incomplete for #${N}; reconcile before retrying"
  echo "$N"; exit 79
fi
tag "$N" "source:collect" "collect:${SOURCE}" ${EXTRA_LABELS[@]+"${EXTRA_LABELS[@]}"} || { RC=$?; echo "$N"; exit "$RC"; }
if [ "$RC" -eq 0 ]; then state success "$N" || exit $?; fi
echo "$N"
exit "$RC"
