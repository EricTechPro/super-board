#!/usr/bin/env bash
# Stubbed Codex only: model precedence and ladders, review consent, bounded permissions,
# structured failures and wave routing/concurrency/halt/stop. No network.
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
export SB_CODEX_TEST_LOG="$T/calls.jsonl"
export PATH="$T/bin:$PATH"
cp "$KIT/tests/fixtures/fake_codex.py" "$T/bin/codex"
chmod +x "$T/bin/codex"
cd "$T/repo"
echo '{"verify_commands":["git diff --check"]}' > "$T/config.json"
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
echo '{"codex":{"model":"config-model"},"verify_commands":["git diff --check"]}' > "$T/config.json"
lane qa --codex >"$T/out"
[ "$(last_model)" = config-model ] || fail 'config model must reach -m'
lane qa --codex=flag-model >"$T/out"
[ "$(last_model)" = flag-model ] || fail 'flag must beat config'
RC=0; lane qa >"$T/out" || RC=$?
[ "$RC" -eq 78 ] || fail 'fallback without usage_fallback "codex" must refuse'
echo '{"codex":{"model":"config-model"},"usage_fallback":"codex","verify_commands":["git diff --check"]}' > "$T/config.json"
lane qa >"$T/out"
[ "$(last_model)" = config-model ] || fail 'build/qa fallback uses config model'
RC=0; lane review >"$T/out" || RC=$?
[ "$RC" -eq 78 ] || fail 'config model cannot authorize fallback review'
RC=0; lane build --codex= >"$T/out" || RC=$?
[ "$RC" -eq 64 ] || fail 'empty explicit model must refuse'

# Ladders: run tier x card grade -> model; an ungraded card takes the medium cell.
echo '{"verify_commands":["git diff --check"]}' > "$T/config.json"
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
echo '{"codex":{"model":"config-model"},"verify_commands":["git diff --check"]}' > "$T/config.json"
lane build --codex --tier low --complexity low >"$T/out"
[ "$(last_model)" = config-model ] || fail 'codex.model beats the ladder'
echo '{"codex":{"model":""},"verify_commands":["git diff --check"]}' > "$T/config.json"
lane build --codex --tier high --complexity low >"$T/out"
[ "$(last_model)" = gpt-6-astra ] || fail 'empty codex.model leaves the ladder in charge'
RC=0; lane build --codex --tier extreme >"$T/out" || RC=$?
[ "$RC" -ne 0 ] || fail 'unknown tier must refuse'

# Wave: the luna router grades Ready cards only when nothing pins a model.
echo '{"max_workers":1,"verify_commands":["git diff --check"]}' > "$T/config.json"
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
python3 "$KIT/tests/fixtures/install_worker_skills.py" "$T/submodule"
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

# The whole result is checked against the lane schema, not only status/column/detail.
while IFS= read -r BAD; do
  RC=0; SB_CODEX_TEST_RESULT="$BAD" lane build --codex >"$T/out" || RC=$?
  [ "$RC" -eq 1 ] && jq -e '.status == "failed" and .column == "Ready"' "$T/out" >/dev/null || fail "malformed result must fail: $BAD"
done <<'BAD'
{"status":"advanced","column":"QA","detail":"d","prUrl":7,"branch":null,"priorFindings":null}
{"status":"advanced","column":"QA","detail":"d","prUrl":null,"branch":null,"priorFindings":null,"extra":1}
{"status":"advanced","column":"QA","detail":"d","prUrl":null,"branch":null,"priorFindings":{"fixed":1,"noLongerApplies":0}}
{"status":"advanced","column":"QA","detail":"d","prUrl":null,"branch":null,"priorFindings":{"fixed":1,"notFixed":true,"noLongerApplies":0}}
{"status":"advanced","column":"QA","detail":"d","prUrl":null,"priorFindings":null}
{"status":"advanced","column":"QA","detail":"d","prUrl":null,"branch":["b"],"priorFindings":null}
{"status":"done","column":"QA","detail":"d","prUrl":null,"branch":null,"priorFindings":null}
["status","advanced"]
BAD
while IFS= read -r GOOD; do
  SB_CODEX_TEST_RESULT="$GOOD" lane build --codex >"$T/out" || fail "valid result must exit 0: $GOOD"
  [ "$(cat "$T/out")" = "$(jq -c . <<<"$GOOD" | python3 -c 'import json,sys; print(json.dumps(json.load(sys.stdin)))')" ] || fail "valid result must print unchanged: $GOOD"
done <<'GOOD'
{"status":"advanced","column":"QA","detail":"d","prUrl":null,"branch":null,"priorFindings":null}
{"status":"advanced","column":"QA","detail":"d","prUrl":"https://github.com/o/r/pull/2","branch":"sb/1","priorFindings":{"fixed":2,"notFixed":0,"noLongerApplies":1}}
GOOD

CARDS='[{"number":1,"status":"Ready"},{"number":2,"status":"Ready","labels":["qa"]},{"number":3,"status":"QA"},{"number":4,"status":"Review"}]'
echo '{"max_workers":1,"codex":{"model":"config-model"},"verify_commands":["git diff --check"]}' > "$T/config.json"
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

# A readiness halt returned by a running lane stops dispatch and preserves its owned lock.
: > "$SB_CODEX_TEST_LOG"
RC=0; SB_CODEX_TEST_EXIT=9 wave --codex >"$T/out" || RC=$?
[ "$RC" -eq 9 ] && [ "$(wc -l < "$SB_CODEX_TEST_LOG" | tr -d ' ')" -eq 1 ] || fail 'readiness halt stops new Codex dispatch'
jq -e '.halted and .cards[0].finalStatus == "halted" and (.cards[0].detail | contains("verification-readiness"))' "$T/out" >/dev/null || fail 'readiness is a setup halt, not failed/rebase'
[ -f .claude/super-board/inflight/1 ] || fail 'readiness halt preserves its lane lock for recovery'
[ ! -e .claude/super-board/codex-wave.pid ] || fail 'ended wave releases only its PID marker'
rm .claude/super-board/inflight/1  # fixture recovery before unrelated concurrency tests

# A normal Codex completion can also report gate exit 9 in its structured result.
: > "$SB_CODEX_TEST_LOG"
RC=0; SB_CODEX_TEST_STATUS=halted SB_CODEX_TEST_DETAIL='verification-readiness: checks missing' wave --codex >"$T/out" || RC=$?
[ "$RC" -eq 9 ] && [ "$(wc -l < "$SB_CODEX_TEST_LOG" | tr -d ' ')" -eq 1 ] || fail 'structured readiness halt preserves code 9'
[ -f .claude/super-board/inflight/1 ] || fail 'structured readiness halt preserves lane state'
rm .claude/super-board/inflight/1

# Two card chains run together, but a cap of 1 above was serial.
echo '{"max_workers":2,"verify_commands":["git diff --check"]}' > "$T/config.json"
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
