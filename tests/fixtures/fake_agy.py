#!/usr/bin/env python3
# Stubbed `agy -p` for the offline Antigravity lane/wave suites; behaviour set by SB_AGY_TEST_* env vars.
# Prints the one JSON line agy 1.4.6 prints: {conversation_id, status, response, structured_output, ...}.
import json, os, re, sys, time
from pathlib import Path
args = sys.argv[1:]
def opt(name, default=None):
    return args[args.index(name) + 1] if name in args else default
prompt = opt('-p') or ''
log = os.environ['SB_AGY_TEST_LOG']
if 'Grade complexity' in prompt:
    with open(log, 'a') as stream:
        stream.write(json.dumps(dict(args=args, number=int(re.search(r'issue #(\d+)', prompt).group(1)), lane='grade', active=1)) + '\n')
    grade = os.environ.get('SB_AGY_TEST_GRADE', 'medium')
    status = os.environ.get('SB_AGY_TEST_GRADE_STATUS', 'SUCCESS')
    print(json.dumps(dict(conversation_id='g', status=status, response='', structured_output=dict(complexity=grade))))
    sys.exit(int(os.environ.get('SB_AGY_TEST_GRADE_EXIT', '0')))
# The pointer prompt names the brief file; the brief carries the card and the lane.
brief = Path(re.search(r'^Read (\S+) and follow it', prompt).group(1)).read_text(encoding='utf-8')
card = json.loads(re.search(r'^Card: (.+)$', brief, re.M).group(1))
lane = re.search(r'Run super-(build|qa|review)', brief).group(1)
counter = Path(log + '.active')
active = int(counter.read_text()) + 1 if counter.exists() else 1
counter.write_text(str(active))
with open(log, 'a') as stream:
    stream.write(json.dumps(dict(args=args, prompt=brief, number=card['number'], lane=lane, active=active,
                                 schema=json.load(open(opt('--json-schema'))) if opt('--json-schema') else None)) + '\n')
if os.environ.get('SB_AGY_TEST_SLEEP'):
    time.sleep(60)
time.sleep(float(os.environ.get('SB_AGY_TEST_DELAY', '0')))
status = os.environ.get('SB_AGY_TEST_STATUS', 'advanced')
column = {'build': 'QA', 'qa': 'Review', 'review': 'Done'}[lane] if status == 'advanced' else card['status']
run = dict(conversation_id='t', status=os.environ.get('SB_AGY_TEST_RUN_STATUS', 'SUCCESS'), response='',
           duration_seconds=1.0, num_turns=1, usage=dict(input_tokens=1, output_tokens=1, thinking_tokens=0, cache_read_tokens=0, total_tokens=2))
if os.environ.get('SB_AGY_TEST_ERROR'):
    run['error'] = os.environ['SB_AGY_TEST_ERROR']
if os.environ.get('SB_AGY_TEST_DENIED'):
    run['denied_actions'] = [dict(action='command', display_name='RunCommand')] * int(os.environ['SB_AGY_TEST_DENIED'])
if os.environ.get('SB_AGY_TEST_NO_OUTPUT'):
    pass
elif os.environ.get('SB_AGY_TEST_RESULT'):
    run['structured_output'] = json.loads(os.environ['SB_AGY_TEST_RESULT'])
else:
    run['structured_output'] = dict(status=status, column=column, detail=os.environ.get('SB_AGY_TEST_DETAIL', 'stub lane result'),
                                    prUrl=None, branch=None, priorFindings=None)
print('agy log noise must not appear in the result line', file=sys.stderr)
if os.environ.get('SB_AGY_TEST_STDERR'):
    print(os.environ['SB_AGY_TEST_STDERR'], file=sys.stderr)
print(json.dumps(run))
counter.write_text(str(int(counter.read_text()) - 1))
sys.exit(int(os.environ.get('SB_AGY_TEST_EXIT', '0')))
