#!/usr/bin/env bash
# Tests scripts/super-qa-file-bug.sh. Deterministic, no network: `gh` is a stub
# on PATH. Covers the enum guards, the body guardrails that keep unactionable
# tickets off the board, project resolution, fingerprint dedupe, and the exit-71
# contract (issue number reaches stdout even when the board promote fails).
#
#   bash tests/test-file-bug.sh

set -uo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SCRIPT="$REPO_ROOT/scripts/super-qa-file-bug.sh"
WORK="$(mktemp -d)"
export SB_GITHUB_RETRY_DELAY=0 SB_GITHUB_HALT_FILE="$WORK/halt.json"
trap 'rm -rf "$WORK"' EXIT

PASS=0
FAIL=0
ok()  { PASS=$((PASS + 1)); printf '  ✅ %s\n' "$1"; }
bad() { FAIL=$((FAIL + 1)); printf '  ❌ %s\n     expected: %s\n     actual:   %s\n' "$1" "$2" "$3"; }
is()  { [ "$2" = "$3" ] && ok "$1" || bad "$1" "$2" "$3"; }
has() { case "$2" in *"$3"*) ok "$1" ;; *) bad "$1" "contains: $3" "$2" ;; esac; }
hasnt() { case "$2" in *"$3"*) bad "$1" "no '$3'" "found it" ;; *) ok "$1" ;; esac; }

# A complete, actionable body — the ticket format in writing-standard.md § 3.
cat > "$WORK/good.md" <<'BODY'
## Problem
CSV upload reports success but no rows land in the imports table.

## Context
- **Where:** Imports page, `/imports`
  - a. Log in as the QA bot
  - b. Upload `fixtures/ten-rows.csv`
  - c. Click **Submit**
- **Who:** any signed-in user

![imports](https://github.com/acme/app/raw/abc1234/docs/super-qa/report/imports/tc-1/en/after-submit.png)

## Evidence
<details><summary>12 rows · no Sentry event · 1 user</summary>

| Row | Value |
|---|---|
| Error + stack | n/a — no client or server error |
| Request / trace ID | `req_42` |
| Sentry | n/a — nothing captured |
| PostHog replay | n/a — replay off on staging |
| Logs | `job 91 queued, never picked up` |
| Screenshots | ![after](https://github.com/acme/app/raw/abc1234/after-submit.png) |
| HAR / API sample | `POST /api/imports → 202` |
| Env + release | staging · `abc1234` |
| First / last seen | Oct 1 · Oct 2 |
| Users affected | 1 (QA bot) |
| Steps | 1. log in 2. upload 3. submit |
| Expected / actual | ten rows / empty table |

</details>

## Fix
Make the import job reach a terminal state; see `server/imports/job-handler.ts`.

## Acceptance Criteria
- [ ] Uploaded rows are visible after submit
- [ ] Regression coverage added
- [ ] Super QA rerun passes /imports

## Risk
🟢 **Low** · one handler, covered by the imports spec.
BODY

sed '/## Evidence/,/## Fix/d' "$WORK/good.md" > "$WORK/no-evidence.md"
sed 's|CSV upload reports success but no rows land in the imports table.|<one sentence: what is wrong and where>|' "$WORK/good.md" > "$WORK/placeholder.md"
sed 's|Make the import job reach a terminal state|TBD|' "$WORK/good.md" > "$WORK/tbd.md"
sed 's|^- \[ \] |- |' "$WORK/good.md" > "$WORK/no-checklist.md"
sed '/  - [abc]\. /d' "$WORK/good.md" > "$WORK/no-steps.md"
sed '/| PostHog replay |/d' "$WORK/good.md" > "$WORK/short-evidence.md"
sed 's|<details><summary>12 rows · no Sentry event · 1 user</summary>||; s|</details>||' "$WORK/good.md" > "$WORK/open-evidence.md"
sed 's|  - b. Upload `fixtures/ten-rows.csv`|  - b. Upload → Submit|' "$WORK/good.md" > "$WORK/arrows.md"

# ── gh stub.
#   DEDUPE_HIT    — issue number the fingerprint search returns ("" = none)
#   PROJECTS      — titles `project list` reports
#   STATUS_OPTS   — Status option names on the board
#   FAIL_ITEMADD  — non-empty makes `project item-add` fail
cat > "$WORK/gh" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$GH_LOG"
case "$1 ${2:-}" in
  "repo view")     echo "acme" ;;
  "issue list")    [ -z "${FAIL_DEDUPE:-}" ] || exit 1; if [ -n "${DEDUPE_HIT:-}" ]; then
      jq -n --argjson n "$DEDUPE_HIT" '[{number:$n,body:"imports|tc-1|silent-drop OrderIntake|shallow outage|test"}]'
    else echo '[]'; fi ;;
  "issue comment") [ -z "${FAIL_COMMENT:-}" ] || exit 1; exit 0 ;;
  "issue create")
    for a in "$@"; do
      [ -f "$a" ] && cp "$a" "$BODY_CAPTURE" 2>/dev/null
    done
    echo "https://github.com/acme/app/issues/77" ;;
  "label create")  exit 0 ;;
  "project list")
    P=""
    for t in ${PROJECTS:-Super_Ultimate_QA}; do
      P="${P}{\"number\":9,\"title\":\"$(echo "$t" | tr '_' ' ')\"},"
    done
    echo "{\"projects\":[${P%,}]}" ;;
  "project item-add")
    [ -n "${FAIL_ITEMADD:-}" ] && exit 1
    echo "PVTI_stub" ;;
  "project view") echo "PVT_stub" ;;
  "project field-list")
    OPTS=""
    for o in ${STATUS_OPTS:-Bug Flaky Skip}; do
      OPTS="${OPTS}{\"id\":\"opt_${o}\",\"name\":\"${o}\"},"
    done
    echo "{\"fields\":[{\"id\":\"FLD_status\",\"name\":\"Status\",\"options\":[${OPTS%,}]}]}" ;;
  "project item-edit") exit 0 ;;
  *) exit 0 ;;
