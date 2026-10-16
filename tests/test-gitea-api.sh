#!/usr/bin/env bash
# Tests super-board-gitea-api.sh against the offline tea stub (evals/_stubs/bin/tea).
# No network. The helper's promises: JSON body building, {owner}/{repo} expansion
# via GITEA_REPO, -i headers on stderr only, and a bounded lifetime for a hung tea.
set -euo pipefail
cd "$(dirname "$0")"
SRC="$PWD/../scripts"
STUB="$PWD/../evals/_stubs/bin/tea"
TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT
fail() { echo "FAIL: $1" >&2; exit 1; }
pass=0; ok() { pass=$((pass + 1)); echo "  ✅ $1"; }

mkdir -p "$TMP/.git"
cd "$TMP"
export GITEA_REPO="example/shop" SB_GITEA_TEA="bash $STUB"
cat > .git/tea-state.json <<'EOF'
{"issues":[{"id":101,"number":1,"title":"Cart bug","body":"x","state":"open","labels":[]}],
 "pulls":[],
 "labels":[{"id":3,"name":"bug","color":"#d73a4a"}],
 "projects":[{"id":4,"title":"Board"}],
 "columns":[{"id":10,"title":"Ready"},{"id":11,"title":"Done"}],
 "comments":{},"writes":0}
EOF
# shellcheck source=/dev/null
source "$SRC/super-board-gitea-api.sh"

# 1 — POST with a JSON body creates and echoes the issue.
OUT=$(sb_gitea_api POST 'repos/{owner}/{repo}/issues' '{"title":"New bug","body":"b"}') || fail "create issue"
[ "$(jq -r .title <<<"$OUT")" = "New bug" ] || fail "echo: $OUT"
[ "$(jq -r .number <<<"$OUT")" = 2 ] || fail "number: $OUT"
jq -e '.issues | length == 2' .git/tea-state.json >/dev/null || fail "state not written"
ok "POST issues → created, state updated"

# 2 — label helpers: attach existing, create missing with the shared color.
sb_gitea_label_add 1 bug >/dev/null || fail "attach existing label"
jq -e '(.issues[] | select(.number==1) | .labels | map(.name)) == ["bug"]' .git/tea-state.json >/dev/null \
  || fail "label not attached: $(jq -c '.issues[0].labels' .git/tea-state.json)"
sb_gitea_label_add 1 feature >/dev/null || fail "create+attach missing label"
jq -e 'any(.labels[]; .name=="feature" and .color=="#1d76db")' .git/tea-state.json >/dev/null \
  || fail "feature label missing/wrong color: $(jq -c .labels .git/tea-state.json)"
ok "label_add attaches existing, creates missing with shared color"

# 3 — creating an existing label is refused by the server, and the pre-check
#     makes label_add idempotent instead.
sb_gitea_label_add 1 bug >/dev/null || fail "idempotent re-attach"
jq -e '(.issues[] | select(.number==1) | .labels | length) == 2' .git/tea-state.json >/dev/null \
  || fail "re-attach duplicated: $(jq -c '.issues[0].labels' .git/tea-state.json)"
ok "label_add is idempotent"

# 4 — headers go to stderr, body stays clean JSON on stdout.
ERR=$(sb_gitea_api_headers GET version 2>&1 >/dev/null) || fail "header probe"
OUT=$(sb_gitea_api_headers GET version 2>/dev/null) || fail "header probe body"
grep -q 'X-RateLimit-Remaining: 3597' <<<"$ERR" || fail "no rate headers: $ERR"
jq -e .version <<<"$OUT" >/dev/null || fail "body not clean JSON: $OUT"
ok "tea api -i → headers stderr, JSON stdout"

# 5 — the move endpoint (card.sh's gitea mutation).
sb_gitea_api POST 'repos/{owner}/{repo}/projects/4/issues/101/move' '{"column_id":11}' >/dev/null \
  || fail "move"
jq -e '(.issues[] | select(.id==101) | ._column) == 11' .git/tea-state.json >/dev/null || fail "not moved"
ok "POST move → column changed"

# 6 — a hung tea is killed by the timeout, not the worker.
cat > "$TMP/hang-tea" <<'EOF'
#!/usr/bin/env bash
sleep 30
EOF
export SB_GITEA_TEA="bash $TMP/hang-tea" SB_GITEA_TIMEOUT=1
RC=0; sb_gitea_api GET version >/dev/null 2>&1 || RC=$?
[ "$RC" != 0 ] || fail "hung tea should fail, not block"
unset SB_GITEA_TEA SB_GITEA_TIMEOUT
export SB_GITEA_TEA="bash $STUB"
ok "hung tea → bounded failure (rc=$RC)"

# 7 — the merge endpoint pins the head: a stale head_commit_id is refused (409),
#     the current one merges and records the merge commit.
jq '.pulls = [{"number":7,"title":"Fix","state":"open","merged":false,
               "head":{"ref":"fix","sha":"abc123"}}]' .git/tea-state.json > "$TMP/s2" && mv "$TMP/s2" .git/tea-state.json
RC=0; sb_gitea_api POST 'repos/{owner}/{repo}/pulls/7/merge' \
  '{"do":"squash","head_commit_id":"stale000"}' >/dev/null 2>&1 || RC=$?
[ "$RC" != 0 ] || fail "stale head_commit_id must be refused"
jq -e '.pulls[0].merged == false' .git/tea-state.json >/dev/null || fail "refused merge mutated state"
sb_gitea_api POST 'repos/{owner}/{repo}/pulls/7/merge' \
  '{"do":"squash","head_commit_id":"abc123","delete_branch_after_merge":true}' >/dev/null || fail "pinned merge"
jq -e '.pulls[0].merged == true and .pulls[0].state == "closed"' .git/tea-state.json >/dev/null \
  || fail "merge not recorded: $(jq -c .pulls .git/tea-state.json)"
ok "merge pins head_commit_id: stale refused, current merges"

# 8 — every write was logged for auditability.
[ "$(grep -c '^POST' .git/tea-writes.log)" -ge 4 ] || fail "write log: $(cat .git/tea-writes.log)"
ok "writes logged to tea-writes.log"

echo "test-gitea-api: $pass passed"
