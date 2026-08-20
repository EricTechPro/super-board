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
trap 'rm -rf "$WORK"' EXIT

PASS=0
FAIL=0
ok()  { PASS=$((PASS + 1)); printf '  ✅ %s\n' "$1"; }
bad() { FAIL=$((FAIL + 1)); printf '  ❌ %s\n     expected: %s\n     actual:   %s\n' "$1" "$2" "$3"; }
is()  { [ "$2" = "$3" ] && ok "$1" || bad "$1" "$2" "$3"; }
has() { case "$2" in *"$3"*) ok "$1" ;; *) bad "$1" "contains: $3" "$2" ;; esac; }
hasnt() { case "$2" in *"$3"*) bad "$1" "no '$3'" "found it" ;; *) ok "$1" ;; esac; }

# A complete, actionable body — the shape the preamble tells the agent to write.
cat > "$WORK/good.md" <<'BODY'
## Summary
CSV upload reports success but no rows land in the imports table.

## Repro steps
1. Log in as the QA bot, go to /imports
2. Upload fixtures/ten-rows.csv, click Submit
3. Banner says "Imported", table stays empty

## Expected behavior
Per SPEC.md the ten rows appear in the imports table.

## Actual behavior
Table is empty. The job never reaches a terminal state.

## Evidence
- Screenshot: docs/super-qa/report/imports/tc-1/en/after-submit.png
- Console: 0 errors
- Network: POST /api/imports returns 202, no follow-up
- Spec: e2e/paths/imports.spec.ts

## Suggested fix path
- Suggested owner: super-build
- Notes for implementer: server/imports/job-handler.ts

## Acceptance criteria
- [ ] Uploaded rows are visible after submit
- [ ] Regression coverage added
- [ ] Super QA rerun passes /imports
BODY

sed '/## Evidence/,/## Suggested fix path/d' "$WORK/good.md" > "$WORK/no-evidence.md"
sed 's|CSV upload reports success but no rows land in the imports table.|<one sentence: what is wrong and where>|' "$WORK/good.md" > "$WORK/placeholder.md"
sed 's|server/imports/job-handler.ts|TBD|' "$WORK/good.md" > "$WORK/tbd.md"

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
  "issue list")    echo "${DEDUPE_HIT:-}" ;;
  "issue comment") exit 0 ;;
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

echo "── happy path"
OUT=$(run "${BASE[@]}" --kind bug --priority high --category functional \
  --area imports --route /imports --spec e2e/paths/imports.spec.ts --iter 3 \
  --fingerprint "imports|tc-1|silent-drop" --suggested-skill super-build)
is  "returns the issue number"   "77" "$OUT"
has "board-readable title"       "$(cat "$GH_LOG")" "🐛 Bug /imports — CSV upload silently drops rows"
has "labels the source"          "$(cat "$GH_LOG")" "source:qa"
has "labels the priority"        "$(cat "$GH_LOG")" "priority:high"
has "labels the qa category"     "$(cat "$GH_LOG")" "qa:functional"
has "labels the owner"           "$(cat "$GH_LOG")" "skill:super-build"
has "lands in Bug column"        "$(cat "$GH_LOG")" "opt_Bug"
has "prepends Board summary"     "$(cat "$BODY_CAPTURE")" "## Board summary"
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

echo "── exit 71 contract"
OUT=$(FAIL_ITEMADD=1 run "${BASE[@]}"; echo "rc=$?")
has "number still reaches stdout" "$OUT" "77"
has "signals promote failure"     "$OUT" "rc=71"
has "says a manual move is needed" "$(cat "$WORK/err")" "manual move required"

printf '\n%s passed, %s failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