esac
STUB
chmod +x "$WORK/gh"
export PATH="$WORK:$PATH"
export GH_LOG="$WORK/gh.log"
export BODY_CAPTURE="$WORK/body-sent.md"

run() { : > "$GH_LOG"; : > "$BODY_CAPTURE"; DEDUPE_HIT="${DEDUPE_HIT:-}" "$SCRIPT" "$@" 2>"$WORK/err"; }
code() { run "$@" >/dev/null; echo $?; }

BASE=(--title "CSV upload silently drops rows" --body-file "$WORK/good.md")

echo "── arg + enum validation"
is "title required"      64 "$(code --body-file "$WORK/good.md")"
is "body-file required"  66 "$(code --title T)"
is "body-file must exist" 66 "$(code --title T --body-file /nope.md)"
is "kind is an enum"     64 "$(code "${BASE[@]}" --kind catastrophe)"
is "priority is an enum" 64 "$(code "${BASE[@]}" --priority urgent)"
is "category is an enum" 64 "$(code "${BASE[@]}" --category vibes)"
is "owner is an enum"    64 "$(code "${BASE[@]}" --suggested-skill super-duper)"

echo "── body guardrails"
is "rejects a missing section"   66 "$(code --title T --body-file "$WORK/no-evidence.md")"
has "names the missing section"  "$(cat "$WORK/err")" "Evidence"
is "rejects <placeholder>"       66 "$(code --title T --body-file "$WORK/placeholder.md")"
is "rejects TBD"                 66 "$(code --title T --body-file "$WORK/tbd.md")"
is "escape hatch files it anyway" 0 "$(SUPER_QA_ALLOW_WEAK_BODY=1 code --title T --body-file "$WORK/tbd.md")"
is "rejects AC without a checklist" 66 "$(code --title T --body-file "$WORK/no-checklist.md")"
has "says why"                      "$(cat "$WORK/err")" "checklist"
is "rejects Context without lettered steps" 66 "$(code --title T --body-file "$WORK/no-steps.md")"
is "rejects arrows in steps"        66 "$(code --title T --body-file "$WORK/arrows.md")"
is "rejects an Evidence row missing" 66 "$(code --title T --body-file "$WORK/short-evidence.md")"
has "names the missing row"         "$(cat "$WORK/err")" "posthog replay"
is "rejects an unfolded Evidence table" 66 "$(code --title T --body-file "$WORK/open-evidence.md")"

echo "── happy path"
OUT=$(run "${BASE[@]}" --kind bug --priority high --category functional \
  --area imports --route /imports --spec e2e/paths/imports.spec.ts --iter 3 \
  --fingerprint "imports|tc-1|silent-drop" --suggested-skill super-build)
