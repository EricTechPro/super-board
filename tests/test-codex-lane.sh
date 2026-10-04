#!/usr/bin/env bash
# Stubbed Codex only: model precedence and ladders, review consent, bounded permissions,
# structured failures and wave routing/concurrency/halt/stop. No network.
set -euo pipefail
KIT=$(cd "$(dirname "$0")/.." && pwd)
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
mkdir -p "$T/bin" "$T/repo"
git init -q "$T/repo"
export SB_CODEX_TEST_LOG="$T/calls.jsonl"
export PATH="$T/bin:$PATH"
cat > "$T/bin/codex" <<'PY'
#!/usr/bin/env python3
import fcntl, json, os, re, subprocess, sys, time
from pathlib import Path
args = sys.argv[1:]
prompt = sys.stdin.read()
if 'Grade complexity' in prompt:
    with open(os.environ['SB_CODEX_TEST_LOG'], 'a') as log:
        fcntl.flock(log, fcntl.LOCK_EX)
        log.write(json.dumps(dict(args=args, number=int(re.search(r'issue #(\d+)', prompt).group(1)), lane='grade', active=1)) + '\n')
    output = Path(args[args.index('--output-last-message') + 1])
    output.write_text(json.dumps(dict(complexity=os.environ.get('SB_CODEX_TEST_GRADE', 'medium'))))
    sys.exit(int(os.environ.get('SB_CODEX_TEST_GRADE_EXIT', '0')))
card = json.loads(re.search(r'^Card: (.+)$', prompt, re.M).group(1))
lane = re.search(r'Run super-(build|qa|review)', prompt).group(1)
with open(os.environ['SB_CODEX_TEST_LOG'], 'a') as log:
    fcntl.flock(log, fcntl.LOCK_EX)
    counter = Path(os.environ['SB_CODEX_TEST_LOG'] + '.active')
    active = int(counter.read_text()) + 1 if counter.exists() else 1
    counter.write_text(str(active))
    log.write(json.dumps(dict(args=args, prompt=prompt, number=card['number'], lane=lane, active=active)) + '\n')
if os.environ.get('SB_CODEX_TEST_SLEEP'):
    descendant = subprocess.Popen(['sleep', '60'])
    Path(os.environ['SB_CODEX_TEST_PID']).write_text(str(descendant.pid))
    time.sleep(60)
time.sleep(float(os.environ.get('SB_CODEX_TEST_DELAY', '0')))
output = Path(args[args.index('--output-last-message') + 1])
status = os.environ.get('SB_CODEX_TEST_STATUS', 'advanced')
column = {'build':'QA', 'qa':'Review', 'review':'Done'}[lane] if status == 'advanced' else card['status']
if os.environ.get('SB_CODEX_TEST_INVALID'):
    output.write_text('not json')
else:
    output.write_text(json.dumps(dict(status=status, column=column, detail='stub lane result', prUrl=None, branch=None, priorFindings=None)))
print('codex log noise must not appear in result stdout')
with open(os.environ['SB_CODEX_TEST_LOG'], 'a') as log:
    fcntl.flock(log, fcntl.LOCK_EX)
    counter.write_text(str(int(counter.read_text()) - 1))
sys.exit(int(os.environ.get('SB_CODEX_TEST_EXIT', '0')))
PY
chmod +x "$T/bin/codex"
cd "$T/repo"
echo '{}' > "$T/config.json"
CARD='{"number":1,"status":"Ready","title":"example"}'
lane() { bash "$KIT/scripts/super-board-codex-lane.sh" --config "$T/config.json" --card "$CARD" --lane "$@" 2>"$T/stderr"; }
wave() { bash "$KIT/scripts/super-board-codex-wave.sh" --config "$T/config.json" --cards "$CARDS" "$@" 2>"$T/stderr"; }
fail() { echo "FAIL: $*" >&2; cat "$T/stderr" >&2; exit 1; }
last_model() { tail -1 "$SB_CODEX_TEST_LOG" | jq -r '.args | if index("-m") then .[index("-m")+1] else "default" end'; }

