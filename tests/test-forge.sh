#!/usr/bin/env bash
# Tests super-board-forge.sh + super-board-gitea-api.sh against fake wrappers,
# a fake gh and a fake tea. No network.
#
# The forge layer's promise: callers keep one verb set while the wrapper,
# the env (GITEA_REPO) and the halt discipline switch with SB_FORGE_KIND.
set -euo pipefail
cd "$(dirname "$0")"
SRC="$PWD/../scripts"
TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT
fail() { echo "FAIL: $1" >&2; exit 1; }
pass=0; ok() { pass=$((pass + 1)); echo "  ✅ $1"; }

mkdir -p "$TMP/bin"
cp "$SRC/super-board-forge.py" "$SRC/super-board-forge.sh" "$SRC/super-board-gitea-api.sh" "$TMP/bin/"

# Fake read wrappers: answer --check/--halt, otherwise print name + args.
for w in github gitea; do
  cat > "$TMP/bin/super-board-${w}-read.py" <<EOF
#!/usr/bin/env python3
import os, sys
args = sys.argv[1:]
if '--check' in args: sys.exit(0)
if '--halt' in args:
    with open(os.environ['SB_GITHUB_HALT_FILE'], 'w') as f: f.write('halted')
    sys.exit(0)
print('${w}-read', *args)
EOF
  chmod +x "$TMP/bin/super-board-${w}-read.py"
done

# Fake gh + tea: log every call; tea answers the label endpoints.
cat > "$TMP/bin/gh" <<'EOF'
#!/usr/bin/env bash
{ printf 'gh %s\n' "$*"; } >> "$FAKE_LOG"
case "$1 $2" in
  "issue edit") exit "${GH_FAIL:-0}" ;;