is  "returns the issue number"   "77" "$OUT"
has "board-readable title"       "$(cat "$GH_LOG")" "🐛 [bug] imports: CSV upload silently drops rows"
has "labels the source"          "$(cat "$GH_LOG")" "source:qa"
has "labels the priority"        "$(cat "$GH_LOG")" "priority:high"
has "labels the qa category"     "$(cat "$GH_LOG")" "qa:functional"
has "labels the owner"           "$(cat "$GH_LOG")" "skill:super-build"
has "lands in Bug column"        "$(cat "$GH_LOG")" "opt_Bug"
has "prepends Board summary"     "$(cat "$BODY_CAPTURE")" "## Board summary"
has "appends Blocked by when absent" "$(cat "$BODY_CAPTURE")" "## Blocked by"
has "states no blocker explicitly"  "$(cat "$BODY_CAPTURE")" "- None."
has "embeds the meta block"      "$(cat "$BODY_CAPTURE")" "fingerprint: imports|tc-1|silent-drop"
has "meta carries the spec"      "$(cat "$BODY_CAPTURE")" "spec: e2e/paths/imports.spec.ts"

echo "── derived fingerprint is iteration-independent"
run "${BASE[@]}" --route /imports --category functional --iter 3 >/dev/null
FP3=$(grep '^fingerprint:' "$BODY_CAPTURE")
run "${BASE[@]}" --route /imports --category functional --iter 9 >/dev/null
FP9=$(grep '^fingerprint:' "$BODY_CAPTURE")
is "same finding, later iter → same key" "$FP3" "$FP9"

echo "── project resolution"
is "halts when the QA project is absent" 70 "$(PROJECTS="Some_Other_Board" code "${BASE[@]}")"
has "tells the operator what to do" "$(cat "$WORK/err")" "create one, or set SUPER_QA_PROJECT_TITLE"
OUT=$(PROJECTS="My_QA_Board" SUPER_QA_PROJECT_TITLE="My QA Board" run "${BASE[@]}")
is "honours SUPER_QA_PROJECT_TITLE" "77" "$OUT"
OUT=$(STATUS_OPTS="Bug Triage" SUPER_QA_TARGET_OPTION_NAME="Triage" run "${BASE[@]}")
has "honours SUPER_QA_TARGET_OPTION_NAME" "$(cat "$GH_LOG")" "opt_Triage"

echo "── dedupe"
OUT=$(DEDUPE_HIT="55" run "${BASE[@]}" --fingerprint "imports|tc-1|silent-drop" --iter 4)
is    "returns the existing issue"   "55" "$OUT"
has   "comments the new sighting"    "$(cat "$GH_LOG")" "issue comment 55"
hasnt "files no duplicate card"      "$(cat "$GH_LOG")" "issue create"

echo "── uncertain placement pauses and preserves the created issue"
OUT=$(FAIL_ITEMADD=1 run "${BASE[@]}"; echo "rc=$?")
has "number still reaches stdout" "$OUT" "77"
has "signals promote failure"     "$OUT" "rc=79"
has "says reconciliation is needed" "$(cat "$WORK/err")" "reconcile before retrying"

echo "── required-read and uncertain-write failure"
rm -f "$SB_GITHUB_HALT_FILE"
OUT=$(FAIL_DEDUPE=1 run --title "Read outage" --body-file "$WORK/good.md" --fingerprint "outage|test"); RC=$?
is "three failed dedupe reads halt" 79 "$RC"
case "$(cat "$GH_LOG")" in *"issue create"*|*"issue comment"*) bad "unreadable dedupe never writes" "no writes" "write attempted" ;; *) ok "unreadable dedupe never writes" ;; esac
is "three dedupe attempts" 3 "$(grep -c '^issue list' "$GH_LOG")"
rm -f "$SB_GITHUB_HALT_FILE"
OUT=$(FAIL_COMMENT=1 DEDUPE_HIT=301 run --title "Write outage" --body-file "$WORK/good.md" --fingerprint "outage|test"); RC=$?
is "uncertain comment outcome halts" 79 "$RC"
is "comment is attempted once" 1 "$(grep -c '^issue comment' "$GH_LOG")"
is "failed comment does not report success ID" "" "$OUT"

printf '\n%s passed, %s failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
