#!/usr/bin/env bash
# Tests skills/super-collect/scripts/super-collect-file.sh. Deterministic, no
# network: `gh` is a stub on PATH, and the real super-qa / super-review filers
# run underneath it. Covers dry-run default, per-source fingerprint shapes,
# repo-wide dedupe, recurrence, holding-column resolution (never Ready), routing,
# extra labels (needs-triage), and --adopt.
#
#   bash tests/test-collect-file.sh

set -uo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SCRIPT="$REPO_ROOT/skills/super-collect/scripts/super-collect-file.sh"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

PASS=0; FAIL=0
ok()  { PASS=$((PASS + 1)); printf '  ✅ %s\n' "$1"; }
bad() { FAIL=$((FAIL + 1)); printf '  ❌ %s\n     expected: %s\n     actual:   %s\n' "$1" "$2" "$3"; }
is()  { [ "$2" = "$3" ] && ok "$1" || bad "$1" "$2" "$3"; }
has() { case "$2" in *"$3"*) ok "$1" ;; *) bad "$1" "contains: $3" "$2" ;; esac; }
lacks() { case "$2" in *"$3"*) bad "$1" "no: $3" "found it" ;; *) ok "$1" ;; esac; }

cat > "$WORK/config.json" <<'JSON'
{"version":1,"project":{"owner":"acme","title":"Board","number":7},
 "variant":"full","repo":{"path":".","remote":"https://github.com/acme/app.git"}}
JSON

cat > "$WORK/bug.md" <<'MD'
## Summary
Checkout 500s on empty cart.
## Repro steps
1. Open /checkout with an empty cart.
## Expected behavior
Empty-cart message.
## Actual behavior
HTTP 500.
## Evidence
Sentry issue 4411, 37 events in 14d.
## Suggested fix path
Guard the empty cart in CheckoutService.
## Acceptance criteria
- [ ] Empty cart renders the message, no 500.
MD

cat > "$WORK/fix.md" <<'MD'
## Summary
Merge gate keeps bouncing cards on stale lockfiles.
## Evidence
Runs 2026-09-01, 09-08, 09-15: #12, #19, #27 bounced on lockfile drift.
## Root cause
verify_commands run without npm ci.
## Acceptance criteria
- [ ] verify_commands install before typecheck.
MD

# gh stub. Env switches:
#   HITS        — JSON array the issue-list dedupe query sees ([{number,state,body}])
#   STATUS_OPTS — Status option names on the board
cat > "$WORK/gh" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$GH_LOG"
case "$1 ${2:-}" in
  "repo view")     echo "acme" ;;
  "issue list")
    jq_expr=""; prev=""
    for a in "$@"; do [ "$prev" = "--jq" ] && jq_expr="$a"; prev="$a"; done
    echo "${HITS:-[]}" | jq -r "$jq_expr" ;;
  "issue view")    echo "https://github.com/acme/app/issues/55" ;;
  "issue create")
    prev=""
    for a in "$@"; do [ "$prev" = "--body-file" ] && [ -r "$a" ] && cat "$a" > "$BODY_LOG"; prev="$a"; done
    echo "https://github.com/acme/app/issues/412" ;;
  "project list")  echo '{"projects":[{"number":7,"title":"Board"}]}' ;;
  "project item-add") echo "PVTI_stub" ;;
  "project view")  echo "PVT_stub" ;;
  "project field-list")
    OPTS=""
    for encoded in ${STATUS_OPTS:-Backlog Ready Done}; do
      name=$(echo "$encoded" | tr '_' ' ')
      OPTS="${OPTS}{\"id\":\"opt_${encoded}\",\"name\":\"${name}\"},"
    done
    echo "{\"fields\":[{\"id\":\"FLD_status\",\"name\":\"Status\",\"options\":[${OPTS%,}]}]}" ;;
  *) exit 0 ;;
esac
STUB
chmod +x "$WORK/gh"
export PATH="$WORK:$PATH" GH_LOG="$WORK/gh.log" BODY_LOG="$WORK/body.filed"
export SUPER_BOARD_BIN="$REPO_ROOT/scripts"

run() { : > "$GH_LOG"; : > "$BODY_LOG"; "$SCRIPT" --config "$WORK/config.json" "$@" 2>"$WORK/err"; }
BUG=(--type bug --source sentry --title "Checkout 500 on empty cart" --body-file "$WORK/bug.md" --fingerprint "err|sentry|4411")
FIX=(--type fix --source prs --title "Merge gate bounces on lockfile drift" --body-file "$WORK/fix.md" --fingerprint "prs|merge-gate|lockfile-drift")

