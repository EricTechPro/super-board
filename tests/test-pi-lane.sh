#!/usr/bin/env bash
# Stubbed Pi only: explicit opt-in, model precedence and ladders, review consent,
# deterministic tool allowlist, result-file failures and wave routing/concurrency/
# halt/stop. No network.
set -euo pipefail
KIT=$(cd "$(dirname "$0")/.." && pwd)
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
mkdir -p "$T/bin" "$T/repo"
git init -q "$T/repo"
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
export SB_PI_TEST_LOG="$T/calls.jsonl"
export PATH="$T/bin:$PATH"
cat > "$T/bin/pi" <<'PY'
#!/usr/bin/env python3
import fcntl, json, os, re, subprocess, sys, time
from pathlib import Path
args = sys.argv[1:]
prompt = args[-1] if args else ''
model = args[args.index('--model') + 1] if '--model' in args else 'default'
def log(entry):
    with open(os.environ['SB_PI_TEST_LOG'], 'a') as stream:
        fcntl.flock(stream, fcntl.LOCK_EX)
        stream.write(json.dumps(entry) + '\n')
if 'Grade complexity' in prompt:
    log(dict(args=args, model=model, number=int(re.search(r'issue #(\d+)', prompt).group(1)), lane='grade', active=1))
    output = Path(re.search(r'^Result file: (.+)$', prompt, re.M).group(1))
    output.write_text(json.dumps(dict(complexity=os.environ.get('SB_PI_TEST_GRADE', 'medium'))))
    sys.exit(int(os.environ.get('SB_PI_TEST_GRADE_EXIT', '0')))
card = json.loads(re.search(r'^Card: (.+)$', prompt, re.M).group(1))
lane = re.search(r'Run super-(build|qa|review)', prompt).group(1)
with open(os.environ['SB_PI_TEST_LOG'], 'a') as stream:
    fcntl.flock(stream, fcntl.LOCK_EX)
    counter = Path(os.environ['SB_PI_TEST_LOG'] + '.active')
    active = int(counter.read_text()) + 1 if counter.exists() else 1
    counter.write_text(str(active))
    stream.write(json.dumps(dict(args=args, model=model, prompt=prompt, number=card['number'], lane=lane, active=active)) + '\n')
if os.environ.get('SB_PI_TEST_SLEEP'):
    descendant = subprocess.Popen(['sleep', '60'])
    Path(os.environ['SB_PI_TEST_PID']).write_text(str(descendant.pid))
    time.sleep(60)
time.sleep(float(os.environ.get('SB_PI_TEST_DELAY', '0')))
output = Path(re.search(r'^Result file: (.+)$', prompt, re.M).group(1))
status = os.environ.get('SB_PI_TEST_STATUS', 'advanced')
column = {'build':'QA', 'qa':'Review', 'review':'Done'}[lane] if status == 'advanced' else card['status']
if os.environ.get('SB_PI_TEST_INVALID'):
    output.write_text('not json')
else:
    output.write_text(json.dumps(dict(status=status, column=column, detail=os.environ.get('SB_PI_TEST_DETAIL', 'stub lane result'), prUrl=None, branch=None, priorFindings=None)))
print('pi log noise must not appear in result stdout')
with open(os.environ['SB_PI_TEST_LOG'], 'a') as stream:
    fcntl.flock(stream, fcntl.LOCK_EX)
    counter.write_text(str(int(counter.read_text()) - 1))
sys.exit(int(os.environ.get('SB_PI_TEST_EXIT', '0')))
PY
chmod +x "$T/bin/pi"
cd "$T/repo"
echo '{"verify_commands":["git diff --check"]}' > "$T/config.json"
CARD='{"number":1,"status":"Ready","title":"example"}'
lane() { bash "$KIT/scripts/super-board-pi-lane.sh" --config "$T/config.json" --card "$CARD" --lane "$@" 2>"$T/stderr"; }
fail() { echo "FAIL: $*" >&2; cat "$T/stderr" >&2; exit 1; }
last_model() { tail -1 "$SB_PI_TEST_LOG" | jq -r '.model'; }

