#!/usr/bin/env bash
# Tests super-board-status.py's gitea branch end-to-end against the offline tea
# stub: one normalized board read, Blocked reason-tags from comments, exit 0.
# No network. The github branch stays covered by test_status_parse.py + CI.
set -euo pipefail
cd "$(dirname "$0")"
STATUS="$PWD/../scripts/super-board-status.py"
STUB="$PWD/../evals/_stubs/bin/tea"
TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT
fail() { echo "FAIL: $1" >&2; exit 1; }
pass=0; ok() { pass=$((pass + 1)); echo "  ✅ $1"; }

mkdir -p "$TMP/.git" "$TMP/.claude/super-board/configs"
cat > "$TMP/.claude/super-board/configs/shop.json" <<'EOF'
{"forge":"gitea","forge_host":"http://localhost:3000",
 "project":{"owner":"example","title":"Board","number":4},
 "repo":{"path":".","remote":"http://localhost:3000/example/shop.git"},
 "base_branch":"main"}
EOF
echo shop > "$TMP/.claude/super-board/active"
cat > "$TMP/.git/tea-state.json" <<'EOF'
{"issues":[
   {"id":101,"number":1,"title":"Cart discount","body":"x","state":"open","labels":[{"id":3,"name":"feature"}],"_column":2},
   {"id":103,"number":3,"title":"Flaky checkout","body":"y","state":"open","labels":[{"id":4,"name":"bug"}],"_column":6},
   {"id":104,"number":4,"title":"Shipped thing","body":"z","state":"closed","labels":[],"_column":7}],
 "pulls":[],
 "labels":[{"id":3,"name":"feature"},{"id":4,"name":"bug"}],
 "projects":[{"id":4,"title":"Board"}],
 "columns":[{"id":1,"title":"Backlog"},{"id":2,"title":"Ready"},{"id":3,"title":"Building"},
            {"id":4,"title":"QA"},{"id":5,"title":"Review"},{"id":6,"title":"Blocked"},{"id":7,"title":"Done"}],
 "comments":{"3":[{"id":1,"body":"⚙ upstream API down — waiting on #9","user":{"login":"bot"},
                   "created_at":"2026-01-02T00:00:00Z","updated_at":"2026-01-02T00:00:00Z"}]},
 "writes":0}
EOF

if [ -x "/c/Program Files/Git/usr/bin/bash.exe" ]; then
  BASH_EXE="C:/Program Files/Git/usr/bin/bash.exe"
else
  BASH_EXE="bash"
fi
export SB_GITEA_TEA="\"$BASH_EXE\" $(cygpath -m "$STUB" 2>/dev/null || echo "$STUB")" \
       SB_GITHUB_HALT_FILE="$TMP/halt.json" SB_GITEA_RETRY_DELAY=0

OUT=$(cd "$TMP" && python3 "$STATUS" 2>"$TMP/err.txt") || fail "status exit: $(cat "$TMP/err.txt")"

grep -q 'super-board · Board' <<<"$OUT" || fail "header missing: $(head -5 <<<"$OUT")"
ok "renders the snapshot header"

# Blocked lane shows #3 and its reason-tag body.
grep -q '#3' <<<"$OUT" || fail "blocked card missing"
grep -q 'infra / tooling' <<<"$OUT" || fail "reason tag missing: $(grep -A3 -i block <<<"$OUT")"
ok "Blocked lane + reason tag from gitea comments"

# Ready and Done lanes carry their cards.
grep -q '#1' <<<"$OUT" || fail "ready card missing"
grep -q '#4' <<<"$OUT" || fail "done card missing"
ok "cards render in their columns"

# A halted forge read must surface as 79, not a fabricated snapshot.
echo '{"reason":"test halt","attempts":3,"at":0,"operation":null}' > "$TMP/halt.json"
RC=0; (cd "$TMP" && python3 "$STATUS") >/dev/null 2>&1 || RC=$?
[ "$RC" = 79 ] || fail "halted read should exit 79, got $RC"
rm -f "$TMP/halt.json"
ok "halt file propagates as exit 79"

echo "test-status-gitea: $pass passed"
