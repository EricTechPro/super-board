#!/usr/bin/env bash
# Tests scripts/super-board-pr-body.sh — one marker block rewritten, the rest
# untouched, nothing written when the PR head moved. `gh` is a stub on PATH.
#
#   bash tests/test-pr-body.sh
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SCRIPT="$REPO_ROOT/scripts/super-board-pr-body.sh"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

PASS=0; FAIL=0
ok()  { PASS=$((PASS + 1)); printf '  ✅ %s\n' "$1"; }
bad() { FAIL=$((FAIL + 1)); printf '  ❌ %s\n     expected: %s\n     actual:   %s\n' "$1" "$2" "$3"; }
is()  { [ "$2" = "$3" ] && ok "$1" || bad "$1" "$2" "$3"; }
has() { case "$2" in *"$3"*) ok "$1" ;; *) bad "$1" "contains: $3" "$2" ;; esac; }
hasnt() { case "$2" in *"$3"*) bad "$1" "no '$3'" "found it" ;; *) ok "$1" ;; esac; }

# gh stub: `pr view` serves $WORK/body.md and $HEAD_OID; `pr edit --body-file` stores the new body.
cat > "$WORK/gh" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$GH_LOG"
case "$1 $2" in
  "pr view") jq -n --arg h "$HEAD_OID" --rawfile b "$BODY" '{headRefOid: $h, body: $b}' ;;
  "pr edit")
    while [ $# -gt 0 ]; do [ "$1" = "--body-file" ] && cp "$2" "$BODY"; shift; done ;;
esac
STUB
chmod +x "$WORK/gh"
export PATH="$WORK:$PATH" GH_LOG="$WORK/gh.log" BODY="$WORK/body.md" HEAD_OID="3f9c2a1aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"

cat > "$BODY" <<'MD'
<!-- sb:status -->
> [!NOTE]
> ⏳ In QA · ✅ 0/2 AC · Closes #7 · head `3f9c2a1`
<!-- /sb:status -->

<!-- sb:problem -->
## Problem
- **Where:** `/x`
<!-- /sb:problem -->

<!-- sb:history -->
## Iteration history
| Lane | Done | Time | Details |
|---|---|---|---|
| 🔨 builder | ✅ | Oct 2, 10:02 EDT | draft |
<!-- /sb:history -->
MD

printf '> [!TIP]\n> ✅ Merged · `9c41e07`\n' > "$WORK/status.md"
printf '## Risk\n🟢 **Low** · one constant.\n' > "$WORK/risk.md"
printf '| 🔍 qa | ✅ v1 | Oct 2, 11:55 EDT | runs/issue-7-qa-v1/ |\n' > "$WORK/row.md"

run() { : > "$GH_LOG"; "$SCRIPT" "$@" 2>"$WORK/err"; }

echo "── replace one block, keep the rest"
is  "replace reports updated" "updated" "$(run --pr 7 --block status --expect-head 3f9c2a1 --body-file "$WORK/status.md")"
has "new status written"      "$(cat "$BODY")" "✅ Merged"
hasnt "old status gone"       "$(cat "$BODY")" "In QA"
has "problem block untouched" "$(cat "$BODY")" '- **Where:** `/x`'

echo "── idempotent"
is  "same content twice is a no-op" "unchanged" "$(run --pr 7 --block status --expect-head 3f9c2a1 --body-file "$WORK/status.md")"
hasnt "no edit call on a no-op"     "$(cat "$GH_LOG")" "pr edit"

echo "── missing block inserted in order"
run --pr 7 --block risk --expect-head 3f9c2a1 --body-file "$WORK/risk.md" >/dev/null
has "risk inserted" "$(cat "$BODY")" "<!-- sb:risk -->"
H=$(grep -n 'sb:history -->' "$BODY" | head -1 | cut -d: -f1); R=$(grep -n '<!-- sb:risk -->' "$BODY" | cut -d: -f1)
[ "$R" -gt "$H" ] && ok "risk lands after history" || bad "risk lands after history" "line > $H" "$R"
printf '## Solution\n- one change\n' > "$WORK/sol.md"
run --pr 7 --block solution --expect-head 3f9c2a1 --body-file "$WORK/sol.md" >/dev/null
P=$(grep -n '<!-- /sb:problem -->' "$BODY" | cut -d: -f1); S=$(grep -n '<!-- sb:solution -->' "$BODY" | cut -d: -f1)
H=$(grep -n '<!-- sb:history -->' "$BODY" | cut -d: -f1)
[ "$S" -gt "$P" ] && [ "$S" -lt "$H" ] && ok "solution lands between problem and history" || bad "solution between problem and history" "$P < x < $H" "$S"

echo "── append a history row, once"
run --pr 7 --block history --expect-head 3f9c2a1 --append-file "$WORK/row.md" >/dev/null
has "row appended" "$(cat "$BODY")" "runs/issue-7-qa-v1/"
is  "re-append is a no-op" "unchanged" "$(run --pr 7 --block history --expect-head 3f9c2a1 --append-file "$WORK/row.md")"
is  "row appears once" "1" "$(grep -c 'runs/issue-7-qa-v1/' "$BODY")"

echo "── refuses when the head moved"
cp "$BODY" "$WORK/before.md"
RC=0; run --pr 7 --block status --expect-head deadbee --body-file "$WORK/risk.md" >/dev/null || RC=$?
is  "moved head exits 6" "6" "$RC"
hasnt "no edit on a moved head" "$(cat "$GH_LOG")" "pr edit"
is  "body unchanged" "$(cat "$WORK/before.md")" "$(cat "$BODY")"

echo "── usage"
RC=0; run --pr 7 --block status --body-file "$WORK/risk.md" >/dev/null || RC=$?; is "expect-head required" 64 "$RC"
RC=0; run --pr 7 --block nope --expect-head x --body-file "$WORK/risk.md" >/dev/null || RC=$?; is "block is an enum" 64 "$RC"
RC=0; run --pr 7 --block ac --expect-head x >/dev/null || RC=$?; is "content file required" 64 "$RC"
OUT=$(run --pr 7 --block ac --dry-run --body-file "$WORK/risk.md"); has "dry run prints the body" "$OUT" "<!-- sb:ac -->"
hasnt "dry run edits nothing" "$(cat "$GH_LOG")" "pr edit"

echo "── skeleton"
SK=$("$SCRIPT" --skeleton)
for b in status problem solution ac history visual risk; do has "skeleton has $b" "$SK" "<!-- sb:$b -->"; done

echo "── time in config timezone"
echo '{"timezone":"UTC"}' > "$WORK/cfg.json"
has "time carries the zone" "$("$SCRIPT" --time --config "$WORK/cfg.json")" "UTC"

printf '\n%s passed, %s failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