RC=0; lane review >"$T/out" || RC=$?
[ "$RC" -eq 78 ] && [ ! -e "$SB_PI_TEST_LOG" ] || fail 'non-explicit review must refuse before Pi'
echo '{"usage_fallback":"pi","verify_commands":["git diff --check"]}' > "$T/config.json"
RC=0; lane build >"$T/out" || RC=$?
[ "$RC" -eq 78 ] || fail 'Pi has no usage fallback; a bare build must still refuse'
echo '{"verify_commands":["git diff --check"]}' > "$T/config.json"
lane review --pi >"$T/out"
jq -e '.status == "advanced" and .column == "Done"' "$T/out" >/dev/null || fail 'explicit review allowed'
grep -q -- '--expect-head' "$SB_PI_TEST_LOG" || fail 'review must pin reviewed head to merge gate'
grep -q 'Never run bare gh pr merge' "$SB_PI_TEST_LOG" || fail 'review must keep merge protocol'
[ "$(last_model)" = default ] || fail 'no model uses the Pi default'
python3 - "$SB_PI_TEST_LOG" <<'PY'
import json, pathlib, sys
call = json.loads(pathlib.Path(sys.argv[1]).read_text().splitlines()[-1])
args = call['args']
assert args[0] == '-p' and '-a' in args, args
assert args[args.index('--tools') + 1] == 'read,bash,edit,write,grep,find,ls', args
assert '--model' not in args, args
assert 'Result file:' in call['prompt'] and 'Write your final JSON' in call['prompt'], call['prompt'][-400:]
assert 'Pi adaptation: do not launch Claude or other sub-agents' in call['prompt']
PY
lane build --pi=flag-model >"$T/out"
[ "$(last_model)" = flag-model ] || fail 'flag model must reach --model'
echo '{"pi":{"model":"config-model"},"verify_commands":["git diff --check"]}' > "$T/config.json"
lane qa --pi >"$T/out"
[ "$(last_model)" = config-model ] || fail 'config model must reach --model'
lane qa --pi=flag-model >"$T/out"
[ "$(last_model)" = flag-model ] || fail 'flag must beat config'
RC=0; lane build --pi= >"$T/out" || RC=$?
[ "$RC" -eq 64 ] || fail 'empty explicit model must refuse'
echo '{"pi":{"model":7},"verify_commands":["git diff --check"]}' > "$T/config.json"
RC=0; lane build --pi >"$T/out" || RC=$?
[ "$RC" -eq 64 ] || fail 'non-string pi.model must refuse'

# Ladders: run tier x card grade -> model; an ungraded card takes the medium cell.
echo '{"verify_commands":["git diff --check"]}' > "$T/config.json"
while read -r TIER GRADE WANT; do
  lane build --pi --tier "$TIER" ${GRADE:+--complexity "$GRADE"} >"$T/out"
  [ "$(last_model)" = "$WANT" ] || fail "ladder $TIER/$GRADE must pick $WANT, got $(last_model)"
done <<'CELLS'
medium low sonnet
medium medium sonnet
medium high opus
low low haiku
low medium sonnet
low high sonnet
high low opus
high medium opus
high high opus
CELLS
lane qa --pi --tier medium >"$T/out"
[ "$(last_model)" = sonnet ] || fail 'ungraded default card takes the medium cell'
lane qa --pi --tier low >"$T/out"
[ "$(last_model)" = sonnet ] || fail 'ungraded --low card takes the medium cell'
lane build --pi=flag-model --tier high --complexity high >"$T/out"
[ "$(last_model)" = flag-model ] || fail 'explicit --pi=<model> beats the ladder'
echo '{"pi":{"model":"config-model"},"verify_commands":["git diff --check"]}' > "$T/config.json"
lane build --pi --tier low --complexity low >"$T/out"
[ "$(last_model)" = config-model ] || fail 'pi.model beats the ladder'
echo '{"pi":{"model":""},"verify_commands":["git diff --check"]}' > "$T/config.json"
lane build --pi --tier high --complexity low >"$T/out"
[ "$(last_model)" = opus ] || fail 'empty pi.model leaves the ladder in charge'
echo '{"pi":{"ladders":{"low":{"low":"l-low","medium":"l-med","high":"l-high"},"medium":{"low":"m-low","medium":"m-med","high":"m-high"},"high":{"low":"h-low","medium":"h-med","high":"h-high"}}},"verify_commands":["git diff --check"]}' > "$T/config.json"
lane build --pi --tier high --complexity low >"$T/out"
[ "$(last_model)" = h-low ] || fail 'pi.ladders override must drive the ladder'
echo '{"pi":{"ladders":{"low":{"low":"x"}}},"verify_commands":["git diff --check"]}' > "$T/config.json"
RC=0; lane build --pi --tier low >"$T/out" || RC=$?
[ "$RC" -eq 64 ] || fail 'malformed pi.ladders must refuse'
RC=0; lane build --pi --tier extreme >"$T/out" || RC=$?
[ "$RC" -ne 0 ] || fail 'unknown tier must refuse'

