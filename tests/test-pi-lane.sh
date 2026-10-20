#!/usr/bin/env bash
# Offline print-mode boundary tests. Real CLI smoke/pilot is recorded separately.
set -euo pipefail
KIT=$(cd "$(dirname "$0")/.." && pwd)
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
mkdir -p "$T/bin" "$T/repo"
git init -q "$T/repo"
bash "$KIT/install.sh" --hosts claude,pi "$T/repo" > "$T/install.log"
python3 "$KIT/tests/fixtures/install_worker_skills.py" "$T/repo"
export HOME="$T/home"
export SUPER_BOARD_SKILLS_HOME="$T/home"; mkdir -p "$SUPER_BOARD_SKILLS_HOME"
cat > "$T/bin/gh" <<'PY'
#!/usr/bin/env python3
import json,sys
args=sys.argv[1:]
if args and args[0]=='api' and '--slurp' in args:
 print('[[]]')
elif args[:2]==['issue','view']:
 print(json.dumps({'labels':[]} if args[args.index('--json')+1]=='labels' else {'number':int(args[2]),'title':'fixture','body':''}))
else: sys.exit('unexpected gh call '+str(args))
PY
cat > "$T/bin/pi" <<'PY'
#!/usr/bin/env python3
import json,os,re,sys,time,subprocess
from pathlib import Path
args=sys.argv[1:]; prompt=sys.stdin.read()
with open(os.environ['SB_PI_LOG'],'a') as log: log.write(json.dumps({'args':args,'prompt':prompt,'cwd':os.getcwd()})+'\n')
if os.environ.get('SB_PI_SLEEP'):
 p=subprocess.Popen([sys.executable,'-c','import signal,time; signal.signal(signal.SIGTERM, signal.SIG_IGN); time.sleep(60)']); Path(os.environ['SB_PI_PID']).write_text(str(p.pid)); time.sleep(60)
card=json.loads(re.search(r'^Card: (.+)$',prompt,re.M)[1]); lane=re.search(r'Run super-(build|qa|review)',prompt)[1]
print(os.environ.get('SB_PI_RESULT',json.dumps(dict(status='advanced',column={'build':'QA','qa':'Review','review':'Done'}[lane],detail='fixture',prUrl=None,branch=None,priorFindings=None))))
sys.exit(int(os.environ.get('SB_PI_EXIT','0')))
PY
chmod +x "$T/bin/gh" "$T/bin/pi"
export PATH="$T/bin:$PATH" SB_PI_LOG="$T/pi.jsonl"
cd "$T/repo"
printf '%s' '{"verify_commands":["git diff --check"],"pi":{"provider":"fixture-provider","model":"fixture-model"}}' > "$T/config.json"
CARD='{"number":1,"status":"Ready","labels":["docs"],"body":""}'
lane() { bash "$KIT/scripts/super-board-pi-lane.sh" --config "$T/config.json" --card "$CARD" --lane build --pi > "$T/out" 2> "$T/err"; }
lane || { cat "$T/out" "$T/err"; exit 1; }
jq -e '.status=="advanced" and .column=="QA"' "$T/out" >/dev/null
python3 - "$SB_PI_LOG" <<'PY'
import json,sys
c=json.loads(open(sys.argv[1]).readlines()[-1]); a=c['args']
for flag in ['--print','--no-extensions','--no-skills','--no-mcp','--extension','--skill']: assert flag in a,a
assert a[a.index('--mode')+1]=='text'
assert a[a.index('--provider')+1]=='fixture-provider'
assert a[a.index('--model')+1]=='fixture-model'
assert '--continue' not in a and '--resume' not in a and '--session' not in a
assert '--expect-head' in c['prompt'] or 'Builder' in c['prompt']
PY
for BAD in '' 'not JSON' '{"status":' '{"status":"advanced","column":"QA","detail":"fake"}' '[]'; do
 RC=0; SB_PI_RESULT="$BAD" lane || RC=$?
 [ "$RC" -eq 1 ]; jq -e '.status=="failed"' "$T/out" >/dev/null
done
RC=0; SB_PI_EXIT=1 lane || RC=$?
[ "$RC" -eq 1 ]; jq -e '.status=="failed"' "$T/out" >/dev/null
# Print may return valid-looking text and still report truncation/provider failure.
RC=0; SB_PI_EXIT=2 lane || RC=$?
[ "$RC" -eq 1 ]
# Missing resources block before model execution.
N=$(wc -l < "$SB_PI_LOG")
rm -f .agents/skills/super-build/SKILL.md .claude/skills/super-build/SKILL.md
RC=0; lane || RC=$?
[ "$RC" -eq 10 ]; [ "$(wc -l < "$SB_PI_LOG")" -eq "$N" ]
python3 "$KIT/tests/fixtures/install_worker_skills.py" "$T/repo"
rm .agents/hooks/guard-secrets.py
RC=0; lane || RC=$?
[ "$RC" -eq 78 ]; [ "$(wc -l < "$SB_PI_LOG")" -eq "$N" ]
cp "$KIT/hooks/guard-secrets.py" .agents/hooks/
# The selected Pi path uses the existing wave contract and fresh processes per lane.
bash "$KIT/scripts/super-board-codex-wave.sh" --config "$T/config.json" --cards "[$CARD]" --pi > "$T/out"
jq -e '.halted==false and .cards[0].lanesRun=="build:advanced → qa:advanced → review:advanced"' "$T/out" >/dev/null
# Direct lane interruption reaps Pi descendants and preserves owned work.
SB_PI_SLEEP=1 SB_PI_PID="$T/child.pid" lane & JOB=$!
for _ in {1..100}; do [ -s "$T/child.pid" ] && break; sleep 0.05; done
[ -s "$T/child.pid" ]
# JOB is the shell function, its child is the exec'd Python launcher.
LAUNCHER=$(pgrep -P "$JOB" | head -1)
kill -TERM "$LAUNCHER"
RC=0; wait "$JOB" || RC=$?
[ "$RC" -ne 0 ]
! kill -0 "$(cat "$T/child.pid")" 2>/dev/null
jq -e '.status=="halted"' "$T/out" >/dev/null
echo 'PASS: test-pi-lane.sh (print results/resources/wave/interruption)'
