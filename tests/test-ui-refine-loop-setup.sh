#!/usr/bin/env bash
# Tests skills/ui-refine-loop/scripts/refine-setup.sh `detect` (config → package.json
# → defaults, both Impeccable layouts, loud warnings), shoot.mjs parsing helpers and
# pr-shots.sh. No dev server, no browser.
#
#   bash tests/test-ui-refine-loop-setup.sh
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SETUP="$REPO_ROOT/skills/ui-refine-loop/scripts/refine-setup.sh"
SHOOT="$REPO_ROOT/skills/ui-refine-loop/scripts/shoot.mjs"
PRSHOTS="$REPO_ROOT/skills/ui-refine-loop/scripts/pr-shots.sh"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

PASS=0; FAIL=0
ok()  { PASS=$((PASS + 1)); printf '  ✅ %s\n' "$1"; }
bad() { FAIL=$((FAIL + 1)); printf '  ❌ %s\n     expected: %s\n     actual:   %s\n' "$1" "$2" "$3"; }
is()  { [ "$2" = "$3" ] && ok "$1" || bad "$1" "$2" "$3"; }
get() { node -e 'const j=JSON.parse(require("fs").readFileSync(0,"utf8"));console.log(JSON.stringify(eval("j."+process.argv[1])))' "$1"; }

# 1 — bare Next app with pnpm, no config: auto-detect everything, no auth.
A="$WORK/a"; mkdir -p "$A"; cd "$A"
cat > package.json <<'JSON'
{"scripts":{"dev":"next dev","typecheck":"tsc --noEmit","lint":"eslint .","test":"jest"}}
JSON
touch pnpm-lock.yaml .env.local
OUT=$(HOME="$WORK/nohome" bash "$SETUP" detect 2>"$WORK/a.err")
is "pm from lockfile"        '"pnpm"'                                  "$(get packageManager <<<"$OUT")"
is "next gets --port"        '"pnpm run dev --port $PORT"'            "$(get devCommand <<<"$OUT")"
is "checks from scripts"     '["pnpm run typecheck","pnpm run lint","CI=1 pnpm run test"]' "$(get checks <<<"$OUT")"
is "env files found"         '[".env.local"]'                          "$(get envFiles <<<"$OUT")"
is "no auth by default"      'null'                                    "$(get authScript <<<"$OUT")"
is "default state"           '[{"name":"main"}]'                       "$(get states <<<"$OUT")"
is "rubric without impeccable" '"rubric"'                              "$(get critic <<<"$OUT")"
is "rounds default"          '5'                                       "$(get rounds <<<"$OUT")"
is "no qaHookRounds"          'undefined'                               "$(node -e 'const j=JSON.parse(require("fs").readFileSync(0,"utf8"));console.log(String(j.qaHookRounds))' <<<"$OUT")"
is "missing impeccable warns in JSON" 'true'                            "$(node -e 'const j=JSON.parse(require("fs").readFileSync(0,"utf8"));console.log(j.warnings.some(w=>/Impeccable NOT FOUND/.test(w)))' <<<"$OUT")"
grep -q '!!! ui-refine-loop WARNING: Impeccable NOT FOUND' "$WORK/a.err" && ok "missing impeccable warns on stderr" || bad "missing impeccable warns on stderr" "banner" "$(cat "$WORK/a.err")"
is "taste default per project" '"docs/design/taste.md"'                "$(get tasteFile <<<"$OUT")"
is "taste not yet written"   'false'                                   "$(get tasteExists <<<"$OUT")"

# 2 — npm, CRA-style start script, placeholder test: PORT env only, test skipped, verify_commands fallback unused.
B="$WORK/b"; mkdir -p "$B"; cd "$B"
cat > package.json <<'JSON'
{"scripts":{"start":"react-scripts start","test":"echo \"Error: no test specified\" && exit 1"}}
JSON
OUT=$(HOME="$WORK/nohome" bash "$SETUP" detect 2>/dev/null)
is "npm start, no flag"      '"npm run start"'                         "$(get devCommand <<<"$OUT")"
is "placeholder test dropped" '[]'                                     "$(get checks <<<"$OUT")"

# 3 — vite via npm gets `-- --port`; no checks → verify_commands from config.
C="$WORK/c"; mkdir -p "$C/.claude/super-board/configs"; cd "$C"
echo '{"scripts":{"dev":"vite"}}' > package.json
echo '{"version":1,"verify_commands":["make check"]}' > .claude/super-board/configs/app.json
echo app > .claude/super-board/active
OUT=$(HOME="$WORK/nohome" bash "$SETUP" detect 2>/dev/null)
is "npm vite port"           '"npm run dev -- --port $PORT"'          "$(get devCommand <<<"$OUT")"
is "verify_commands fallback" '["make check"]'                        "$(get checks <<<"$OUT")"
is "active config found"     '".claude/super-board/configs/app.json"'  "$(get config <<<"$OUT")"