# Failures: the result file is the only trusted output, fail closed.
echo '{"verify_commands":["git diff --check"]}' > "$T/config.json"
SB_PI_TEST_INVALID=1 RC=0
export SB_PI_TEST_INVALID
lane build --pi >"$T/out" || RC=$?
[ "$RC" -eq 1 ] && jq -e '.status == "failed"' "$T/out" >/dev/null || fail 'invalid result fails'
unset SB_PI_TEST_INVALID
RC=0; SB_PI_TEST_EXIT=2 lane build --pi >"$T/out" || RC=$?
[ "$RC" -eq 1 ] && jq -e '.status == "failed"' "$T/out" >/dev/null || fail 'nonzero pi exit never trusts success JSON'
RC=0; SB_PI_TEST_EXIT=9 lane build --pi >"$T/out" || RC=$?
[ "$RC" -eq 9 ] && jq -e '.status == "halted" and (.detail | startswith("verification-readiness:"))' "$T/out" >/dev/null || fail 'pi gate exit 9 preserves the verification halt'
RC=0; SB_PI_TEST_EXIT=10 lane build --pi >"$T/out" || RC=$?
[ "$RC" -eq 10 ] && jq -e '.status == "halted" and (.detail | startswith("skills-readiness:"))' "$T/out" >/dev/null || fail 'pi gate exit 10 preserves the skills halt'
RC=0; SB_PI_TEST_STATUS=halted SB_PI_TEST_DETAIL='verification-readiness: checks missing' lane review --pi >"$T/out" || RC=$?
[ "$RC" -eq 9 ] && jq -e '.status == "halted"' "$T/out" >/dev/null || fail 'structured readiness halt preserves code 9'

