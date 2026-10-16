#!/usr/bin/env bash
# Tests super-board-card.sh's gitea branch against the offline tea stub.
# No network. Pins the same promises as test-card.sh: a warm move is ONE
# write, a cold one is two reads plus the write, an unknown column re-reads
# once then exits 3, and a rejected read halts (79) instead of retrying forever.
set -euo pipefail
cd "$(dirname "$0")"
CARD="$PWD/../scripts/super-board-card.sh"
STUB="$PWD/../evals/_stubs/bin/tea"
TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT
fail() { echo "FAIL: $1" >&2; exit 1; }
pass=0; ok() { pass=$((pass + 1)); echo "  ✅ $1"; }

mkdir -p "$TMP/.git"
cat > "$TMP/.git/tea-state.json" <<'EOF'
{"issues":[
   {"id":101,"number":1,"title":"Cart bug","body":"x","state":"open","labels":[{"id":3,"name":"bug"}],"_column":10},
   {"id":102,"number":2,"title":"Ship it","body":"y","state":"open","labels":[],"_column":11}],
 "pulls":[],
 "labels":[{"id":3,"name":"bug","color":"#d73a4a"}],
 "projects":[{"id":4,"title":"Board"}],
 "columns":[{"id":10,"title":"Ready"},{"id":11,"title":"Done"}],
 "comments":{},"writes":0}
EOF
cat > "$TMP/cfg.json" <<'EOF'
{"forge":"gitea","forge_host":"http://localhost:3000",
 "project":{"owner":"example","title":"Board","number":4},
 "repo":{"path":".","remote":"http://localhost:3000/example/shop.git"}}
EOF
cat > "$TMP/hang-tea" <<'EOF'
#!/usr/bin/env bash
echo "tea $*" >> "$PWD/.git/tea-calls.log"
echo "ServerError: 404 not found" >&2
exit 1
EOF

# SB_GITEA_TEA names the tea executable; on Windows an extensionless PATH stub
# loses to the real tea.exe in CreateProcess, so run the stub through Git bash
# by absolute path (forward slashes; both shlex and bash word-splitting agree).
if [ -x "/c/Program Files/Git/usr/bin/bash.exe" ]; then
  BASH_EXE="C:/Program Files/Git/usr/bin/bash.exe"
else
  BASH_EXE="bash"
fi
export SB_GITEA_TEA="\"$BASH_EXE\" $(cygpath -m "$STUB" 2>/dev/null || echo "$STUB")" \
       SB_CARD_CACHE_DIR="$TMP/cache" \
       SB_GITHUB_HALT_FILE="$TMP/halt.json" SB_GITEA_RETRY_DELAY=0
card() { (cd "$TMP" && "$CARD" --config "$TMP/cfg.json" "$@"); }
calls() { grep -c "$1" "$TMP/.git/tea-calls.log" 2>/dev/null || true; }
writes() { grep -c "$1" "$TMP/.git/tea-writes.log" 2>/dev/null || true; }
reset_logs() { : > "$TMP/.git/tea-calls.log"; : > "$TMP/.git/tea-writes.log"; }

# 1 — cold move: fields read + items read + ONE move write, right column.
reset_logs
OUT=$(card move 1 Done) || fail "cold move"
[ "$OUT" = "moved #1 → Done" ] || fail "cold move output: $OUT"
[ "$(writes move)" = 1 ] || fail "cold move writes: $(cat "$TMP/.git/tea-writes.log")"
grep move "$TMP/.git/tea-writes.log" | grep -q '"column_id":11' || fail "wrong column: $(cat "$TMP/.git/tea-writes.log")"
jq -e '(.issues[] | select(.id==101) | ._column) == 11' "$TMP/.git/tea-state.json" >/dev/null || fail "state not moved"
ok "cold move = 2 reads + 1 move, right column"

# 2 — warm move: ids and the item id are cached from test 1, so it is ONE write.
reset_logs
card move 1 Ready >/dev/null || fail "warm move"
[ "$(calls 'tea api')" = 1 ] && [ "$(writes move)" = 1 ] || fail "warm move calls: $(cat "$TMP/.git/tea-calls.log")"
ok "warm move = 1 write"

# 3 — cache shape matches the github one (board-<owner>-<number>.json).
[ -f "$TMP/cache/board-example-4.json" ] || fail "cache file missing"
jq -e '.items["1"] == "gitea:101" and .options.Done == "11"' "$TMP/cache/board-example-4.json" >/dev/null \
  || fail "cache content: $(cat "$TMP/cache/board-example-4.json")"
ok "cache holds gitea ids in the github cache shape"

# 4 — a column the board does not have: re-read once, exit 3, no write.
reset_logs
RC=0; card move 1 Shipping >/dev/null 2>&1 || RC=$?
[ "$RC" = 3 ] || fail "unknown column should exit 3, got $RC"
[ "$(writes POST)" = 0 ] || fail "unknown column must not write"
ok "unknown column → re-read, exit 3, no write"

# 5 — an issue that is not on the board: exit 3.
reset_logs
RC=0; card move 999 Ready >/dev/null 2>&1 || RC=$?
[ "$RC" = 3 ] || fail "off-board issue should exit 3, got $RC"
ok "off-board issue → exit 3"

# 6 — status and items verbs serve the normalized shapes.
[ "$(card status 2)" = "Done" ] || fail "status: $(card status 2)"
card items | jq -e '.totalCount == 2 and (.items[0].content.repository == "example/shop")' >/dev/null \
  || fail "items shape: $(card items)"
card ids | jq -e '.options.Ready == "10"' >/dev/null || fail "ids: $(card ids)"
ok "status / items / ids verbs"

# 7 — a rejected read (permanent 404) halts on the first attempt: exit 79.
rm -f "$TMP/halt.json" "$TMP/cache/board-example-4.json"
reset_logs
export SB_GITEA_TEA="\"$BASH_EXE\" $(cygpath -m "$TMP/hang-tea" 2>/dev/null || echo "$TMP/hang-tea")"
RC=0; card items >/dev/null 2>&1 || RC=$?
[ "$RC" = 79 ] || fail "permanent error should halt 79, got $RC"
[ -f "$TMP/halt.json" ] || fail "halt file missing"
[ "$(calls 'tea api')" = 1 ] || fail "permanent error retried: $(cat "$TMP/.git/tea-calls.log")"
ok "permanent read error → halt (79), no retry"

echo "test-card-gitea: $pass passed"
