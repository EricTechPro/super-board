#!/usr/bin/env bash
# Tests super-board-setup.py's gitea board commands (board-rank, board-migrate)
# against the offline tea stub. No network. The github halves stay covered by
# test-setup.sh; this suite pins the gitea output shapes onboard consumes.
set -euo pipefail
cd "$(dirname "$0")"
SETUP="$PWD/../scripts/super-board-setup.py"
STUB="$PWD/../evals/_stubs/bin/tea"
TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT
fail() { echo "FAIL: $1" >&2; exit 1; }
pass=0; ok() { pass=$((pass + 1)); echo "  ✅ $1"; }

mkdir -p "$TMP/.git"
if [ -x "/c/Program Files/Git/usr/bin/bash.exe" ]; then
  BASH_EXE="C:/Program Files/Git/usr/bin/bash.exe"
else
  BASH_EXE="bash"
fi
export SB_GITEA_TEA="\"$BASH_EXE\" $(cygpath -m "$STUB" 2>/dev/null || echo "$STUB")"

seed() { cat > "$TMP/.git/tea-state.json"; }

# ── board-rank ───────────────────────────────────────────────────────────────
seed <<'EOF'
{"issues":[{"id":101,"number":1,"title":"a","body":"","state":"open","labels":[],"_column":2}],
 "pulls":[],"labels":[],
 "projects":[{"id":4,"title":"Shop Board","html_url":"u4"},{"id":5,"title":"Empty","html_url":"u5"}],
 "columns":[{"id":1,"title":"Backlog","_project":4},{"id":2,"title":"Ready","_project":4},
            {"id":9,"title":"Todo","_project":5}],
 "comments":{},"writes":0}
EOF
OUT=$(cd "$TMP" && python3 "$SETUP" board-rank --owner example --repo example/shop --forge gitea) || fail "board-rank exit"
echo "$OUT" | jq -e '.boards | length == 2' >/dev/null || fail "boards: $OUT"
echo "$OUT" | jq -e '.boards[0].number == 4 and .boards[0].matches == 2' >/dev/null || fail "rank order: $OUT"
echo "$OUT" | jq -e '.boards[0].missing | index("Done")' >/dev/null || fail "missing columns: $OUT"
echo "$OUT" | jq -e '.recommend == null' >/dev/null || fail "recommend with 2 matches should be null: $OUT"
ok "board-rank gitea ranks repo projects by column match"

# ── board-migrate: adds columns + labels, moves Skipped → Done, removes it ───
seed <<'EOF'
{"issues":[
   {"id":101,"number":1,"title":"old bug","body":"","state":"open","labels":[{"id":8,"name":"bugfix"}],"_column":3},
   {"id":102,"number":2,"title":"ready thing","body":"","state":"open","labels":[],"_column":2}],
 "pulls":[],
 "labels":[{"id":8,"name":"bugfix","color":"#ff0000"}],
 "projects":[{"id":4,"title":"Shop Board","html_url":"u4"}],
 "columns":[{"id":2,"title":"Ready"},{"id":3,"title":"Skipped"},{"id":4,"title":"Done"}],
 "comments":{},"writes":0}
EOF
OUT=$(cd "$TMP" && python3 "$SETUP" board-migrate --owner example --number 4 --repo example/shop \
      --forge gitea --root "$TMP") || fail "board-migrate exit: $OUT"
echo "$OUT" | jq -e '.added_columns == ["Backlog","Building","QA","Review","Blocked"]' >/dev/null || fail "added_columns: $OUT"
echo "$OUT" | jq -e '(.labels_created | sort) == ["bug","feature","qa"]' >/dev/null || fail "labels_created: $OUT"
echo "$OUT" | jq -e '.skipped_moved == 1 and .skipped_removed == true' >/dev/null || fail "skipped handling: $OUT"
echo "$OUT" | jq -e '.labels_mapped == 1' >/dev/null || fail "old label mapping: $OUT"
jq -e '[.columns[].title] | (index("Backlog") != null) and (index("Skipped") == null)' \
  "$TMP/.git/tea-state.json" >/dev/null || fail "columns after migrate: $(jq -c '[.columns[].title]' "$TMP/.git/tea-state.json")"
jq -e '(.issues[] | select(.id==101) | ._column) == 4' "$TMP/.git/tea-state.json" >/dev/null \
  || fail "skipped card not moved to Done"
jq -e '(.issues[] | select(.id==101) | .labels | map(.name)) | (index("bug") != null) and (index("bugfix") == null)' \
  "$TMP/.git/tea-state.json" >/dev/null || fail "label conversion: $(jq -c '.issues[0].labels' "$TMP/.git/tea-state.json")"
[ -f "$TMP/.claude/super-board/migrations/gitea-board-4.json" ] || fail "snapshot missing"
ok "board-migrate gitea: columns, labels, Skipped→Done, snapshot"

# ── board-migrate is idempotent: re-running changes nothing ──────────────────
OUT2=$(cd "$TMP" && python3 "$SETUP" board-migrate --owner example --number 4 --repo example/shop \
       --forge gitea --root "$TMP") || fail "re-run exit: $OUT2"
echo "$OUT2" | jq -e '.added_columns == [] and .labels_created == [] and .skipped_moved == 0 and .labels_mapped == 0' >/dev/null \
  || fail "re-run not a no-op: $OUT2"
ok "board-migrate gitea re-run is a no-op"

# ── dry run writes nothing ───────────────────────────────────────────────────
seed <<'EOF'
{"issues":[],"pulls":[],"labels":[],
 "projects":[{"id":6,"title":"Fresh","html_url":"u6"}],
 "columns":[{"id":1,"title":"Todo"}],
 "comments":{},"writes":0}
EOF
OUT=$(cd "$TMP" && python3 "$SETUP" board-migrate --owner example --number 6 --repo example/shop \
      --forge gitea --root "$TMP" --dry-run --prune-empty) || fail "dry exit: $OUT"
echo "$OUT" | jq -e '.dry == true and (.added_columns | length == 7)' >/dev/null || fail "dry plan: $OUT"
jq -e '[.columns[].title] == ["Todo"]' "$TMP/.git/tea-state.json" >/dev/null || fail "dry run mutated state"
ok "dry-run plans all seven columns, mutates nothing"

echo "test-setup-gitea: $pass passed"