# A separate-git-dir worktree still launches: Pi has no sandbox flags, only -a
# (trust this project's .pi config) and the deterministic tool allowlist.
mkdir -p "$T/super/.git/modules"
git init -q --separate-git-dir="$T/super/.git/modules/kit" "$T/submodule"
python3 "$KIT/tests/fixtures/install_worker_skills.py" "$T/submodule"
cd "$T/submodule"
lane review --pi >"$T/out"
jq -e '.status == "advanced"' "$T/out" >/dev/null || fail 'a separate-git-dir worktree must launch a Pi lane'
cd "$T/repo"
# Wave: the haiku router grades Ready cards only when nothing pins a model.
wave() { bash "$KIT/scripts/super-board-pi-wave.sh" --config "$T/config.json" --cards "$CARDS" "$@" 2>"$T/stderr"; }
echo '{"max_workers":1,"verify_commands":["git diff --check"]}' > "$T/config.json"
CARDS='[{"number":1,"status":"Ready","title":"easy"},{"number":2,"status":"Review"}]'
: > "$SB_PI_TEST_LOG"
SB_PI_TEST_GRADE=low wave --pi --tier low >"$T/out"
python3 - "$SB_PI_TEST_LOG" <<'PY'
import json, pathlib, sys
calls = [json.loads(line) for line in pathlib.Path(sys.argv[1]).read_text().splitlines()]
grades = [call for call in calls if call['lane'] == 'grade']
assert [call['number'] for call in grades] == [1], grades
assert grades[0]['model'] == 'haiku'
card1 = [call['model'] for call in calls if call['number'] == 1 and call['lane'] != 'grade']
assert card1 == ['haiku'] * 3, card1          # --low x low on build, qa and review
card2 = [call['model'] for call in calls if call['number'] == 2]
assert card2 == ['sonnet'], card2             # ungraded Review card: --low medium cell
PY
: > "$SB_PI_TEST_LOG"
SB_PI_TEST_GRADE=high wave --pi >"$T/out"
jq -s -e '[.[] | select(.number == 1 and .lane != "grade") | .model] | all(. == "opus")' "$SB_PI_TEST_LOG" >/dev/null || fail 'default ladder sends a hard card to opus'
: > "$SB_PI_TEST_LOG"
SB_PI_TEST_GRADE_EXIT=1 wave --pi --tier high >"$T/out"
jq -s -e '[.[] | select(.number == 1 and .lane != "grade") | .model] | all(. == "opus")' "$SB_PI_TEST_LOG" >/dev/null || fail 'a failed grade falls back to the medium cell'
: > "$SB_PI_TEST_LOG"
echo '{"max_workers":1,"pi":{"router_model":"router-x"},"verify_commands":["git diff --check"]}' > "$T/config.json"
SB_PI_TEST_GRADE=low wave --pi >"$T/out"
jq -s -e '[.[] | select(.lane == "grade") | .model] == ["router-x"]' "$SB_PI_TEST_LOG" >/dev/null || fail 'pi.router_model drives the router'
echo '{"max_workers":1,"verify_commands":["git diff --check"]}' > "$T/config.json"
: > "$SB_PI_TEST_LOG"
wave --pi=pinned-model >"$T/out"
jq -s -e 'all(.lane != "grade") and all(.model == "pinned-model")' "$SB_PI_TEST_LOG" >/dev/null || fail 'a pinned model skips the router and wins every lane'
: > "$SB_PI_TEST_LOG"
RC=0; SB_PI_TEST_GRADE_EXIT=79 wave --pi >"$T/out" || RC=$?
[ "$RC" -eq 79 ] && jq -e '.halted and .cards[0].finalStatus == "halted"' "$T/out" >/dev/null || fail 'router halt stops the wave'
jq -s -e 'all(.lane == "grade")' "$SB_PI_TEST_LOG" >/dev/null || fail 'router halt launches no lane'
RC=0; wave >"$T/out" || RC=$?
[ "$RC" -eq 2 ] || fail 'wave requires exactly one explicit --pi'
rm -f "$T/stderr"

CARDS='[{"number":1,"status":"Ready"},{"number":2,"status":"Ready","labels":["qa"]},{"number":3,"status":"QA"},{"number":4,"status":"Review"}]'
echo '{"max_workers":1,"pi":{"model":"config-model"},"verify_commands":["git diff --check"]}' > "$T/config.json"
: > "$SB_PI_TEST_LOG"
wave --pi=wave-model --output "$T/wave.json" > "$T/out"
cmp "$T/out" "$T/wave.json" || fail 'file and stdout wave result differ'
jq -e '.halted == false and (.cards | length) == 4 and .cards[0].lanesRun == "build:advanced → qa:advanced → review:advanced" and .cards[1].lanesRun == "qa:advanced → review:advanced" and .cards[2].lastLane == "review" and .cards[3].column == "Done"' "$T/out" >/dev/null || fail 'wave routing/summary'
[ "$(last_model)" = wave-model ] || fail 'wave propagates explicit model'
jq -s -e 'all(.active == 1)' "$SB_PI_TEST_LOG" >/dev/null || fail 'max_workers=1 must serialize cards'
[ ! -e .claude/super-board/pi-wave.pid ] && [ -z "$(ls -A .claude/super-board/inflight)" ] || fail 'completed wave leaves no PID/worker locks'
: > "$SB_PI_TEST_LOG"
SB_PI_TEST_STATUS=bounced wave --pi >"$T/out"
jq -e '.cards[0].lanesRun == "build:bounced"' "$T/out" >/dev/null || fail 'non-advanced ends card chain'
: > "$SB_PI_TEST_LOG"
RC=0; SB_PI_TEST_STATUS=halted wave --pi >"$T/out" || RC=$?
[ "$RC" -eq 79 ] && [ "$(wc -l < "$SB_PI_TEST_LOG" | tr -d ' ')" -eq 1 ] || fail 'halt stops all new lane dispatch'
jq -e '.halted and (.cards | length) == 4' "$T/out" >/dev/null || fail 'halt summary preserves all cards'

