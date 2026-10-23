#!/usr/bin/env bash
# Tests scripts/super-board-agy-permissions.py: the rules a headless Antigravity lane needs,
# written once into the agy settings file without touching anything else. No agy binary needed.
set -euo pipefail
cd "$(dirname "$0")"
P="../scripts/super-board-agy-permissions.py"
PASS=0
fail() { echo "FAIL: $1" >&2; exit 1; }
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
S="$T/settings.json"
mkdir -p "$T/repo/.claude"

# 1 — dry run on a missing file: the lane profile (allow *) plus the deny rules, nothing written.
OUT=$(python3 "$P" --repo "$T/repo" --settings "$S")
echo "$OUT" | grep -q '^+ allow command(\*)$' || fail "dry run must offer command(*): $OUT"
echo "$OUT" | grep -q '^+ allow write_file(\*)$' || fail "dry run must offer write_file(*)"
echo "$OUT" | grep -q '^+ deny  command(regex:.*gh.*auth' || fail "dry run must deny gh auth"
echo "$OUT" | grep -q '^+ deny  read_file(.env)$' || fail "dry run must deny reading .env"
echo "$OUT" | grep -q '^dry run:' || fail "dry run must say so"
[ ! -e "$S" ] || fail "dry run must write nothing"
PASS=$((PASS + 1))

# 2 — apply keeps the other keys, writes allow and deny once, and backs the file up.
printf '{"colorScheme":"dark","permissions":{"allow":["command(git status)"]},"trustedWorkspaces":["/x"]}\n' > "$S"
python3 "$P" --repo "$T/repo" --settings "$S" --apply | grep -q '✓ .* added to' || fail "apply must report what it added"
jq -e '.colorScheme == "dark" and .trustedWorkspaces == ["/x"]' "$S" >/dev/null || fail "apply must keep the other keys"
jq -e '.permissions.allow == ["command(git status)", "command(*)", "read_file(*)", "write_file(*)"]' "$S" >/dev/null || fail "allow list wrong: $(cat "$S")"
jq -e '(.permissions.deny | length) > 8 and (.permissions.deny | index("read_file(.env)")) != null' "$S" >/dev/null || fail "deny list missing: $(cat "$S")"
ls "$T"/settings.json.bak-* >/dev/null 2>&1 || fail "apply must back the file up"
PASS=$((PASS + 1))

# 3 — a second apply adds nothing and says so.
OUT=$(python3 "$P" --repo "$T/repo" --settings "$S" --apply)
echo "$OUT" | grep -q 'every board rule already present' || fail "second apply must be a no-op: $OUT"
[ "$(jq '.permissions.allow | length' "$S")" = 4 ] || fail "second apply duplicated rules"
PASS=$((PASS + 1))

# 4 — --from-allowlist converts the Claude rules to regex command rules that match on every OS.
printf '{"permissions":{"allow":["Bash(gh pr view:*)","Bash(npm test)","Read(**)","Bash(git worktree:*)"]}}\n' > "$T/repo/.claude/settings.json"
OUT=$(python3 "$P" --repo "$T/repo" --settings "$T/none.json" --from-allowlist --verbose)
echo "$OUT" | grep -qF '+ allow command(regex:(?s)gh\ pr\ view(\s.*)?)' || fail "Bash prefix rule must become a regex rule: $OUT"
echo "$OUT" | grep -qF '+ allow command(regex:(?s)npm\ test(\s.*)?)' || fail "exact Bash rule must become a regex rule: $OUT"
echo "$OUT" | grep -q 'skipped (no Antigravity twin): Read(\*\*)' || fail "--verbose must list the skipped rule: $OUT"
echo "$OUT" | grep -q '^+ allow command(\*)$' && fail "--from-allowlist must not add command(*)"
echo "$OUT" | grep -q '^+ allow write_file(\*)$' || fail "--from-allowlist still allows workspace-adjacent file writes"
PASS=$((PASS + 1))

# 5 — --add appends a rule as written; a malformed one is refused with 64.
python3 "$P" --repo "$T/repo" --settings "$S" --add 'command(./gradlew)' --apply >/dev/null
jq -e '.permissions.allow | index("command(./gradlew)") != null' "$S" >/dev/null || fail "--add rule missing"
rc=0; python3 "$P" --repo "$T/repo" --settings "$S" --add 'gradlew' >/dev/null 2>&1 || rc=$?
[ "$rc" = 64 ] || fail "malformed --add must exit 64, got $rc"
PASS=$((PASS + 1))

# 6 — an invalid settings file is left untouched, exit 2.
printf '{not json' > "$T/bad.json"
rc=0; python3 "$P" --repo "$T/repo" --settings "$T/bad.json" --apply >/dev/null 2>&1 || rc=$?
[ "$rc" = 2 ] || fail "invalid settings must exit 2, got $rc"
[ "$(cat "$T/bad.json")" = '{not json' ] || fail "invalid settings must be left untouched"
PASS=$((PASS + 1))

# 7 — a settings file agy rewrote with a UTF-8 BOM is read all the same and rewritten clean by --apply.
printf '\xef\xbb\xbf{"permissions":{"allow":["command(*)"]}}\n' > "$T/bom.json"
OUT=$(python3 "$P" --repo "$T/repo" --settings "$T/bom.json")
echo "$OUT" | grep -q 'starts with a UTF-8 BOM' || fail "dry run must warn about the BOM: $OUT"
python3 "$P" --repo "$T/repo" --settings "$T/bom.json" --apply | grep -q 'BOM stripped' || fail "apply must say it stripped the BOM"
[ "$(head -c 1 "$T/bom.json")" = "{" ] || fail "apply must rewrite the file without a BOM"
jq -e '.permissions.allow | index("command(*)") != null' "$T/bom.json" >/dev/null || fail "the rules must survive the rewrite"
PASS=$((PASS + 1))

echo "PASS: test-agy-permissions.sh ($PASS scenarios)"
