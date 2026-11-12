#!/usr/bin/env bash
# Tests scripts/super-board-pr-body.sh — one marker block rewritten, the rest
# untouched, nothing written when the PR head moved. `gh` is a stub on PATH.
#
#   bash tests/test-pr-body.sh
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SCRIPT="$REPO_ROOT/scripts/super-board-pr-body.sh"
WORK="$(mktemp -d)"
export SB_GITHUB_RETRY_DELAY=0 SB_GITHUB_HALT_FILE="$WORK/halt.json"
trap 'rm -rf "$WORK"' EXIT

PASS=0; FAIL=0
ok()  { PASS=$((PASS + 1)); printf '  ✅ %s\n' "$1"; }
bad() { FAIL=$((FAIL + 1)); printf '  ❌ %s\n     expected: %s\n     actual:   %s\n' "$1" "$2" "$3"; }
is()  { [ "$2" = "$3" ] && ok "$1" || bad "$1" "$2" "$3"; }
has() { case "$2" in *"$3"*) ok "$1" ;; *) bad "$1" "contains: $3" "$2" ;; esac; }
hasnt() { case "$2" in *"$3"*) bad "$1" "no '$3'" "found it" ;; *) ok "$1" ;; esac; }

# gh stub (REST): GET pulls/N serves $WORK/body.md, $HEAD_OID and branch $HEAD_REF through the
# caller's --jq; PATCH pulls/N --input - stores the new body.
cat > "$WORK/gh" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$GH_LOG"
case "$*" in
  "api -X PATCH repos/{owner}/{repo}/pulls/"*" --input -") jq -j .body > "$BODY" ;;
  "api repos/{owner}/{repo}/pulls/"*)
    Q=.; while [ $# -gt 0 ]; do [ "$1" = --jq ] && Q="$2"; shift; done
    jq -n --arg h "$HEAD_OID" --arg r "${HEAD_REF:-}" --rawfile b "$BODY" '{head: {sha: $h, ref: $r}, body: $b}' | jq "$Q" ;;
  *) echo "unexpected gh call: $*" >&2; exit 1 ;;
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

# Runs outside any git checkout, so the caller's own branch never counts as a card worktree.
run() { : > "$GH_LOG"; (cd "$WORK" && "$SCRIPT" "$@" 2>"$WORK/err"); }

echo "── replace one block, keep the rest"
is  "replace reports updated" "updated" "$(run --pr 7 --block status --expect-head 3f9c2a1 --body-file "$WORK/status.md")"
has "new status written"      "$(cat "$BODY")" "✅ Merged"
hasnt "old status gone"       "$(cat "$BODY")" "In QA"
has "problem block untouched" "$(cat "$BODY")" '- **Where:** `/x`'

echo "── idempotent"
is  "same content twice is a no-op" "unchanged" "$(run --pr 7 --block status --expect-head 3f9c2a1 --body-file "$WORK/status.md")"
hasnt "no edit call on a no-op"     "$(cat "$GH_LOG")" "PATCH"

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

echo "── a folded history keeps new rows inside the fold"
cp "$BODY" "$WORK/unfolded.md"
cat > "$BODY" <<'FOLD'
<!-- sb:status -->
> [!NOTE]
> ⏳ In QA · Closes #7 · head `3f9c2a1`
<!-- /sb:status -->

<!-- sb:history -->
<details><summary>Iteration history</summary>

| Lane | Done | Time | Details |
|---|---|---|---|
| 🔨 builder | ✅ | Oct 2, 10:02 EDT | draft |

</details>
<!-- /sb:history -->
FOLD
run --pr 7 --block history --expect-head 3f9c2a1 --append-file "$WORK/row.md" >/dev/null
ROW=$(grep -n 'runs/issue-7-qa-v1/' "$BODY" | cut -d: -f1); END=$(grep -n '^</details>$' "$BODY" | cut -d: -f1)
[ -n "$ROW" ] && [ "$ROW" -lt "$END" ] && ok "row lands above </details>" || bad "row lands above </details>" "row < $END" "${ROW:-none}"
is  "blank line kept before </details>" "" "$(sed -n "$((END - 1))p" "$BODY")"
is  "folded re-append is a no-op" "unchanged" "$(run --pr 7 --block history --expect-head 3f9c2a1 --append-file "$WORK/row.md")"
cp "$WORK/unfolded.md" "$BODY"

