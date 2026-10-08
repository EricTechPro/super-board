#!/usr/bin/env bash
# One headless lane. --codex is the run owner's explicit opt-in; without it,
# usage fallback may build/test but must never own a review or merge.
# Without --codex the board config must say "usage_fallback": "codex" (exit 78 otherwise).
# Usage: --config f --card '<JSON>' --lane build|qa|review [--codex[=model]]
#        [--tier low|medium|high] [--complexity low|medium|high]
# Model: --codex=<model>, else codex.model, else CODEX_LADDERS[tier][complexity]
# when --tier is given (an ungraded card takes the medium cell), else Codex's default.
set -euo pipefail
exec python3 - "${BASH_SOURCE[0]}" "$@" <<'PY'
import argparse
import json
import os
from pathlib import Path
import signal
import subprocess
import sys
import tempfile

def fail(message, code=64):
    print(message, file=sys.stderr)
    sys.exit(code)

parser = argparse.ArgumentParser(description='Run one Codex board lane (no Claude sub-agents).')
parser.add_argument('--config', required=True)
parser.add_argument('--card', required=True, help='card JSON or a JSON file')
parser.add_argument('--lane', required=True, choices=['build', 'qa', 'review'])
parser.add_argument('--tier', choices=['low', 'medium', 'high'], help='run ladder (--low / default / --high)')
parser.add_argument('--complexity', choices=['low', 'medium', 'high'], help="router's grade for this card")
raw = sys.argv[2:]
explicit = False
model = None
rest = []
for arg in raw:
    if arg == '--codex':
        explicit = True
    elif arg.startswith('--codex='):
        explicit = True
        model = arg.partition('=')[2]
        if not model.strip():
            fail('--codex=<model> requires a non-empty model')
    else:
        rest.append(arg)
args = parser.parse_args(rest)
script_path = Path(sys.argv[1]).resolve()
if args.lane == 'review' and not explicit:
    fail('Codex review refused: run must be started with explicit --codex; usage fallback cannot review.', 78)
try:
    config_path = Path(args.config).resolve()
    config = json.loads(config_path.read_text())
    card = json.loads(args.card if args.card.lstrip().startswith('{') else Path(args.card).read_text())
    if not isinstance(config, dict) or not isinstance(card, dict):
        raise ValueError('config/card must be objects')
    if type(card.get('number')) is not int or card['number'] < 1 or not isinstance(card.get('status'), str):
        raise ValueError('card needs a positive issue number and status')
    configured = config.get('codex', {}).get('model') if config.get('codex') else None
    if configured is not None and not isinstance(configured, str):
        raise ValueError('codex.model must be a string')
    model = model if model is not None else (configured if configured and configured.strip() else None)
    # Codex run ladders, the one copy: run tier x card complexity -> model.
    # Mirrors the Claude LADDERS in workflows/super-board-wave.js. gpt-6.1-sol
    # ties gpt-6-astra on DeepSWE v1.1 (75.2% vs 74.1-74.8%) at a fifth of the
    # price, so it carries the default; Astra takes hard cards and --high.
    CODEX_LADDERS = {
        'low': {'low': 'gpt-6-luna', 'medium': 'gpt-6.1-sol', 'high': 'gpt-6.1-sol'},
        'medium': {'low': 'gpt-6.1-sol', 'medium': 'gpt-6.1-sol', 'high': 'gpt-6-astra'},
        'high': {'low': 'gpt-6-astra', 'medium': 'gpt-6-astra', 'high': 'gpt-6-astra'},
    }
    if model is None and args.tier:
        model = CODEX_LADDERS[args.tier][args.complexity or 'medium']
except (OSError, ValueError, AttributeError) as error:
    fail(f'Invalid Codex lane input: {error}')
# Without --codex this is the usage fallback, and that is opt-in per board.
if not explicit and config.get('usage_fallback', 'none') != 'codex':
    fail(f'Codex fallback refused: usage_fallback is not "codex" in {config_path}; pass --codex for an explicit Codex run.', 78)

def git_path(option):
    return Path(subprocess.check_output(['git', 'rev-parse', option], text=True).strip()).resolve()

try:
    root = git_path('--show-toplevel')
    git_dir = git_path('--git-dir')
    common_dir = git_path('--git-common-dir')
except subprocess.CalledProcessError:
    fail('Codex lane must start inside the target git repository')
os.chdir(root)
helper = script_path.with_name('super-board-github-read.py')
column = card['status']
def result(status, detail):
    print(json.dumps({'status': status, 'column': column, 'detail': detail}))

if not helper.exists() or subprocess.run([sys.executable, str(helper), '--check']).returncode:
    result('halted', 'required GitHub reads halted or helper missing; preserve claims and worktrees')
    sys.exit(79)