RC=0; lane review >"$T/out" || RC=$?
[ "$RC" -eq 78 ] && [ ! -e "$SB_CODEX_TEST_LOG" ] || fail 'fallback review must refuse before Codex'
lane review --codex >"$T/out"
jq -e '.status == "advanced" and .column == "Done"' "$T/out" >/dev/null || fail 'explicit review allowed'
grep -q -- '--expect-head' "$SB_CODEX_TEST_LOG" || fail 'review must pin reviewed head to merge gate'
grep -q 'Never run bare gh pr merge' "$SB_CODEX_TEST_LOG" || fail 'review must keep merge protocol'
[ "$(last_model)" = default ] || fail 'no model uses Codex default'
lane build --codex=flag-model >"$T/out"
[ "$(last_model)" = flag-model ] || fail 'flag model must reach -m'
echo '{"codex":{"model":"config-model"}}' > "$T/config.json"
lane qa --codex >"$T/out"
[ "$(last_model)" = config-model ] || fail 'config model must reach -m'
lane qa --codex=flag-model >"$T/out"
[ "$(last_model)" = flag-model ] || fail 'flag must beat config'
RC=0; lane qa >"$T/out" || RC=$?
[ "$RC" -eq 78 ] || fail 'fallback without usage_fallback "codex" must refuse'
echo '{"codex":{"model":"config-model"},"usage_fallback":"codex"}' > "$T/config.json"
lane qa >"$T/out"
[ "$(last_model)" = config-model ] || fail 'build/qa fallback uses config model'
RC=0; lane review >"$T/out" || RC=$?
[ "$RC" -eq 78 ] || fail 'config model cannot authorize fallback review'
RC=0; lane build --codex= >"$T/out" || RC=$?
[ "$RC" -eq 64 ] || fail 'empty explicit model must refuse'

# Ladders: run tier x card grade -> model; an ungraded card takes the medium cell.
echo '{}' > "$T/config.json"
while read -r TIER GRADE WANT; do
  lane build --codex --tier "$TIER" ${GRADE:+--complexity "$GRADE"} >"$T/out"
  [ "$(last_model)" = "$WANT" ] || fail "ladder $TIER/$GRADE must pick $WANT, got $(last_model)"
done <<'CELLS'
medium low gpt-6.1-sol
medium medium gpt-6.1-sol
medium high gpt-6-astra
low low gpt-6-luna
low medium gpt-6.1-sol
low high gpt-6.1-sol
high low gpt-6-astra
high medium gpt-6-astra
high high gpt-6-astra
CELLS
lane qa --codex --tier medium >"$T/out"
[ "$(last_model)" = gpt-6.1-sol ] || fail 'ungraded default card takes the medium cell'
lane qa --codex --tier low >"$T/out"
[ "$(last_model)" = gpt-6.1-sol ] || fail 'ungraded --low card takes the medium cell'
lane build --codex=flag-model --tier high --complexity high >"$T/out"
[ "$(last_model)" = flag-model ] || fail 'explicit --codex=<model> beats the ladder'
echo '{"codex":{"model":"config-model"}}' > "$T/config.json"
lane build --codex --tier low --complexity low >"$T/out"
[ "$(last_model)" = config-model ] || fail 'codex.model beats the ladder'
echo '{"codex":{"model":""}}' > "$T/config.json"
lane build --codex --tier high --complexity low >"$T/out"
[ "$(last_model)" = gpt-6-astra ] || fail 'empty codex.model leaves the ladder in charge'
RC=0; lane build --codex --tier extreme >"$T/out" || RC=$?
[ "$RC" -ne 0 ] || fail 'unknown tier must refuse'

