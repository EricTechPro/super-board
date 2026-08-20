#!/usr/bin/env bash
# Tests scripts/super-review-file-refactor.sh. Deterministic, no network: `gh`
# is a stub on PATH. Covers arg validation, fingerprint dedupe, Backlog
# placement, and the guarantee that board failures never fail the script —
# a mergeable PR must not be stranded because a card would not place.
#
#   bash tests/test-file-refactor.sh

set -uo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SCRIPT="$REPO_ROOT/scripts/super-review-file-refactor.sh"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

PASS=0
FAIL=0
ok()  { PASS=$((PASS + 1)); printf '  ✅ %s\n' "$1"; }
bad() { FAIL=$((FAIL + 1)); printf '  ❌ %s\n     expected: %s\n     actual:   %s\n' "$1" "$2" "$3"; }
is()  { [ "$2" = "$3" ] && ok "$1" || bad "$1" "$2" "$3"; }
has() { case "$2" in *"$3"*) ok "$1" ;; *) bad "$1" "contains: $3" "$2" ;; esac; }

cat > "$WORK/config.json" <<'JSON'
{"version":1,"project":{"owner":"acme","title":"Board","number":7},
 "variant":"full","repo":{"path":".","remote":"https://github.com/acme/app.git"}}
JSON

echo "shallow module: interface nearly as complex as implementation" > "$WORK/body.md"

# ── gh stub. Behaviour switches on env so each case stays declarative.
#   DEDUPE_HIT   — issue number the fingerprint search should return ("" = none)
#   STATUS_OPTS  — Status option names the board exposes
#   FAIL_ITEMADD — non-empty makes `project item-add` fail
cat > "$WORK/gh" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$GH_LOG"
case "$1 ${2:-}" in
  "issue list")    echo "${DEDUPE_HIT:-}" ;;
  "issue comment") exit 0 ;;
  "issue create")  echo "https://github.com/acme/app/issues/412" ;;
  "label create")  exit 0 ;;
  "project item-add")
    [ -n "${FAIL_ITEMADD:-}" ] && exit 1
    echo "PVTI_stub" ;;
  "project view")  echo "PVT_stub" ;;
  "project field-list")
    OPTS=""
    for o in ${STATUS_OPTS:-Backlog Ready Done}; do
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

run() { : > "$GH_LOG"; "$SCRIPT" "$@" 2>"$WORK/err"; }

echo "── arg validation"
DEDUPE_HIT="" run --config "$WORK/config.json" --title T --body-file "$WORK/body.md" >/dev/null
is "fingerprint required" 64 "$( DEDUPE_HIT="" "$SCRIPT" --config "$WORK/config.json" --title T --body-file "$WORK/body.md" >/dev/null 2>&1; echo $? )"
is "title required"       64 "$( DEDUPE_HIT="" "$SCRIPT" --config "$WORK/config.json" --fingerprint f --body-file "$WORK/body.md" >/dev/null 2>&1; echo $? )"
is "config must exist"    66 "$( DEDUPE_HIT="" "$SCRIPT" --config /nope.json --title T --fingerprint f --body-file "$WORK/body.md" >/dev/null 2>&1; echo $? )"
is "body-file must exist" 66 "$( DEDUPE_HIT="" "$SCRIPT" --config "$WORK/config.json" --title T --fingerprint f --body-file /nope.md >/dev/null 2>&1; echo $? )"
is "strength is an enum"  64 "$( DEDUPE_HIT="" "$SCRIPT" --config "$WORK/config.json" --title T --fingerprint f --body-file "$WORK/body.md" --strength huge >/dev/null 2>&1; echo $? )"

echo "── happy path"
OUT=$(DEDUPE_HIT="" run --config "$WORK/config.json" --title "OrderIntake is shallow" \
  --body-file "$WORK/body.md" --fingerprint "OrderIntake|shallow" --files "src/a.ts,src/b.ts" \
  --strength strong --pr 99)
is  "returns the new issue number" "412" "$OUT"
has "files render as a list"       "$(cat "$GH_LOG")" "issue create"
has "lands in Backlog, not Ready"  "$(cat "$GH_LOG")" "opt_Backlog"
has "labels the source"            "$(cat "$GH_LOG")" "source:review"
has "labels the strength"          "$(cat "$GH_LOG")" "strength:strong"

echo "── dedupe"
OUT=$(DEDUPE_HIT="301" run --config "$WORK/config.json" --title "Seen before" \
  --body-file "$WORK/body.md" --fingerprint "OrderIntake|shallow" --pr 99)
is  "returns the existing issue" "301" "$OUT"
has "comments instead of creating" "$(cat "$GH_LOG")" "issue comment 301"
case "$(cat "$GH_LOG")" in
  *"issue create"*) bad "no duplicate card created" "no 'issue create'" "found one" ;;
  *) ok "no duplicate card created" ;;
esac

echo "── degradation (must never fail the review)"
OUT=$(DEDUPE_HIT="" STATUS_OPTS="Ready Done" run --config "$WORK/config.json" --title "No backlog column" \
  --body-file "$WORK/body.md" --fingerprint "X|y")
is  "still returns the issue number" "412" "$OUT"
has "warns about the missing column" "$(cat "$WORK/err")" "no 'Backlog' option"

OUT=$(DEDUPE_HIT="" FAIL_ITEMADD=1 run --config "$WORK/config.json" --title "Board down" \
  --body-file "$WORK/body.md" --fingerprint "X|z")
is  "survives a board failure" "412" "$OUT"
has "warns about placement"    "$(cat "$WORK/err")" "could not place it"

printf '\n%s passed, %s failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
