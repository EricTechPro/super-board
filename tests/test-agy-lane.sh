#!/usr/bin/env bash
# Stubbed Antigravity only (tests/fixtures/fake_agy.py through SB_AGY_BIN): model and effort
# precedence and ladders, the effort-in-slug rule, review consent, structured failures (no
# structured_output, run status ERROR, quota exhausted, denied tool calls), wave routing,
# router, halts and the workflow's summary keys. No network, no agy binary.
set -euo pipefail
KIT=$(cd "$(dirname "$0")/.." && pwd)
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
mkdir -p "$T/bin" "$T/repo" "$T/bare"
git init -q "$T/repo"
git init -q "$T/bare"
python3 "$KIT/tests/fixtures/install_worker_skills.py" "$T/repo"
export SUPER_BOARD_SKILLS_HOME="$T/home"; mkdir -p "$SUPER_BOARD_SKILLS_HOME"
cat > "$T/bin/gh" <<'PYGH'
#!/usr/bin/env python3
import json,sys
args=sys.argv[1:]
if args[:2]==['issue','view']:
    print(json.dumps({'labels':[]} if args[args.index('--json')+1] == 'labels' else {'number':int(args[2]),'title':'fixture','body':''}))
else:
    sys.exit('unexpected gh fixture call: '+str(args))
PYGH
chmod +x "$T/bin/gh"
export PATH="$T/bin:$PATH"
export SB_AGY_TEST_LOG="$T/calls.jsonl"
export SB_AGY_BIN="python3 $KIT/tests/fixtures/fake_agy.py"
cd "$T/repo"
echo '{"verify_commands":["git diff --check"]}' > "$T/config.json"
CARD='{"number":1,"status":"Ready","title":"example"}'
lane() { bash "$KIT/scripts/super-board-agy-lane.sh" --config "$T/config.json" --card "$CARD" --lane "$@" 2>"$T/stderr"; }
wave() { bash "$KIT/scripts/super-board-agy-wave.sh" --config "$T/config.json" --cards "$CARDS" "$@" 2>"$T/stderr"; }
fail() { echo "FAIL: $*" >&2; cat "$T/stderr" >&2 2>/dev/null || true; exit 1; }
last_opt() { tail -1 "$SB_AGY_TEST_LOG" | jq -r --arg o "$1" '.args | if index($o) then .[index($o)+1] else "none" end'; }

# Review needs the owner's explicit --agy; the brief carries the merge protocol and the agy host.
RC=0; lane review >"$T/out" || RC=$?
[ "$RC" -eq 78 ] && [ ! -e "$SB_AGY_TEST_LOG" ] || fail 'fallback review must refuse before agy'
lane review --agy >"$T/out"
jq -e '.status == "advanced" and .column == "Done"' "$T/out" >/dev/null || fail 'explicit review allowed'
grep -q -- '--expect-head' "$SB_AGY_TEST_LOG" || fail 'review must pin reviewed head to merge gate'
grep -q 'Never run bare gh pr merge' "$SB_AGY_TEST_LOG" || fail 'review must keep merge protocol'
grep -q -- '--host agy' "$SB_AGY_TEST_LOG" || fail 'the brief must recheck skills for host agy'
grep -q 'invoke_subagent' "$SB_AGY_TEST_LOG" || fail 'the brief must forbid Antigravity sub-agents'
[ "$(last_opt --model)" = none ] || fail 'no model uses the agy default'
[ "$(last_opt --effort)" = high ] || fail 'review always runs at effort high'
[ "$(last_opt --print-timeout)" = 120m ] || fail 'default timeout is 120m'
[ "$(last_opt --output-format)" = json ] || fail 'agy must print json'
tail -1 "$SB_AGY_TEST_LOG" | jq -e '.schema.properties.status.enum | index("advanced")' >/dev/null || fail 'the lane schema must reach --json-schema'
[ ! -e .claude/super-board/inflight/agy-1-review.prompt.md ] || fail 'the brief file must be removed after the run'

# Model precedence: flag > agy.model > ladder > CLI default; fallback needs usage_fallback "agy".
lane build --agy=flag-model >"$T/out"
[ "$(last_opt --model)" = flag-model ] || fail 'flag model must reach --model'
echo '{"agy":{"model":"config-model"},"verify_commands":["git diff --check"]}' > "$T/config.json"
lane qa --agy >"$T/out"
[ "$(last_opt --model)" = config-model ] || fail 'config model must reach --model'
lane qa --agy=flag-model >"$T/out"
[ "$(last_opt --model)" = flag-model ] || fail 'flag must beat config'
RC=0; lane qa >"$T/out" || RC=$?
[ "$RC" -eq 78 ] || fail 'fallback without usage_fallback "agy" must refuse'
echo '{"agy":{"model":"config-model"},"usage_fallback":"agy","verify_commands":["git diff --check"]}' > "$T/config.json"
lane qa >"$T/out"
[ "$(last_opt --model)" = config-model ] || fail 'build/qa fallback uses config model'
RC=0; lane review >"$T/out" || RC=$?
[ "$RC" -eq 78 ] || fail 'config model cannot authorize fallback review'
RC=0; lane build --agy= >"$T/out" || RC=$?
[ "$RC" -eq 64 ] || fail 'empty explicit model must refuse'

