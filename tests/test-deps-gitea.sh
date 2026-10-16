#!/usr/bin/env bash
# Tests super-board-deps.sh --forge gitea (the --deps composite of
# super-board-gitea-read.py) against the offline tea stub. No network.
# The parser itself stays covered by test-deps.sh; this pins the gitea feed:
# open issues + last-8 comments in the GraphQL node shape.
set -euo pipefail
cd "$(dirname "$0")"
KIT="$PWD/.."
DEPS="$KIT/scripts/super-board-deps.sh"
STUB="$KIT/evals/_stubs/bin/tea"
TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT
fail() { echo "FAIL: $1" >&2; exit 1; }
pass=0; ok() { pass=$((pass + 1)); echo "  ✅ $1"; }

mkdir -p "$TMP/.git"
cat > "$TMP/.git/tea-state.json" <<'EOF'
{"issues":[
  {"id":101,"number":1,"title":"Free card","state":"open","labels":[],
   "body":"intro\n\n## Blocked by\n\n- None."},
  {"id":102,"number":2,"title":"Waiting card","state":"open","labels":[],
   "body":"intro\n\n## Blocked by\n\n- #1"},
  {"id":103,"number":3,"title":"Parked card","state":"open","labels":[{"id":5,"name":"needs-you"}],
   "body":"intro\n\n## Blocked by\n\n- None.",
   "_parked":true},
  {"id":104,"number":4,"title":"Done card","state":"closed","labels":[],"body":"x"}],
 "pulls":[],"labels":[{"id":5,"name":"needs-you"}],"projects":[],"columns":[],
 "comments":{"3":[{"id":1,"body":"[orchestrator] [block] 🙋\nReason tag: 🙋 needs a human\nblocked-by: -","user":{"login":"bot"},"created_at":"2026-01-02T00:00:00Z","updated_at":"2026-01-02T00:00:00Z"}]},
 "writes":0}
EOF
if [ -x "/c/Program Files/Git/usr/bin/bash.exe" ]; then
  BASH_EXE="C:/Program Files/Git/usr/bin/bash.exe"
else
  BASH_EXE="bash"
fi
export SB_GITEA_TEA="\"$BASH_EXE\" $(cygpath -m "$STUB" 2>/dev/null || echo "$STUB")" \
       SB_GITHUB_HALT_FILE="$TMP/halt.json" SB_GITEA_RETRY_DELAY=0

OUT=$(cd "$TMP" && bash "$DEPS" --forge gitea --repo example/shop) || fail "deps exit: $OUT"

echo "$OUT" | jq -e '."1".runnable == true' >/dev/null || fail "free card not runnable: $OUT"
echo "$OUT" | jq -e '."2".runnable == false and (."2".openBlockers == [1])' >/dev/null \
  || fail "waiting card: $(echo "$OUT" | jq -c '."2"')"
echo "$OUT" | jq -e '."3".needsYou == true and ."3".humanGated == true and ."3".runnable == false' >/dev/null \
  || fail "parked card: $(echo "$OUT" | jq -c '."3"')"
echo "$OUT" | jq -e 'has("4") | not' >/dev/null || fail "closed issue leaked into the graph"
ok "gitea deps: runnable, blocked-by, needs-you comment line, closed excluded"

echo "test-deps-gitea: $pass passed"
