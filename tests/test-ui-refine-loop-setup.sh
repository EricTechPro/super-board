#!/usr/bin/env bash
# Tests skills/ui-refine-loop/scripts/refine-setup.sh `detect` (config → package.json
# → defaults) and shoot.mjs state parsing. No dev server, no browser.
#
#   bash tests/test-ui-refine-loop-setup.sh
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SETUP="$REPO_ROOT/skills/ui-refine-loop/scripts/refine-setup.sh"
SHOOT="$REPO_ROOT/skills/ui-refine-loop/scripts/shoot.mjs"
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
OUT=$(HOME="$WORK/nohome" bash "$SETUP" detect)
is "pm from lockfile"        '"pnpm"'                                  "$(get packageManager <<<"$OUT")"
is "next gets --port"        '"pnpm run dev --port $PORT"'            "$(get devCommand <<<"$OUT")"
is "checks from scripts"     '["pnpm run typecheck","pnpm run lint","CI=1 pnpm run test"]' "$(get checks <<<"$OUT")"
is "env files found"         '[".env.local"]'                          "$(get envFiles <<<"$OUT")"
is "no auth by default"      'null'                                    "$(get authScript <<<"$OUT")"
is "default state"           '[{"name":"main"}]'                       "$(get states <<<"$OUT")"
is "rubric without impeccable" '"rubric"'                              "$(get critic <<<"$OUT")"
is "rounds default"          '10'                                      "$(get rounds <<<"$OUT")"

# 2 — npm, CRA-style start script, placeholder test: PORT env only, test skipped, verify_commands fallback unused.
B="$WORK/b"; mkdir -p "$B"; cd "$B"
cat > package.json <<'JSON'
{"scripts":{"start":"react-scripts start","test":"echo \"Error: no test specified\" && exit 1"}}
JSON
OUT=$(HOME="$WORK/nohome" bash "$SETUP" detect)
is "npm start, no flag"      '"npm run start"'                         "$(get devCommand <<<"$OUT")"
is "placeholder test dropped" '[]'                                     "$(get checks <<<"$OUT")"

# 3 — vite via npm gets `-- --port`; no checks → verify_commands from config.
C="$WORK/c"; mkdir -p "$C/.claude/super-board/configs"; cd "$C"
echo '{"scripts":{"dev":"vite"}}' > package.json
echo '{"version":1,"verify_commands":["make check"]}' > .claude/super-board/configs/app.json
echo app > .claude/super-board/active
OUT=$(HOME="$WORK/nohome" bash "$SETUP" detect)
is "npm vite port"           '"npm run dev -- --port $PORT"'          "$(get devCommand <<<"$OUT")"
is "verify_commands fallback" '["make check"]'                        "$(get checks <<<"$OUT")"
is "active config found"     '".claude/super-board/configs/app.json"'  "$(get config <<<"$OUT")"

# 4 — the refine block wins over detection; impeccable found under ~; commented config parses.
D="$WORK/d"; mkdir -p "$D" "$WORK/home/.claude/skills/impeccable/scripts"; cd "$D"
touch "$WORK/home/.claude/skills/impeccable/scripts/impeccable"
echo '{"scripts":{"dev":"next dev","lint":"eslint ."}}' > package.json
cat > cfg.json <<'JSON'
// comment line, as onboard-written configs may carry
{"version":1,"refine":{"dev_command":"make serve PORT=$PORT","ready_path":"/health","check_commands":["make lint"],
 "auth_script":"scripts/auth.mjs","states":[{"name":"main"},{"name":"empty","query":"?empty=1"}],"rounds":6,"qa_hook_rounds":2,"env_files":[".env.test"]}}
JSON
OUT=$(HOME="$WORK/home" bash "$SETUP" detect --config cfg.json)
is "dev_command override"    '"make serve PORT=$PORT"'                 "$(get devCommand <<<"$OUT")"
is "ready_path override"     '"/health"'                               "$(get readyPath <<<"$OUT")"
is "check_commands override" '["make lint"]'                           "$(get checks <<<"$OUT")"
is "auth_script passthrough" '"scripts/auth.mjs"'                      "$(get authScript <<<"$OUT")"
is "states passthrough"      '2'                                       "$(get states.length <<<"$OUT")"
is "rounds override"         '[6,2]'                                   "$(node -e 'const j=JSON.parse(require("fs").readFileSync(0,"utf8"));console.log(JSON.stringify([j.rounds,j.qaHookRounds]))' <<<"$OUT")"
is "env_files override"      '[".env.test"]'                           "$(get envFiles <<<"$OUT")"
is "impeccable under ~"      '"impeccable"'                            "$(get critic <<<"$OUT")"

# 5 — usage errors exit 64.
bash "$SETUP" bogus >/dev/null 2>&1; is "unknown verb exits 64" 64 $?
bash "$SETUP" down >/dev/null 2>&1;  is "down without --run exits 64" 64 $?
bash "$SETUP" up --config cfg.json >/dev/null 2>&1; is "up without --slug exits 64" 64 $?

# 6 — shoot.mjs state parsing: names, inline JSON, file; and it compiles.
cd "$WORK"
echo '[{"name":"dense","query":"?n=500"}]' > states.json
STATES=$(node --input-type=module -e "
import { parseStates } from '$SHOOT';
console.log(JSON.stringify([parseStates(undefined), parseStates('main,empty'), parseStates('[{\"name\":\"x\"}]'), parseStates('states.json')]))")
is "shoot parseStates" '[[{"name":"main"}],[{"name":"main"},{"name":"empty"}],[{"name":"x"}],[{"name":"dense","query":"?n=500"}]]' "$STATES"
node "$SHOOT" >/dev/null 2>&1; is "shoot usage error exits 1" 1 $?

echo
echo "test-ui-refine-loop-setup.sh: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