# Effort ladder: run tier x card grade; an ungraded card takes the medium cell; agy.effort pins.
echo '{"verify_commands":["git diff --check"]}' > "$T/config.json"
while read -r TIER GRADE WANT; do
  lane build --agy --tier "$TIER" ${GRADE:+--complexity "$GRADE"} >"$T/out"
  [ "$(last_opt --effort)" = "$WANT" ] || fail "effort $TIER/$GRADE must be $WANT, got $(last_opt --effort)"
done <<'CELLS'
medium low low
medium medium medium
medium high high
low low low
low medium low
low high medium
high low medium
high medium high
high high high
CELLS
lane qa --agy --tier medium >"$T/out"
[ "$(last_opt --effort)" = medium ] || fail 'ungraded card takes the medium cell'
lane build --agy >"$T/out"
[ "$(last_opt --effort)" = none ] || fail 'no tier means no --effort (CLI default)'
echo '{"agy":{"effort":"xhigh"},"verify_commands":["git diff --check"]}' > "$T/config.json"
lane build --agy --tier low --complexity low >"$T/out"
[ "$(last_opt --effort)" = xhigh ] || fail 'agy.effort pins the effort'
echo '{"agy":{"effort":"silly"},"verify_commands":["git diff --check"]}' > "$T/config.json"
RC=0; lane build --agy >"$T/out" || RC=$?
[ "$RC" -eq 64 ] || fail 'an unknown agy.effort must refuse'

# A slug that names its effort gets no --effort (agy refuses the pair); agy.ladder picks by cell.
echo '{"verify_commands":["git diff --check"]}' > "$T/config.json"
lane build --agy=gemini-3.8-flash-low --tier high --complexity high >"$T/out"
[ "$(last_opt --model)" = gemini-3.8-flash-low ] && [ "$(last_opt --effort)" = none ] || fail 'an effort suffix in the slug must suppress --effort'
echo '{"agy":{"ladder":{"medium":{"high":"big-model"}},"timeout":"30m"},"verify_commands":["git diff --check"]}' > "$T/config.json"
lane build --agy --tier medium --complexity high >"$T/out"
[ "$(last_opt --model)" = big-model ] || fail 'agy.ladder cell must pick the model'
[ "$(last_opt --print-timeout)" = 30m ] || fail 'agy.timeout must reach --print-timeout'
lane build --agy --tier medium --complexity low >"$T/out"
[ "$(last_opt --model)" = none ] || fail 'a missing ladder cell leaves the CLI default'

# Structured failures: fail closed, keep the raw run; quota is a halt; denials are reported.
echo '{"verify_commands":["git diff --check"]}' > "$T/config.json"
RC=0; SB_AGY_TEST_NO_OUTPUT=1 lane build --agy >"$T/out" || RC=$?
[ "$RC" -eq 1 ] && jq -e '.status == "failed" and (.detail | contains("raw run"))' "$T/out" >/dev/null || fail 'no structured_output must fail and name the raw run'
[ -f .claude/super-board/inflight/agy-1-build.last.json ] || fail 'the raw run must be kept on failure'
jq -e '.exit == 0 and (.stdout | contains("conversation_id"))' .claude/super-board/inflight/agy-1-build.last.json >/dev/null || fail 'the raw run must hold exit, stdout and stderr'
rm -f .claude/super-board/inflight/agy-1-build.last.json
RC=0; SB_AGY_TEST_RUN_STATUS=ERROR SB_AGY_TEST_ERROR='Individual quota reached. Resets in 20h' SB_AGY_TEST_EXIT=3 lane build --agy >"$T/out" || RC=$?
[ "$RC" -eq 79 ] && jq -e '.status == "halted" and (.detail | contains("quota"))' "$T/out" >/dev/null || fail 'quota exhausted must halt with 79'
RC=0; SB_AGY_TEST_RUN_STATUS=ERROR SB_AGY_TEST_ERROR='Internal error' SB_AGY_TEST_EXIT=1 lane build --agy >"$T/out" || RC=$?
[ "$RC" -eq 1 ] && jq -e '.status == "failed" and (.detail | contains("Internal error"))' "$T/out" >/dev/null || fail 'a run status ERROR must fail with its error'
RC=0; SB_AGY_TEST_EXIT=2 lane build --agy >"$T/out" || RC=$?
[ "$RC" -eq 1 ] && jq -e '.status == "failed"' "$T/out" >/dev/null || fail 'nonzero exit never trusts success JSON'
SB_AGY_TEST_DENIED=2 lane build --agy >"$T/out"
jq -e '.status == "advanced" and (.detail | contains("2 tool call(s) auto-denied")) and (.detail | contains("super-board-agy-permissions.py"))' "$T/out" >/dev/null || fail 'denied tool calls must be named in detail'
[ ! -e .claude/super-board/inflight/agy-1-build.last.json ] || fail 'a valid result keeps no raw run'