# 4 — the refine block wins over detection; impeccable (v4.4 launcher layout) found under ~; commented config parses.
D="$WORK/d"; mkdir -p "$D" "$WORK/home/.claude/skills/impeccable/scripts"; cd "$D"
touch "$WORK/home/.claude/skills/impeccable/scripts/impeccable"
printf -- '---\nname: impeccable\nversion: 4.4.0\n---\n' > "$WORK/home/.claude/skills/impeccable/SKILL.md"
echo '{"scripts":{"dev":"next dev","lint":"eslint ."}}' > package.json
cat > cfg.json <<'JSON'
// comment line, as onboard-written configs may carry
{"version":1,"refine":{"dev_command":"make serve PORT=$PORT","ready_path":"/health","check_commands":["make lint"],
 "auth_script":"scripts/auth.mjs","states":[{"name":"main"},{"name":"empty","query":"?empty=1"}],"rounds":6,"qa_hook_rounds":2,"taste_file":"design/taste.md","env_files":[".env.test"]}}
JSON
OUT=$(HOME="$WORK/home" bash "$SETUP" detect --config cfg.json)
is "dev_command override"    '"make serve PORT=$PORT"'                 "$(get devCommand <<<"$OUT")"
is "ready_path override"     '"/health"'                               "$(get readyPath <<<"$OUT")"
is "check_commands override" '["make lint"]'                           "$(get checks <<<"$OUT")"
is "auth_script passthrough" '"scripts/auth.mjs"'                      "$(get authScript <<<"$OUT")"
is "states passthrough"      '2'                                       "$(get states.length <<<"$OUT")"
is "rounds override (qa_hook_rounds ignored)" '6'                     "$(get rounds <<<"$OUT")"
is "taste_file override"     '"design/taste.md"'                       "$(get tasteFile <<<"$OUT")"
is "env_files override"      '[".env.test"]'                           "$(get envFiles <<<"$OUT")"
is "impeccable under ~"      '"impeccable"'                            "$(get critic <<<"$OUT")"
is "launcher layout"         '"launcher"'                              "$(get impeccable.layout <<<"$OUT")"
is "launcher version"        '"4.4.0"'                                 "$(get impeccable.version <<<"$OUT")"
is "launcher detect cmd"     "\"$WORK/home/.claude/skills/impeccable/scripts/impeccable detect --json\"" "$(get impeccable.detect <<<"$OUT")"
is "launcher context cmd"    "\"$WORK/home/.claude/skills/impeccable/scripts/impeccable context\"" "$(get impeccable.context <<<"$OUT")"
is "no warnings with impeccable" '[]'                                  "$(get warnings <<<"$OUT")"

# 4b — v4.0.x node layout, found in a PARENT dir's .agents/skills (a project nested in a bigger repo).
N="$WORK/mono"; mkdir -p "$N/.agents/skills/impeccable/scripts" "$N/projects/app"
touch "$N/.agents/skills/impeccable/scripts/detect.mjs" "$N/.agents/skills/impeccable/scripts/context.mjs"
printf -- '---\nname: impeccable\nversion: 4.0.4\n---\n' > "$N/.agents/skills/impeccable/SKILL.md"
cd "$N/projects/app"; echo '{"scripts":{"dev":"vite"}}' > package.json
OUT=$(HOME="$WORK/nohome" bash "$SETUP" detect 2>/dev/null)
NREAL=$(cd "$N" && pwd -P)
is "node layout"             '"node"'                                  "$(get impeccable.layout <<<"$OUT")"
is "node version"            '"4.0.4"'                                 "$(get impeccable.version <<<"$OUT")"
is "node detect cmd"         "\"node $NREAL/.agents/skills/impeccable/scripts/detect.mjs --json\"" "$(get impeccable.detect <<<"$OUT")"
is "node context cmd"        "\"node $NREAL/.agents/skills/impeccable/scripts/context.mjs\"" "$(get impeccable.context <<<"$OUT")"
is "found in parent dir"     '"impeccable"'                            "$(get critic <<<"$OUT")"

# 4c — both layouts in one folder: the launcher wins. refine.impeccable may name the skill dir or a script.
touch "$N/.agents/skills/impeccable/scripts/impeccable"
is "launcher preferred"      '"launcher"'                              "$(HOME="$WORK/nohome" bash "$SETUP" detect 2>/dev/null | get impeccable.layout)"
rm "$N/.agents/skills/impeccable/scripts/impeccable"
mkdir -p .claude/super-board/configs; echo app > .claude/super-board/active
echo "{\"refine\":{\"impeccable\":\"$N/.agents/skills/impeccable/scripts/detect.mjs\"}}" > .claude/super-board/configs/app.json
is "refine.impeccable → script file" '"node"'                         "$(HOME="$WORK/nohome" bash "$SETUP" detect 2>/dev/null | get impeccable.layout)"