echo "── arg validation"
is "type is an enum"        64 "$(run --type chore --source sentry --title T --body-file "$WORK/bug.md" --fingerprint f >/dev/null; echo $?)"
is "source is an enum"      64 "$(run --type bug --source vibes --title T --body-file "$WORK/bug.md" --fingerprint f >/dev/null; echo $?)"
is "old intake source gone" 64 "$(run --type bug --source intake --title T --body-file "$WORK/bug.md" --fingerprint "err|sentry|1" >/dev/null; echo $?)"
is "fp must match source"   64 "$(run --type bug --source posthog --title T --body-file "$WORK/bug.md" --fingerprint "err|sentry|1" >/dev/null; echo $?)"
is "gap only for posthog"  64 "$(run --type feature --source sentry --title T --body-file "$WORK/fix.md" --fingerprint "gap|checkout" >/dev/null; echo $?)"
is "fp prefix needs a key"  64 "$(run --type bug --source sentry --title T --body-file "$WORK/bug.md" --fingerprint "err|sentry|" >/dev/null; echo $?)"
for pair in "sentry err|sentry|9" "posthog posthog|exception|abc123" "posthog gap|checkout" "github github|55" "prs prs|merge-gate|drift" "architecture arch|order-intake|shallow"; do
  src=${pair%% *}; fp=${pair#* }
  OUT=$(run --type bug --source "$src" --title T --body-file "$WORK/bug.md" --fingerprint "$fp")
  has "fingerprint shape accepted for $src" "$OUT" "would-file|bug|T|Backlog"
done
is "fingerprint required"   64 "$(run --type bug --source sentry --title T --body-file "$WORK/bug.md" >/dev/null; echo $?)"
is "fix needs Root cause"   66 "$(run --type fix --source prs --title T --body-file "$WORK/bug.md" --fingerprint "prs|x|y" >/dev/null; echo $?)"

echo "── dry-run is the default"
OUT=$(run "${BUG[@]}")
is    "plans, does not file"       "would-file|bug|Checkout 500 on empty cart|Backlog" "$OUT"
lacks "no issue create on dry-run" "$(cat "$GH_LOG")" "issue create"

echo "── holding column, never Ready"
OUT=$(STATUS_OPTS="Todo Ready Done" run "${BUG[@]}")
has "falls back to another holding column" "$OUT" "|Todo"
is  "no holding column refuses" 65 "$(STATUS_OPTS="Ready QA Done" run "${BUG[@]}" >/dev/null; echo $?)"

echo "── dedupe"
OUT=$(HITS='[{"number":301,"state":"OPEN","body":"x err|sentry|4411 y"}]' run "${BUG[@]}")
is  "open hit is a duplicate" "duplicate|#301|bug|Checkout 500 on empty cart" "$OUT"
OUT=$(HITS='[{"number":301,"state":"OPEN","body":"err|sentry|4411"}]' run "${BUG[@]}" --yes)
is  "--yes on duplicate returns existing" "301" "$OUT"
has "comments instead of filing" "$(cat "$GH_LOG")" "issue comment 301"
lacks "no duplicate card" "$(cat "$GH_LOG")" "issue create"
OUT=$(HITS='[{"number":88,"state":"CLOSED","body":"prs|merge-gate|lockfile-drift"}]' run "${FIX[@]}")
has "closed-only hit is a recurrence" "$OUT" "recurrence|#88"

echo "── filing a bug through super-qa-file-bug.sh"
OUT=$(run "${BUG[@]}" --yes)
is  "returns the new issue" "412" "$OUT"
has "routes via the QA filer (source:qa label)" "$(cat "$GH_LOG")" "source:qa"
has "lands in Backlog"        "$(cat "$GH_LOG")" "opt_Backlog"
lacks "never Ready"           "$(cat "$GH_LOG")" "opt_Ready"
has "stamps the fingerprint"  "$(cat "$BODY_LOG")" "super-collect-fingerprint: err|sentry|4411"
has "labels source:collect"   "$(cat "$GH_LOG")" "source:collect"

echo "── filing a prs fix (weak-body bypass, own section check)"
OUT=$(HITS='[{"number":88,"state":"CLOSED","body":"prs|merge-gate|lockfile-drift"}]' run "${FIX[@]}" --yes)
is  "returns the new issue" "412" "$OUT"
has "files as tech-debt"      "$(cat "$GH_LOG")" "tech-debt"
has "names the recurrence"    "$(cat "$BODY_LOG")" "#88"
lacks "never Ready"           "$(cat "$GH_LOG")" "opt_Ready"

echo "── refactor with criteria still lands in Backlog (filer would pick Ready)"
OUT=$(run --type refactor --source architecture --title "Split OrderIntake" --body-file "$WORK/fix.md" --fingerprint "arch|order-intake|shallow" --yes)
has "routes via the review filer" "$(cat "$GH_LOG")" "source:review"
has "lands in Backlog"            "$(cat "$GH_LOG")" "opt_Backlog"
lacks "never Ready"               "$(cat "$GH_LOG")" "opt_Ready"

has "labels collect:architecture" "$(cat "$GH_LOG")" "collect:architecture"

echo "── posthog bug with extra labels (needs-triage, ux)"
OUT=$(run --type bug --source posthog --title "Dead clicks on /checkout" --body-file "$WORK/bug.md" --fingerprint "posthog|dead_click|1a2b3c" --label needs-triage --label ux --yes)
is  "returns the new issue"   "412" "$OUT"
has "stamps posthog fingerprint" "$(cat "$BODY_LOG")" "super-collect-fingerprint: posthog|dead_click|1a2b3c"
has "labels needs-triage"     "$(cat "$GH_LOG")" "--add-label needs-triage"
has "labels ux"               "$(cat "$GH_LOG")" "--add-label ux"
has "labels collect:posthog"  "$(cat "$GH_LOG")" "collect:posthog"
lacks "never Ready"           "$(cat "$GH_LOG")" "opt_Ready"

echo "── adopt a user-filed issue"
is  "adopt dry-run" "would-adopt|#55|feature|Backlog" "$(run --adopt 55 --type feature)"
OUT=$(run --adopt 55 --type feature --yes)
is  "adopt returns the issue" "55" "$OUT"
lacks "adopt files nothing new" "$(cat "$GH_LOG")" "issue create"
has "adopt places in Backlog"  "$(cat "$GH_LOG")" "opt_Backlog"

echo
echo "passed: $PASS  failed: $FAIL"
[ "$FAIL" -eq 0 ]
