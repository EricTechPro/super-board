#!/usr/bin/env python3
# Stubbed `codex exec` for the offline Codex lane/wave suites; behaviour set by SB_CODEX_TEST_* env vars.
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
elif os.environ.get('SB_CODEX_TEST_RESULT'):
    output.write_text(os.environ['SB_CODEX_TEST_RESULT'])
else:
    output.write_text(json.dumps(dict(status=status, column=column, detail=os.environ.get('SB_CODEX_TEST_DETAIL', 'stub lane result'), prUrl=None, branch=None, priorFindings=None)))
print('codex log noise must not appear in result stdout')
with open(os.environ['SB_CODEX_TEST_LOG'], 'a') as log:
    fcntl.flock(log, fcntl.LOCK_EX)
    counter.write_text(str(int(counter.read_text()) - 1))
sys.exit(int(os.environ.get('SB_CODEX_TEST_EXIT', '0')))