# 4d — refine.impeccable pointing at nothing warns loudly, then falls back to search.
echo '{"refine":{"impeccable":"/nope/impeccable"}}' > .claude/super-board/configs/app.json
OUT=$(HOME="$WORK/nohome" bash "$SETUP" detect 2>"$WORK/d.err")
is "bad refine.impeccable warns" 'true'                               "$(node -e 'const j=JSON.parse(require("fs").readFileSync(0,"utf8"));console.log(j.warnings.some(w=>/is not an Impeccable install/.test(w)))' <<<"$OUT")"
grep -q 'WARNING: refine.impeccable' "$WORK/d.err" && ok "bad refine.impeccable banner" || bad "bad refine.impeccable banner" "banner" "$(cat "$WORK/d.err")"
is "falls back to the search" '"node"'                                "$(get impeccable.layout <<<"$OUT")"
cd "$D"

# 5 — usage errors exit 64.
bash "$SETUP" bogus >/dev/null 2>&1; is "unknown verb exits 64" 64 $?
bash "$SETUP" down >/dev/null 2>&1;  is "down without --run exits 64" 64 $?
bash "$SETUP" up --config cfg.json >/dev/null 2>&1; is "up without --slug exits 64" 64 $?
bash "$SETUP" up --worktree /tmp >/dev/null 2>&1; is "qa-hook --worktree is gone (64)" 64 $?

# 6 — shoot.mjs state parsing: names, inline JSON, file; and it compiles.
cd "$WORK"
echo '[{"name":"dense","query":"?n=500"}]' > states.json
STATES=$(node --input-type=module -e "
import { parseStates } from '$SHOOT';
console.log(JSON.stringify([parseStates(undefined), parseStates('main,empty'), parseStates('[{\"name\":\"x\"}]'), parseStates('states.json')]))")
is "shoot parseStates" '[[{"name":"main"}],[{"name":"main"},{"name":"empty"}],[{"name":"x"}],[{"name":"dense","query":"?n=500"}]]' "$STATES"
node "$SHOOT" >/dev/null 2>&1; is "shoot usage error exits 1" 1 $?
HELP=$(node --input-type=module -e "
import { parseThemes, pairNames } from '$SHOOT';
let bad = 'no-throw'; try { parseThemes('sepia') } catch { bad = 'throws' }
console.log(JSON.stringify([parseThemes(), parseThemes('dark'), bad, pairNames('/r/round-3-main-mobile-dark.png', 'round-3', 'round-0')]))")
is "shoot themes + compare names" '[["light","dark"],["dark"],"throws",{"before":"/r/round-0-main-mobile-dark.png","sheet":"/r/cmp-round-3-main-mobile-dark.png"}]' "$HELP"

# 7 — pr-shots.sh: copies round-0 + final shots onto the branch, commits, prints raw-URL table.
G="$WORK/g"; RUNG="$WORK/g.run"; mkdir -p "$G" "$RUNG/shots"; cd "$G"
git init -q; git config user.email t@t; git config user.name t; git commit -q --allow-empty -m init
git remote add origin git@github.com:acme/app.git
for l in round-0 round-2; do for v in desktop mobile; do for t in light dark; do echo x > "$RUNG/shots/$l-main-$v-$t.png"; done; done; done
git rev-parse HEAD > "$RUNG/base"; BASE7=$(git rev-parse --short HEAD)
TABLE=$(bash "$PRSHOTS" --worktree "$G" --run "$RUNG" --slug reports --final round-2)
SHA=$(git rev-parse HEAD)
is "shots committed"         '💄 [ui] reports: before/after screenshots' "$(git log -1 --format=%s)"
grep -q "| | Before \`$BASE7\` | After \`$BASE7\` (round-2) |" <<<"$TABLE" && ok "header names both shas" || bad "header names both shas" "Before \`$BASE7\` | After \`$BASE7\`" "$(head -1 <<<"$TABLE")"
is "8 images on the branch"  '8'                                       "$(git ls-files docs/ui-refine/reports | wc -l | tr -d ' ')"
grep -q "https://github.com/acme/app/raw/$SHA/docs/ui-refine/reports/before-desktop-light.png" <<<"$TABLE" && ok "raw URL pinned to sha" || bad "raw URL pinned to sha" "github raw link" "$TABLE"
grep -q "| Mobile 390 · dark |" <<<"$TABLE" && ok "table has mobile dark row" || bad "table has mobile dark row" "row" "$TABLE"
grep -qiE "imgur|postimg|imgbb" <<<"$TABLE" && bad "no public upload hosts" "none" "$TABLE" || ok "no public upload hosts"
rm "$RUNG/shots/round-2-main-mobile-dark.png" "$G/docs/ui-refine/reports/after-mobile-dark.png"
grep -q "not shot" <<<"$(bash "$PRSHOTS" --worktree "$G" --run "$RUNG" --slug reports --final round-2 --no-commit)" && ok "missing shot says not shot" || bad "missing shot says not shot" "not shot" "?"
bash "$PRSHOTS" --worktree "$G" >/dev/null 2>&1; is "pr-shots usage exits 64" 64 $?
git remote set-url origin https://gitlab.com/acme/app.git
bash "$PRSHOTS" --worktree "$G" --run "$RUNG" --slug reports --final round-2 --no-commit >/dev/null 2>&1; is "non-GitHub remote exits 70" 70 $?

echo
echo "test-ui-refine-loop-setup.sh: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
