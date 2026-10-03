#!/usr/bin/env bash
# Tests scripts/super-board-readme-sync.py and hooks/pre-commit-readme.sh against
# a throwaway copy of the pack, so the real README is never touched.
set -euo pipefail
cd "$(dirname "$0")/.."
PACK=$PWD
fail() { echo "FAIL: $1" >&2; exit 1; }
N=0; ok() { N=$((N + 1)); }

# 0 — the committed README is in sync.
python3 scripts/super-board-readme-sync.py --check || fail "the committed README.md is stale — run scripts/super-board-readme-sync.py"
ok

copy() {
  T=$(mktemp -d)
  mkdir -p "$T/scripts" "$T/hooks"
  cp -R skills "$T/"; cp README.md "$T/"
  cp scripts/super-board-readme-sync.py "$T/scripts/"; cp hooks/pre-commit-readme.sh "$T/hooks/"
  SYNC="$T/scripts/super-board-readme-sync.py"
}
fam() {  # python edit of families.json: $1 = statement on `d`
  python3 - "$T/skills/families.json" "$1" <<'PY'
import json, sys
p = sys.argv[1]; d = json.load(open(p)); exec(sys.argv[2])
open(p, "w").write(json.dumps(d, indent=2))
PY
}

# 1 — a changed brief makes --check fail without writing; a sync fixes it.
copy
fam 'd["you_type"]["skills"]["visual"] = "A brand new brief."'
BEFORE=$(cat "$T/README.md")
RC=0; python3 "$SYNC" --check 2>/dev/null || RC=$?
[ "$RC" -eq 1 ] || fail "--check on a stale README should exit 1, got $RC"
[ "$(cat "$T/README.md")" = "$BEFORE" ] || fail "--check must not write"
python3 "$SYNC" >/dev/null
grep -q "A brand new brief." "$T/README.md" || fail "sync did not write the new brief"
python3 "$SYNC" --check || fail "--check after a sync should pass"
rm -rf "$T"; ok

# 2 — a new skill bumps every "N skills (N you type, N the board runs)" count, the
#     family title and the badge, and its folded (>-) description is read when its
#     brief is empty.
copy
mkdir -p "$T/skills/new-one"
printf -- '---\nname: new-one\ndescription: >-\n  Does a new thing. Then more.\n---\n' > "$T/skills/new-one/SKILL.md"
fam 'd["you_type"]["skills"]["new-one"] = ""'
python3 "$SYNC" >/dev/null
read -r NY NB <<<"$(python3 -c 'import json,sys; d=json.load(open(sys.argv[1])); print(len(d["you_type"]["skills"]), len(d["board_runs"]["skills"]))' "$T/skills/families.json")"
PHRASE="$((NY + NB)) skills ($NY you type, $NB the board runs)"
[ "$(grep -cF "$PHRASE" "$T/README.md")" -ge 2 ] || fail "header and Skills counts not both updated to: $PHRASE"
grep -qF "**You type — $NY skills**" "$T/README.md" || fail "family title count not updated"
if grep -q "badge/skills-" README.md; then  # the badge is optional; when present it must follow
  grep -q "badge/skills-$((NY + NB))-" "$T/README.md" || fail "skills badge not updated"
fi
grep -q '| \[`/new-one`\](skills/new-one/SKILL.md) | Does a new thing. |' "$T/README.md" || fail "empty brief should fall back to the description's first sentence"
rm -rf "$T"; ok

# 3 — a skill missing from families.json, or a 15-word brief, is an input error (2).
copy
mkdir -p "$T/skills/orphan"; printf -- '---\nname: orphan\ndescription: x\n---\n' > "$T/skills/orphan/SKILL.md"
RC=0; python3 "$SYNC" --check 2>/dev/null || RC=$?
[ "$RC" -eq 2 ] || fail "an unlisted skill should exit 2, got $RC"
rm -rf "$T"
copy
fam 'd["board_runs"]["skills"]["super-qa"] = " ".join(["word"] * 15)'
RC=0; python3 "$SYNC" 2>/dev/null || RC=$?
[ "$RC" -eq 2 ] || fail "a 15-word brief should exit 2, got $RC"
rm -rf "$T"; ok

# 4 — --hook syncs only for an edit under skills/, and always exits 0.
copy
fam 'd["you_type"]["skills"]["visual"] = "Hook brief."'
printf '{"tool_input":{"file_path":"%s/docs/x.md"}}' "$T" | python3 "$SYNC" --hook || fail "--hook must exit 0"
grep -q "Hook brief." "$T/README.md" && fail "--hook must not sync for a path outside skills/"
printf 'not json' | python3 "$SYNC" --hook || fail "--hook must exit 0 on bad input"
printf '{"tool_input":{"file_path":"%s/skills/visual/SKILL.md"}}' "$T" | python3 "$SYNC" --hook || fail "--hook must exit 0"
grep -q "Hook brief." "$T/README.md" || fail "--hook should sync after an edit under skills/"
mkdir -p "$T/skills/orphan"; printf -- '---\nname: orphan\ndescription: x\n---\n' > "$T/skills/orphan/SKILL.md"
printf '{"tool_input":{"file_path":"%s/skills/orphan/SKILL.md"}}' "$T" | python3 "$SYNC" --hook 2>/dev/null || fail "--hook must exit 0 even on an input error"
rm -rf "$T"; ok

# 5 — pre-commit-readme.sh: a staged skill change with a stale README stops the
#     commit and regenerates README; once staged, the next run passes.
copy
( cd "$T" && git init -q && git add -A && git -c user.email=t@t -c user.name=t commit -q -m init )
fam 'd["you_type"]["skills"]["visual"] = "Pre-commit brief."'
( cd "$T" && git add skills/families.json )
RC=0; ( cd "$T" && sh hooks/pre-commit-readme.sh >/dev/null 2>&1 ) || RC=$?
[ "$RC" -eq 1 ] || fail "pre-commit should stop a commit with a stale README, got $RC"
grep -q "Pre-commit brief." "$T/README.md" || fail "pre-commit should regenerate README.md"
( cd "$T" && git add README.md && sh hooks/pre-commit-readme.sh ) || fail "pre-commit should pass once README is staged"
( cd "$T" && echo x > notes.txt && git add notes.txt && sh hooks/pre-commit-readme.sh ) || fail "pre-commit must ignore commits outside skills/"
rm -rf "$T"; ok

echo "PASS: test-readme-sync.sh ($N scenarios)"
