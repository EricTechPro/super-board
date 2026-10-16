#!/usr/bin/env bash
# Tests super-board-pr-body.sh's gitea branch against the offline tea stub:
# one marker block rewritten, head pin enforced (exit 6), idempotent no-op,
# dry-run touches nothing. No network. The github branch stays in test-pr-body.sh.
set -euo pipefail
cd "$(dirname "$0")"
KIT="$PWD/.."
PRBODY="$KIT/scripts/super-board-pr-body.sh"
STUB="$KIT/evals/_stubs/bin/tea"
TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT
fail() { echo "FAIL: $1" >&2; exit 1; }
pass=0; ok() { pass=$((pass + 1)); echo "  ✅ $1"; }

SHA=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
mkdir -p "$TMP/.git"
cat > "$TMP/.git/tea-state.json" <<EOF
{"issues":[],
 "pulls":[{"number":7,"title":"Fix","state":"open","merged":false,
   "head":{"ref":"fix","sha":"$SHA"},
   "body":"<!-- sb:status -->\nold status\n<!-- /sb:status -->\n\n<!-- sb:problem -->\nkeep me\n<!-- /sb:problem -->"}],
 "labels":[],"projects":[],"columns":[],"comments":{},"writes":0}
EOF
if [ -x "/c/Program Files/Git/usr/bin/bash.exe" ]; then
  BASH_EXE="C:/Program Files/Git/usr/bin/bash.exe"
else
  BASH_EXE="bash"
fi
export SB_GITEA_TEA="\"$BASH_EXE\" $(cygpath -m "$STUB" 2>/dev/null || echo "$STUB")" \
       SB_FORGE=gitea SB_FORGE_HOST="http://localhost:3000" \
       SB_GITHUB_HALT_FILE="$TMP/halt.json" SB_GITEA_RETRY_DELAY=0
printf 'building #7\n- did things\n' > "$TMP/block.md"

run() { (cd "$TMP" && bash "$PRBODY" --repo example/shop "$@"); }
body_now() { jq -r '.pulls[0].body' "$TMP/.git/tea-state.json"; }

# 1 — replaces only the named block, keeps the others byte-identical.
OUT=$(run --pr 7 --block status --expect-head "$SHA" --body-file "$TMP/block.md") || fail "update run"
[ "$OUT" = updated ] || fail "expected 'updated', got: $OUT"
body_now | grep -q 'building #7' || fail "block not written: $(body_now)"
body_now | grep -q 'keep me' || fail "other block clobbered: $(body_now)"
body_now | grep -q 'old status' && fail "old content survived"
ok "one block rewritten, others untouched"

# 2 — same content again is a no-op.
OUT=$(run --pr 7 --block status --expect-head "$SHA" --body-file "$TMP/block.md") || fail "rerun"
[ "$OUT" = unchanged ] || fail "expected 'unchanged', got: $OUT"
ok "idempotent re-run reports unchanged"

# 3 — a moved head refuses the edit (exit 6), body untouched.
BEFORE=$(body_now)
RC=0; run --pr 7 --block status --expect-head bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb \
  --body-file "$TMP/block.md" >/dev/null 2>&1 || RC=$?
[ "$RC" = 6 ] || fail "stale head should exit 6, got $RC"
[ "$(body_now)" = "$BEFORE" ] || fail "stale-head run wrote anyway"
ok "head pin: stale expect-head → exit 6, no write"

# 4 — dry-run prints the new body and writes nothing.
printf 'dry content\n' > "$TMP/block.md"
W_BEFORE=$(wc -l < "$TMP/.git/tea-writes.log" 2>/dev/null | tr -d ' ' || echo 0)
OUT=$(run --pr 7 --block status --expect-head "$SHA" --body-file "$TMP/block.md" --dry-run) || fail "dry run"
grep -q 'dry content' <<<"$OUT" || fail "dry-run output missing the new block"
[ "$(body_now)" = "$BEFORE" ] || fail "dry-run wrote to the server"
W_AFTER=$(wc -l < "$TMP/.git/tea-writes.log" 2>/dev/null | tr -d ' ' || echo 0)
[ "$W_BEFORE" = "$W_AFTER" ] || fail "dry-run logged a write: $(tail -1 "$TMP/.git/tea-writes.log")"
ok "dry-run prints, never writes"

# 5 — append mode adds a row inside the block once (history rows).
printf '| row one |\n' > "$TMP/block.md"
run --pr 7 --block history --expect-head "$SHA" --append-file "$TMP/block.md" >/dev/null || fail "append create"
run --pr 7 --block history --expect-head "$SHA" --append-file "$TMP/block.md" >/dev/null || fail "append twice"
[ "$(body_now | grep -c 'row one')" = 1 ] || fail "append duplicated the row: $(body_now)"
ok "append is idempotent per row"

echo "test-pr-body-gitea: $pass passed"