echo "── refuses when the head moved"
cp "$BODY" "$WORK/before.md"
RC=0; run --pr 7 --block status --expect-head deadbee --body-file "$WORK/risk.md" >/dev/null || RC=$?
is  "moved head exits 6" "6" "$RC"
hasnt "no edit on a moved head" "$(cat "$GH_LOG")" "PATCH"
is  "body unchanged" "$(cat "$WORK/before.md")" "$(cat "$BODY")"

echo "── usage"
RC=0; run --pr 7 --block status --body-file "$WORK/risk.md" >/dev/null || RC=$?; is "expect-head required" 64 "$RC"
RC=0; run --pr 7 --block nope --expect-head x --body-file "$WORK/risk.md" >/dev/null || RC=$?; is "block is an enum" 64 "$RC"
RC=0; run --pr 7 --block ac --expect-head x >/dev/null || RC=$?; is "content file required" 64 "$RC"
OUT=$(run --pr 7 --block ac --dry-run --body-file "$WORK/risk.md"); has "dry run prints the body" "$OUT" "<!-- sb:ac -->"
hasnt "dry run edits nothing" "$(cat "$GH_LOG")" "PATCH"

echo "── the status block belongs to this PR's card"
# Parallel lanes once shared a /tmp status file: one lane wrote another card's
# `Closes #N` and head onto its own PR, and the approval check refused the human's approval.
export HEAD_REF=issue-7-fix-x
cp "$BODY" "$WORK/before.md"
OTHER='> [!NOTE]\n> ⏳ In review · round 1 · Closes #8 · head `bbbbbbb`\n'
printf "$OTHER" > "$WORK/other.md"
RC=0; run --pr 7 --block status --expect-head 3f9c2a1 --body-file "$WORK/other.md" >/dev/null || RC=$?
is  "another card's status exits 65" "65" "$RC"
has "says it belongs to another PR" "$(cat "$WORK/err")" "another PR"
hasnt "no edit for another card's status" "$(cat "$GH_LOG")" "PATCH"
is  "body unchanged on refusal" "$(cat "$WORK/before.md")" "$(cat "$BODY")"
printf '> [!NOTE]\n> ⏳ In QA · Closes #8 · head `3f9c2a1`\n' > "$WORK/other.md"
RC=0; run --pr 7 --block status --expect-head 3f9c2a1 --body-file "$WORK/other.md" >/dev/null || RC=$?
is  "another card's Closes with the right head exits 65" "65" "$RC"
has "names the other card" "$(cat "$WORK/err")" "#8"
printf '> [!NOTE]\n> ⏳ In QA · Closes #7 · head `bbbbbbb`\n' > "$WORK/other.md"
RC=0; run --pr 7 --block status --expect-head 3f9c2a1 --body-file "$WORK/other.md" >/dev/null || RC=$?
is  "another PR's head exits 65" "65" "$RC"
printf '> [!NOTE]\n> ⏳ In review · Closes #7 · head `3f9c2a1`\n' > "$WORK/own.md"
is  "own status is written" "updated" "$(run --pr 7 --block status --expect-head 3f9c2a1 --body-file "$WORK/own.md")"
has "own Closes kept once" "$(cat "$BODY")" "⏳ In review · Closes #7 · head"
printf '> [!NOTE]\n> ⏳ In QA · head `3f9c2a1`\n' > "$WORK/own.md"
run --pr 7 --block status --expect-head 3f9c2a1 --body-file "$WORK/own.md" >/dev/null
has "status without Closes gets its card" "$(cat "$BODY")" '⏳ In QA · head `3f9c2a1` · Closes #7'
run --pr 7 --block status --expect-head 3f9c2a1 --body-file "$WORK/status.md" >/dev/null
has "merged line gets its card" "$(cat "$BODY")" '✅ Merged · `9c41e07` · Closes #7'
printf '> [!WARNING]\n> 🛑 Blocked · needs you · head `3f9c2a1`\n> needs-you: `npm run db:migrate:live`\n' > "$WORK/own.md"
run --pr 7 --block status --expect-head 3f9c2a1 --body-file "$WORK/own.md" >/dev/null
has "blocked line gets its card" "$(cat "$BODY")" '🛑 Blocked · needs you · head `3f9c2a1` · Closes #7'
has "needs-you line left as written" "$(cat "$BODY")" '> needs-you: `npm run db:migrate:live`
<!-- /sb:status -->'
printf '> [!NOTE]\n> ⏳ In QA · Refs #7 · head `3f9c2a1`\n' > "$WORK/own.md"
run --pr 7 --block status --expect-head 3f9c2a1 --body-file "$WORK/own.md" >/dev/null
has "partial PR keeps Refs" "$(cat "$BODY")" "⏳ In QA · Refs #7 · head"
hasnt "partial PR gets no Closes" "$(sed -n '/sb:status -->/,/\/sb:status/p' "$BODY")" "Closes"
printf '## Problem\n- Closes #8 is only mentioned in prose\n' > "$WORK/prose.md"
is  "other blocks are not checked" "updated" "$(run --pr 7 --block problem --expect-head 3f9c2a1 --body-file "$WORK/prose.md")"