# A readiness halt returned by a running lane stops dispatch and preserves its owned lock.
: > "$SB_PI_TEST_LOG"
RC=0; SB_PI_TEST_EXIT=9 wave --pi >"$T/out" || RC=$?
[ "$RC" -eq 9 ] && [ "$(wc -l < "$SB_PI_TEST_LOG" | tr -d ' ')" -eq 1 ] || fail 'readiness halt stops new Pi dispatch'
jq -e '.halted and .cards[0].finalStatus == "halted" and (.cards[0].detail | contains("verification-readiness"))' "$T/out" >/dev/null || fail 'readiness is a setup halt, not failed/rebase'
[ -f .claude/super-board/inflight/1 ] || fail 'readiness halt preserves its lane lock for recovery'
[ ! -e .claude/super-board/pi-wave.pid ] || fail 'ended wave releases only its PID marker'
rm .claude/super-board/inflight/1

# A normal Pi completion can also report gate exit 9 in its structured result.
: > "$SB_PI_TEST_LOG"
RC=0; SB_PI_TEST_STATUS=halted SB_PI_TEST_DETAIL='verification-readiness: checks missing' wave --pi >"$T/out" || RC=$?
[ "$RC" -eq 9 ] && [ "$(wc -l < "$SB_PI_TEST_LOG" | tr -d ' ')" -eq 1 ] || fail 'structured readiness halt preserves code 9'
[ -f .claude/super-board/inflight/1 ] || fail 'structured readiness halt preserves lane state'
rm .claude/super-board/inflight/1

# Two card chains run together, but a cap of 1 above was serial.
echo '{"max_workers":2,"verify_commands":["git diff --check"]}' > "$T/config.json"
CARDS='[{"number":1,"status":"Review"},{"number":2,"status":"Review"}]'
: > "$SB_PI_TEST_LOG"
SB_PI_TEST_DELAY=1 wave --pi >"$T/out"
python3 - "$SB_PI_TEST_LOG" <<'PY'
import json, pathlib, sys
calls = [json.loads(line) for line in pathlib.Path(sys.argv[1]).read_text().splitlines()]
assert len(calls) == 2 and max(call['active'] for call in calls) == 2
PY

# If the numeric lock cannot be written, startup fails as a card result and
# reaps the already-created launcher rather than losing the whole wave summary.
mkdir .claude/super-board/inflight/1
CARDS='[{"number":1,"status":"Review"}]'
wave --pi >"$T/out"
jq -e '.cards[0].finalStatus == "failed" and (.cards[0].detail | contains("could not start"))' "$T/out" >/dev/null || fail 'startup failure needs structured result'
rmdir .claude/super-board/inflight/1

# TERM reaps the Pi process group and its descendants before lock cleanup.
CARDS='[{"number":1,"status":"Review"}]'
SB_PI_TEST_SLEEP=1 SB_PI_TEST_PID="$T/descendant.pid" wave --pi >"$T/out" &
JOB=$!
for _ in {1..100}; do [ -s "$T/descendant.pid" ] && break; sleep 0.05; done
[ -s "$T/descendant.pid" ] || fail 'stub did not start'
WAVE_PID=$(cat .claude/super-board/pi-wave.pid)
kill -TERM "$WAVE_PID"
RC=0; wait "$JOB" || RC=$?
[ "$RC" -eq 79 ] || fail 'interrupted wave must halt'
DESCENDANT=$(cat "$T/descendant.pid")
! kill -0 "$DESCENDANT" 2>/dev/null || fail 'descendant survived wave cancellation'
[ ! -e .claude/super-board/pi-wave.pid ] && [ -z "$(ls -A .claude/super-board/inflight)" ] || fail 'interrupted wave leaves no live locks'
echo "PASS: test-pi-lane.sh (opt-in/models/ladders/review/results/wave/halt/cancellation)"