esac
exit 0
EOF
cat > "$TMP/bin/tea" <<'EOF'
#!/usr/bin/env bash
{ printf 'tea %s\n' "$*"; } >> "$FAKE_LOG"
args="$*"
case "$args" in
  *"-X GET"*labels*) cat "$TEA_LABELS" ;;
  *"-X POST"*labels*)
    case "$args" in
      *issues/*) echo '{}' ;;
      *) echo '{"id":7,"name":"created"}' ;;
    esac ;;
  *) echo '{}' ;;
esac
exit 0
EOF
chmod +x "$TMP/bin/gh" "$TMP/bin/tea"

export PATH="$TMP/bin:$PATH" FAKE_LOG="$TMP/log" HALT_FILE="$TMP/halt.json" \
       SB_GITHUB_HALT_FILE="$TMP/halt.json" TEA_LABELS="$TMP/labels.json"
: > "$FAKE_LOG"

load() { # fresh shell state per scenario, sourcing the copied forge.sh
  unset SB_FORGE_KIND SB_FORGE_HOST SB_FORGE_LOGIN SB_FORGE_OWNER SB_FORGE_REPO GITEA_REPO 2>/dev/null || true
  SB_FORGE_KIND=github SB_FORGE_HOST= SB_FORGE_LOGIN= SB_FORGE_OWNER= SB_FORGE_REPO=
  # shellcheck source=/dev/null
  source "$TMP/bin/super-board-forge.sh"
}

cat > "$TMP/github.json" <<'EOF'
{"forge":"github","project":{"owner":"acme"},"repo":{"remote":"https://github.com/acme/app.git"}}
EOF
cat > "$TMP/gitea.json" <<'EOF'
{"forge":"gitea","forge_host":"http://localhost:3000","project":{"owner":"acme"},
 "repo":{"remote":"http://localhost:3000/acme/app.git"}}
EOF

# 1 — github config resolves and reads through the github wrapper.
load
sb_forge_resolve "$TMP/github.json" || fail "resolve github"
[ "$SB_FORGE_KIND" = github ] || fail "kind: $SB_FORGE_KIND"
OUT=$(sb_forge_read json -- api rate_limit) || fail "github read"
[ "$OUT" = "github-read --kind json -- api rate_limit" ] || fail "dispatch: $OUT"
[ -z "${GITEA_REPO:-}" ] || fail "GITEA_REPO leaked into github mode"
ok "github config → github wrapper, no GITEA_REPO"

# 2 — gitea config resolves, exports GITEA_REPO and reads through the gitea wrapper.
load
sb_forge_resolve "$TMP/gitea.json" || fail "resolve gitea"
[ "$SB_FORGE_KIND" = gitea ] || fail "kind: $SB_FORGE_KIND"
[ "$SB_FORGE_HOST" = "http://localhost:3000" ] || fail "host: $SB_FORGE_HOST"
[ "$GITEA_REPO" = "acme/app" ] || fail "GITEA_REPO: ${GITEA_REPO:-unset}"
OUT=$(sb_forge_read json -- api GET repos/{owner}/{repo}) || fail "gitea read"
[ "$OUT" = "gitea-read --kind json -- api GET repos/{owner}/{repo}" ] || fail "dispatch: $OUT"
ok "gitea config → gitea wrapper + GITEA_REPO exported"

# 3 — a gitea config with no host anywhere exits 66 through resolve.
load
cat > "$TMP/nohost.json" <<'EOF'
{"forge":"gitea"}
EOF
RC=0; sb_forge_resolve "$TMP/nohost.json" 2>/dev/null || RC=$?
[ "$RC" = 66 ] || fail "hostless gitea should exit 66, got $RC"
ok "gitea without host → exit 66"

# 4 — write_once: success passes through to gh; failure halts and returns 79.
load
sb_forge_resolve "$TMP/github.json"
: > "$FAKE_LOG"
sb_forge_write_once issue edit 12 --add-label qa >/dev/null || fail "write_once success"
grep -q '^gh issue edit 12 --add-label qa' "$FAKE_LOG" || fail "gh not called: $(cat "$FAKE_LOG")"
rm -f "$HALT_FILE"
export GH_FAIL=1
RC=0; sb_forge_write_once issue edit 12 --add-label qa >/dev/null 2>&1 || RC=$?
unset GH_FAIL
[ "$RC" = 79 ] || fail "failed write should return 79, got $RC"
[ -f "$HALT_FILE" ] || fail "failed write must record a halt"
ok "write_once: gh passthrough, failure → halt + 79"

# 5 — label_add on github is one gh issue edit.
load
sb_forge_resolve "$TMP/github.json"
: > "$FAKE_LOG"; rm -f "$HALT_FILE"
sb_forge_label_add 12 bug >/dev/null || fail "github label_add"
grep -q '^gh issue edit 12 --add-label bug' "$FAKE_LOG" || fail "$(cat "$FAKE_LOG")"
ok "github label_add → gh issue edit --add-label"

# 6 — label_add on gitea: existing label → resolve id, POST issue labels.
load
sb_forge_resolve "$TMP/gitea.json"
echo '[{"id":5,"name":"bug"},{"id":6,"name":"qa"}]' > "$TEA_LABELS"
: > "$FAKE_LOG"
sb_forge_label_add 12 bug >/dev/null || fail "gitea label_add"
grep -q 'repos/{owner}/{repo}/issues/12/labels' "$FAKE_LOG" || fail "no attach: $(cat "$FAKE_LOG")"
grep -q '"labels":\[5\]' "$FAKE_LOG" || fail "wrong id: $(cat "$FAKE_LOG")"
ok "gitea label_add → id lookup + POST issue labels"

# 7 — label_add on gitea: missing label → create with the shared color, then attach.
load
sb_forge_resolve "$TMP/gitea.json"
echo '[]' > "$TEA_LABELS"
: > "$FAKE_LOG"
sb_forge_label_add 12 feature >/dev/null || fail "gitea label create"
grep -q '"name":"feature"' "$FAKE_LOG" || fail "no create: $(cat "$FAKE_LOG")"
grep -q '"color":"#1d76db"' "$FAKE_LOG" || fail "wrong color: $(cat "$FAKE_LOG")"
grep -q '"labels":\[7\]' "$FAKE_LOG" || fail "attach used wrong id: $(cat "$FAKE_LOG")"
ok "gitea label_add → create with shared color, then attach"

# 8 — tea_write halts + returns 79 when tea fails.
load
sb_forge_resolve "$TMP/gitea.json"
cat > "$TMP/bin/tea" <<'EOF'
#!/usr/bin/env bash
exit 1
EOF
chmod +x "$TMP/bin/tea"
rm -f "$HALT_FILE"
RC=0; sb_forge_tea_write POST repos/{owner}/{repo}/issues '{"title":"x"}' >/dev/null 2>&1 || RC=$?
[ "$RC" = 79 ] || fail "failed tea write should return 79, got $RC"
[ -f "$HALT_FILE" ] || fail "failed tea write must record a halt"
ok "tea_write: failure → halt + 79"

echo "test-forge: $pass passed"