# The whole result is checked against the lane schema, not only status/column/detail.
while IFS= read -r BAD; do
  RC=0; SB_AGY_TEST_RESULT="$BAD" lane build --agy >"$T/out" || RC=$?
  [ "$RC" -eq 1 ] && jq -e '.status == "failed" and .column == "Ready"' "$T/out" >/dev/null || fail "malformed result must fail: $BAD"
done <<'BAD'
{"status":"advanced","column":"QA","detail":"d","prUrl":7,"branch":null,"priorFindings":null}
{"status":"advanced","column":"QA","detail":"d","prUrl":null,"branch":null,"priorFindings":null,"extra":1}
{"status":"advanced","column":"QA","detail":"d","prUrl":null,"branch":null,"priorFindings":{"fixed":1,"noLongerApplies":0}}
{"status":"done","column":"QA","detail":"d","prUrl":null,"branch":null,"priorFindings":null}
["status","advanced"]
BAD
rm -f .claude/super-board/inflight/agy-1-build.last.json
while IFS= read -r GOOD; do
  SB_AGY_TEST_RESULT="$GOOD" lane build --agy >"$T/out" || fail "valid result must exit 0: $GOOD"
  [ "$(cat "$T/out")" = "$(jq -c . <<<"$GOOD" | python3 -c 'import json,sys; print(json.dumps(json.load(sys.stdin)))')" ] || fail "valid result must print unchanged: $GOOD"
done <<'GOOD'
{"status":"advanced","column":"QA","detail":"d","prUrl":null,"branch":null,"priorFindings":null}
{"status":"advanced","column":"QA","detail":"d","prUrl":"https://github.com/o/r/pull/2","branch":"sb/1","priorFindings":{"fixed":2,"notFixed":0,"noLongerApplies":1}}
GOOD

# Wave: routing, model propagation, serialisation, clean exit; the wrapper refuses --codex.
CARDS='[{"number":1,"status":"Ready"},{"number":2,"status":"Ready","labels":["qa"]},{"number":3,"status":"QA"},{"number":4,"status":"Review"}]'
echo '{"max_workers":1,"agy":{"model":"config-model"},"verify_commands":["git diff --check"]}' > "$T/config.json"
: > "$SB_AGY_TEST_LOG"
wave --agy=wave-model --output "$T/wave.json" > "$T/out"
cmp "$T/out" "$T/wave.json" || fail 'file and stdout wave result differ'
jq -e '.halted == false and (.cards | length) == 4 and .cards[0].lanesRun == "build:advanced → qa:advanced → review:advanced" and .cards[1].lanesRun == "qa:advanced → review:advanced" and .cards[2].lastLane == "review" and .cards[3].column == "Done"' "$T/out" >/dev/null || fail 'wave routing/summary'
[ "$(last_opt --model)" = wave-model ] || fail 'wave propagates explicit model'
jq -s -e 'all(.lane != "grade")' "$SB_AGY_TEST_LOG" >/dev/null || fail 'a pinned model skips the router'
jq -s -e 'all(.active == 1)' "$SB_AGY_TEST_LOG" >/dev/null || fail 'max_workers=1 must serialize cards'
[ ! -e .claude/super-board/codex-wave.pid ] && [ -z "$(ls -A .claude/super-board/inflight)" ] || fail 'completed wave leaves no PID/worker locks'
RC=0; bash "$KIT/scripts/super-board-agy-wave.sh" --config "$T/config.json" --cards "$CARDS" --codex >"$T/out" 2>"$T/stderr" || RC=$?
[ "$RC" -eq 64 ] || fail 'the agy wave wrapper must refuse --codex'
RC=0; bash "$KIT/scripts/super-board-codex-wave.sh" --config "$T/config.json" --cards "$CARDS" --agy --codex >"$T/out" 2>"$T/stderr" || RC=$?
[ "$RC" -ne 0 ] || fail 'two host flags must refuse'