skill = {'build': 'super-build', 'qa': 'super-qa', 'review': 'super-review'}[args.lane]
section = {'build': 'Builder', 'qa': 'Tester', 'review': 'Reviewer'}[args.lane]
prompt = f'''Run {skill} for issue #{card['number']} as a Codex lane worker.
Config: {config_path}
Card: {json.dumps(card)}
Read .claude/skills/{skill}/SKILL.md and .claude/skills/super-board/references/run.md → {section} lifecycle; follow all its board, branch, worktree, comments, test and merge requirements.
Source .claude/bin/super-board-gh-guard.sh and use its quota checks. Required GitHub reads go through .claude/bin/super-board-github-read.py; a read that misses its --kind shape exits 64 for that call only and prints the valid form, so fix the read. Check --check before new writes, migrations and merges; exit 79 means status=halted, no more GitHub calls, preserve claims/worktree/card/approval. Never retry a mutation.
Use .claude/bin/super-board-card.sh for board reads/moves and .claude/bin/super-board-pr-body.sh for owned PR blocks; follow writing-standard.md and pr-author-notes.md.
Use your own worktree under .claude/worktrees/; never edit the main checkout. Clean up on ordinary exit, preserve work on halt/interruption.
Codex adaptation: do not launch Claude or other sub-agents. Perform preflight, classification, independent review and truth-check duties inline. This changes the execution host, never the evidence requirements, confidence threshold or merge policy.
Return JSON: status=advanced|bounced|blocked|human-gate|failed|halted; column=current board column; detail=one line; prUrl/branch when known, otherwise null; priorFindings=review counts or null. A non-advanced exit ends this card's lane chain.
'''
if args.lane == 'build':
    prompt += '''Before creating any worktree or changing code, perform run.md's Builder pre-flight inline: call super-board-preflight.sh, judge its candidates semantically, and act on proceed/hold/sequence/skipped. Blind preflight leaves Ready and returns failed. Your own issue branch PR is not a duplicate. Read the issue and all comments; preserve qa/bug/feature labels. If untyped, classify feature or bug and add that label, never qa. Then follow the Builder lifecycle.
'''
elif args.lane == 'qa' and card['status'] == 'Ready':
    prompt += 'This qa-labelled Ready card skips Building: move Ready → QA and create the issue branch from the base; test the existing product per run.md qa cards.\n'
elif args.lane == 'review':
    prompt += '''The owner explicitly chose run --codex: you may review and own the merge. First load the latest <!-- super-review:report -->; grade prior R-ids fixed/not fixed/no longer applies, bounce any not fixed and edit the same report in place. Form hypotheses from the issue AC and diff before reading the Builder narrative.
Rerun the Tester's tests. When truth_gate triggers, apply super-review's fixed Adversarial mode brief inline in two distinct passes (code-grounder and historian); collect evidence and aggregate confidence against truth_threshold. Over-engineering is Should fix, never Blocker alone and never lowers confidence. Missing evidence fails closed.
Merge ONLY through the unchanged .claude/bin/super-board-merge-gate.sh, pinning the exact head you reviewed at review pass using --expect-head "$HEAD" --config <config> --pr <N> --subject <title> --body-file <msg.md>. Never run bare gh pr merge or bypass the gate. Follow run.md Merge protocol and route every gate exit exactly: 2/5 rebase pass, 3 Blocked, 4 stay Review, 6 fresh review, 7/8 human gate with pinned approval-request. Respect human_approves_merge and merge_policy. Confirm MERGED <sha>, fetch base and prove merge-base --is-ancestor <sha> origin/<base> before closing issue or moving Done.
'''

counts = {key: {'type': 'integer'} for key in ['fixed', 'notFixed', 'noLongerApplies']}
properties = {
    'status': {'type': 'string', 'enum': ['advanced', 'bounced', 'blocked', 'human-gate', 'failed', 'halted']},
    'column': {'type': 'string'}, 'detail': {'type': 'string'},
    'prUrl': {'type': ['string', 'null']}, 'branch': {'type': ['string', 'null']},
    'priorFindings': {'anyOf': [{'type': 'null'}, {'type': 'object', 'properties': counts,
                      'required': list(counts), 'additionalProperties': False}]},
}
schema = {'type': 'object', 'properties': properties, 'required': list(properties), 'additionalProperties': False}
child = None
def interrupted(signum, frame):
    if child is not None:
        child.terminate()
        try:
            child.wait(timeout=2)
        except subprocess.TimeoutExpired:
            child.kill()
            child.wait()
    result('halted', 'lane interrupted; preserve claims and worktrees')
    sys.exit(128 + signum)
signal.signal(signal.SIGTERM, interrupted)
signal.signal(signal.SIGINT, interrupted)
with tempfile.TemporaryDirectory(prefix='super-board-codex-') as temporary:
    schema_path = Path(temporary) / 'schema.json'
    output = Path(temporary) / 'result.json'
    schema_path.write_text(json.dumps(schema))
    # A custom profile deliberately does NOT extend :workspace, which protects
    # .git as read-only. Explicit git/common-dir grants also cover submodules.
    # https://learn.chatgpt.com/docs/permissions → File access limited to workspace
    filesystem = {':root': 'read', ':slash_tmp': 'write', ':tmpdir': 'write',
                  str(root): 'write', str(git_dir): 'write', str(common_dir): 'write'}
    grants = '{' + ', '.join(json.dumps(key) + '=' + json.dumps(value) for key, value in filesystem.items()) + '}'
    command = ['codex', 'exec', '-C', str(root), '-c', 'approval_policy="never"',
               '-c', 'default_permissions="super-board-lane"',
               '-c', 'permissions.super-board-lane.filesystem=' + grants,
               '-c', 'permissions.super-board-lane.network.enabled=true',
               '--output-schema', str(schema_path), '--output-last-message', str(output), '-']
    if model and model.strip():
        command[2:2] = ['-m', model]
    try:
        child = subprocess.Popen(command, stdin=subprocess.PIPE, stdout=sys.stderr, text=True)
        child.communicate(prompt)
        if child.returncode:
            result('halted' if child.returncode == 79 else 'failed', f'codex exec exited {child.returncode}')
            sys.exit(child.returncode if child.returncode == 79 else 1)
        parsed = json.loads(output.read_text())
        if (not isinstance(parsed, dict) or parsed.get('status') not in properties['status']['enum']
                or not all(isinstance(parsed.get(key), str) for key in ['column', 'detail'])):
            raise ValueError('lane result needs status, column and detail')
        print(json.dumps(parsed))
        sys.exit(79 if parsed['status'] == 'halted' else 0)
    except (OSError, ValueError) as error:
        result('failed', f'Codex returned no valid lane result: {error}')
        sys.exit(1)
PY