echo "── --issue and the card worktree must match the PR's card"
cp "$BODY" "$WORK/before.md"
RC=0; run --pr 7 --issue 8 --block status --expect-head 3f9c2a1 --body-file "$WORK/own.md" >/dev/null || RC=$?
is  "--issue naming another card exits 65" "65" "$RC"
has "says whose PR it is" "$(cat "$WORK/err")" "the PR for #7"
is  "body unchanged on a wrong --issue" "$(cat "$WORK/before.md")" "$(cat "$BODY")"
is  "--issue naming this card is fine" "unchanged" "$(run --pr 7 --issue 7 --block status --expect-head 3f9c2a1 --body-file "$WORK/own.md")"
git init --quiet "$WORK/wt" && git -C "$WORK/wt" symbolic-ref HEAD refs/heads/issue-8-other
RC=0; (cd "$WORK/wt" && "$SCRIPT" --pr 7 --block status --expect-head 3f9c2a1 --body-file "$WORK/own.md" >/dev/null 2>"$WORK/err") || RC=$?
is  "a card worktree on another card exits 65" "65" "$RC"
has "names the worktree branch" "$(cat "$WORK/err")" "issue-8-other"
RC=0; run --pr 7 --issue x8 --block status --expect-head 3f9c2a1 --body-file "$WORK/own.md" >/dev/null || RC=$?
is  "--issue is a number" "64" "$RC"
export HEAD_REF=tooling-fix
printf '> [!NOTE]\n> ⏳ In review · head `3f9c2a1`\n' > "$WORK/own.md"
run --pr 7 --issue 9 --block status --expect-head 3f9c2a1 --body-file "$WORK/own.md" >/dev/null
has "a branch without a card takes --issue" "$(cat "$BODY")" '⏳ In review · head `3f9c2a1` · Closes #9'
unset HEAD_REF

echo "── skeleton"
SK=$("$SCRIPT" --skeleton)
for b in status problem solution ac history visual risk; do has "skeleton has $b" "$SK" "<!-- sb:$b -->"; done
has "skeleton folds the history" "$SK" "<details><summary>Iteration history</summary>"

echo "── time in config timezone"
echo '{"timezone":"UTC"}' > "$WORK/cfg.json"
has "time carries the zone" "$("$SCRIPT" --time --config "$WORK/cfg.json")" "UTC"

printf '\n%s passed, %s failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