# Router: Ready cards are graded with agy.router_model at effort low when nothing pins a model;
# the grade sets the effort cell; a failed grade falls back to medium.
echo '{"max_workers":1,"agy":{"router_model":"cheap-model"},"verify_commands":["git diff --check"]}' > "$T/config.json"
CARDS='[{"number":1,"status":"Ready","title":"hard"},{"number":2,"status":"Review"}]'
: > "$SB_AGY_TEST_LOG"
SB_AGY_TEST_GRADE=high wave --agy >"$T/out"
python3 - "$SB_AGY_TEST_LOG" <<'PY'
import json, pathlib, sys
calls = [json.loads(line) for line in pathlib.Path(sys.argv[1]).read_text().splitlines()]
opt = lambda call, name: call['args'][call['args'].index(name) + 1] if name in call['args'] else 'none'
grades = [call for call in calls if call['lane'] == 'grade']
assert [call['number'] for call in grades] == [1], grades
assert opt(grades[0], '--model') == 'cheap-model' and opt(grades[0], '--effort') == 'low', grades[0]['args']
card1 = [opt(call, '--effort') for call in calls if call['number'] == 1 and call['lane'] != 'grade']
assert card1 == ['high', 'high', 'high'], card1            # medium tier x high grade on build and qa, review always high
card2 = [opt(call, '--effort') for call in calls if call['number'] == 2]
assert card2 == ['high'], card2                             # review lane
assert all(opt(call, '--model') == 'none' for call in calls if call['lane'] != 'grade'), 'router model must not leak into lanes'
PY
: > "$SB_AGY_TEST_LOG"
SB_AGY_TEST_GRADE_STATUS=ERROR wave --agy >"$T/out"
jq -s -e '[.[] | select(.number == 1 and .lane == "build") | .args | .[index("--effort")+1]] == ["medium"]' "$SB_AGY_TEST_LOG" >/dev/null || fail 'a failed grade falls back to the medium cell'

# Halts: a halted lane stops dispatch (79); a structured readiness halt keeps its lock (9).
CARDS='[{"number":1,"status":"Ready"},{"number":2,"status":"Review"}]'
echo '{"max_workers":1,"agy":{"model":"m"},"verify_commands":["git diff --check"]}' > "$T/config.json"
: > "$SB_AGY_TEST_LOG"
RC=0; SB_AGY_TEST_STATUS=halted wave --agy >"$T/out" || RC=$?
[ "$RC" -eq 79 ] && [ "$(wc -l < "$SB_AGY_TEST_LOG" | tr -d ' ')" -eq 1 ] || fail 'halt stops all new lane dispatch'
jq -e '.halted and (.cards | length) == 2' "$T/out" >/dev/null || fail 'halt summary preserves all cards'
: > "$SB_AGY_TEST_LOG"
RC=0; SB_AGY_TEST_STATUS=halted SB_AGY_TEST_DETAIL='verification-readiness: checks missing' wave --agy >"$T/out" || RC=$?
[ "$RC" -eq 9 ] && [ -f .claude/super-board/inflight/1 ] || fail 'structured readiness halt preserves lane state with code 9'
rm -f .claude/super-board/inflight/1
: > "$SB_AGY_TEST_LOG"
RC=0; SB_AGY_TEST_RUN_STATUS=ERROR SB_AGY_TEST_ERROR='RESOURCE_EXHAUSTED' SB_AGY_TEST_EXIT=3 wave --agy >"$T/out" || RC=$?
[ "$RC" -eq 79 ] && jq -e '.halted and (.cards[0].detail | contains("quota"))' "$T/out" >/dev/null || fail 'quota exhausted halts the wave'

# The wave hands back the workflow's summary keys (the one source: workflows/super-board-wave.js).
python3 - "$KIT/workflows/super-board-wave.js" > "$T/keys.json" <<'PY'
import json, re, sys
text = open(sys.argv[1]).read()
block = re.search(r'const summary = .*?return \{\n(.*?)\n\s*\}\n', text, re.S)
assert block, 'summary object not found in workflows/super-board-wave.js'
print(json.dumps(sorted(re.findall(r'^\s*(\w+):', block.group(1), re.M))))
PY
python3 - "$T/keys.json" "$T/out" <<'PY' || fail 'agy wave summary drifts from the workflow keys'
import json, sys
keys, result = json.load(open(sys.argv[1])), json.load(open(sys.argv[2]))
assert sorted(result) == ['cards', 'halted']
for card in result['cards']:
    assert sorted(card) == keys, (sorted(card), keys)
PY
cd "$T/bare"
RC=0; wave --agy >"$T/out" || RC=$?
[ "$RC" -eq 10 ] || fail "skills-readiness halt exits 10, got $RC"
echo 'PASS: test-agy-lane.sh (model/effort/ladders/router/review/results/wave/halt)'