# Wave: the luna router grades Ready cards only when nothing pins a model.
echo '{"max_workers":1}' > "$T/config.json"
CARDS='[{"number":1,"status":"Ready","title":"easy"},{"number":2,"status":"Review"}]'
: > "$SB_CODEX_TEST_LOG"
SB_CODEX_TEST_GRADE=low wave --codex --tier low >"$T/out"
python3 - "$SB_CODEX_TEST_LOG" <<'PY'
import json, pathlib, sys
calls = [json.loads(line) for line in pathlib.Path(sys.argv[1]).read_text().splitlines()]
model = lambda call: call['args'][call['args'].index('-m') + 1] if '-m' in call['args'] else 'default'
grades = [call for call in calls if call['lane'] == 'grade']
assert [call['number'] for call in grades] == [1], grades
assert model(grades[0]) == 'gpt-6-luna'
card1 = [model(call) for call in calls if call['number'] == 1 and call['lane'] != 'grade']
assert card1 == ['gpt-6-luna'] * 3, card1          # --low x low on build, qa and review
card2 = [model(call) for call in calls if call['number'] == 2]
assert card2 == ['gpt-6.1-sol'], card2              # ungraded Review card: --low medium cell
PY
: > "$SB_CODEX_TEST_LOG"
SB_CODEX_TEST_GRADE=high wave --codex >"$T/out"
jq -s -e '[.[] | select(.number == 1 and .lane != "grade") | .args | .[index("-m")+1]] | all(. == "gpt-6-astra")' "$SB_CODEX_TEST_LOG" >/dev/null || fail 'default ladder sends a hard card to astra'
: > "$SB_CODEX_TEST_LOG"
SB_CODEX_TEST_GRADE_EXIT=1 wave --codex --tier high >"$T/out"
jq -s -e '[.[] | select(.number == 1 and .lane != "grade") | .args | .[index("-m")+1]] | all(. == "gpt-6-astra")' "$SB_CODEX_TEST_LOG" >/dev/null || fail 'a failed grade falls back to the medium cell'
: > "$SB_CODEX_TEST_LOG"
wave --codex=pinned-model >"$T/out"
jq -s -e 'all(.lane != "grade") and all(.args | .[index("-m")+1] == "pinned-model")' "$SB_CODEX_TEST_LOG" >/dev/null || fail 'a pinned model skips the router and wins every lane'
: > "$SB_CODEX_TEST_LOG"
RC=0; SB_CODEX_TEST_GRADE_EXIT=79 wave --codex >"$T/out" || RC=$?
[ "$RC" -eq 79 ] && jq -e '.halted and .cards[0].finalStatus == "halted"' "$T/out" >/dev/null || fail 'router halt stops the wave'
jq -s -e 'all(.lane == "grade")' "$SB_CODEX_TEST_LOG" >/dev/null || fail 'router halt launches no lane'
rm -f "$T/stderr"

# A .git pointer to a superproject-shaped external git dir, without a commit.
mkdir -p "$T/super/.git/modules"
git init -q --separate-git-dir="$T/super/.git/modules/kit" "$T/submodule"
cd "$T/submodule"
lane review --codex >"$T/out"
python3 - "$SB_CODEX_TEST_LOG" "$T/submodule" "$T/super/.git/modules/kit" <<'PY'
import json, pathlib, sys
call = json.loads(pathlib.Path(sys.argv[1]).read_text().splitlines()[-1])
args = call['args']
configs = [args[i+1] for i, arg in enumerate(args) if arg == '-c']
assert 'approval_policy="never"' in configs
assert 'default_permissions="super-board-lane"' in configs
assert not any('.extends=' in entry for entry in configs)
assert 'permissions.super-board-lane.network.enabled=true' in configs
grants = next(entry.split('=', 1)[1] for entry in configs if entry.startswith('permissions.super-board-lane.filesystem='))
filesystem = json.loads(grants.replace('=', ':'))
for path in sys.argv[2:]:
    assert filesystem[str(pathlib.Path(path).resolve())] == 'write'
assert filesystem[':root'] == 'read'
assert '--dangerously-bypass-approvals-and-sandbox' not in args
PY
cd "$T/repo"
SB_CODEX_TEST_INVALID=1 RC=0
export SB_CODEX_TEST_INVALID
lane build --codex >"$T/out" || RC=$?
[ "$RC" -eq 1 ] && jq -e '.status == "failed"' "$T/out" >/dev/null || fail 'invalid result fails'
unset SB_CODEX_TEST_INVALID
RC=0; SB_CODEX_TEST_EXIT=2 lane build --codex >"$T/out" || RC=$?
[ "$RC" -eq 1 ] && jq -e '.status == "failed"' "$T/out" >/dev/null || fail 'nonzero exec never trusts success JSON'

CARDS='[{"number":1,"status":"Ready"},{"number":2,"status":"Ready","labels":["qa"]},{"number":3,"status":"QA"},{"number":4,"status":"Review"}]'
echo '{"max_workers":1,"codex":{"model":"config-model"}}' > "$T/config.json"
: > "$SB_CODEX_TEST_LOG"
wave --codex=wave-model --output "$T/wave.json" > "$T/out"
cmp "$T/out" "$T/wave.json" || fail 'file and stdout wave result differ'
jq -e '.halted == false and (.cards | length) == 4 and .cards[0].lanesRun == "build:advanced → qa:advanced → review:advanced" and .cards[1].lanesRun == "qa:advanced → review:advanced" and .cards[2].lastLane == "review" and .cards[3].column == "Done"' "$T/out" >/dev/null || fail 'wave routing/summary'
[ "$(last_model)" = wave-model ] || fail 'wave propagates explicit model'
jq -s -e 'all(.active == 1)' "$SB_CODEX_TEST_LOG" >/dev/null || fail 'max_workers=1 must serialize cards'
[ ! -e .claude/super-board/codex-wave.pid ] && [ -z "$(ls -A .claude/super-board/inflight)" ] || fail 'completed wave leaves no PID/worker locks'
: > "$SB_CODEX_TEST_LOG"
SB_CODEX_TEST_STATUS=bounced wave --codex >"$T/out"
jq -e '.cards[0].lanesRun == "build:bounced"' "$T/out" >/dev/null || fail 'non-advanced ends card chain'
: > "$SB_CODEX_TEST_LOG"
RC=0; SB_CODEX_TEST_STATUS=halted wave --codex >"$T/out" || RC=$?
[ "$RC" -eq 79 ] && [ "$(wc -l < "$SB_CODEX_TEST_LOG" | tr -d ' ')" -eq 1 ] || fail 'halt stops all new lane dispatch'
jq -e '.halted and (.cards | length) == 4' "$T/out" >/dev/null || fail 'halt summary preserves all cards'

# Two card chains run together, but a cap of 1 above was serial.
echo '{"max_workers":2}' > "$T/config.json"
CARDS='[{"number":1,"status":"Review"},{"number":2,"status":"Review"}]'
: > "$SB_CODEX_TEST_LOG"
SB_CODEX_TEST_DELAY=1 wave --codex >"$T/out"
python3 - "$SB_CODEX_TEST_LOG" <<'PY'
import json, pathlib, sys
calls = [json.loads(line) for line in pathlib.Path(sys.argv[1]).read_text().splitlines()]
assert len(calls) == 2 and max(call['active'] for call in calls) == 2
PY

# If the numeric lock cannot be written, startup fails as a card result and
# reaps the already-created launcher rather than losing the whole wave summary.
mkdir .claude/super-board/inflight/1
CARDS='[{"number":1,"status":"Review"}]'
wave --codex >"$T/out"
jq -e '.cards[0].finalStatus == "failed" and (.cards[0].detail | contains("could not start"))' "$T/out" >/dev/null || fail 'startup failure needs structured result'
rmdir .claude/super-board/inflight/1

# TERM reaps the Codex process group and its descendants before lock cleanup.
CARDS='[{"number":1,"status":"Review"}]'
SB_CODEX_TEST_SLEEP=1 SB_CODEX_TEST_PID="$T/descendant.pid" wave --codex >"$T/out" &
JOB=$!
for _ in {1..100}; do [ -s "$T/descendant.pid" ] && break; sleep 0.05; done
[ -s "$T/descendant.pid" ] || fail 'stub did not start'
WAVE_PID=$(cat .claude/super-board/codex-wave.pid)
kill -TERM "$WAVE_PID"
RC=0; wait "$JOB" || RC=$?
[ "$RC" -eq 79 ] || fail 'interrupted wave must halt'
DESCENDANT=$(cat "$T/descendant.pid")
! kill -0 "$DESCENDANT" 2>/dev/null || fail 'descendant survived wave cancellation'
[ ! -e .claude/super-board/codex-wave.pid ] && [ -z "$(ls -A .claude/super-board/inflight)" ] || fail 'interrupted wave leaves no live locks'
echo 'PASS: test-codex-lane.sh (model/ladders/router/review/sandbox/results/wave/halt/cancellation)'
