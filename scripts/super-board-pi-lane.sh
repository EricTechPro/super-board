#!/usr/bin/env bash
# One headless Pi lane. --pi is the run owner's explicit opt-in; a Pi-host
# session counts as explicit (see references/run-workflow.md → "Pi runs").
# Without --pi the lane refuses (exit 78): unlike Codex there is no
# Claude-usage fallback chain that could start Pi on its own.
# Usage: --config f --card '<JSON>' --lane build|qa|review [--pi[=model]]
#        [--tier low|medium|high] [--complexity low|medium|high]
# Model: --pi=<model>, else pi.model, else pi.ladders (config) or PI_LADDERS
# [tier][complexity] when --tier is given (an ungraded card takes the medium
# cell), else Pi's own default model.
# Result: Pi has no --output-schema/--output-last-message flags, so the worker
# is told to write its final JSON to a private file and the wrapper validates
# it fail-closed, exactly like the Codex lane validates its schema output.
set -euo pipefail
exec python3 - "${BASH_SOURCE[0]}" "$@" <<'PY'
import argparse
import importlib.util
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

parser = argparse.ArgumentParser(description='Run one Pi board lane (no Claude sub-agents).')
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
    if arg == '--pi':
        explicit = True
    elif arg.startswith('--pi='):
        explicit = True
        model = arg.partition('=')[2]
        if not model.strip():
            fail('--pi=<model> requires a non-empty model')
    else:
        rest.append(arg)
args = parser.parse_args(rest)
script_path = Path(sys.argv[1]).resolve()
if not explicit:
    # Review and merge ownership always need the run owner's explicit choice;
    # build/qa have no Pi fallback path either, so every non-explicit start is
    # a mistake rather than a degrade.
    if args.lane == 'review':
        fail('Pi review refused: run must be started with explicit --pi; no fallback backend can own a merge.', 78)
    fail('Pi lane refused: pass --pi (or run from a Pi session) — there is no Pi usage fallback.', 78)
try:
    config_path = Path(args.config).resolve()
    config = json.loads(config_path.read_text())
    card = json.loads(args.card if args.card.lstrip().startswith('{') else Path(args.card).read_text())
    if not isinstance(config, dict) or not isinstance(card, dict):
        raise ValueError('config/card must be objects')
    if type(card.get('number')) is not int or card['number'] < 1 or not isinstance(card.get('status'), str):
        raise ValueError('card needs a positive issue number and status')
    configured = config.get('pi', {}).get('model') if config.get('pi') else None
    if configured is not None and not isinstance(configured, str):
        raise ValueError('pi.model must be a string')
    model = model if model is not None else (configured if configured and configured.strip() else None)
    # Pi run ladders, the one copy: run tier x card complexity -> `pi --model`.
    # Pi resolves patterns fuzzily across whatever providers the user connected,
    # so the defaults are the Claude-family names with an optional `:thinking`
    # suffix; boards on other providers override pi.ladders in the config.
    PI_LADDERS = {
        'low': {'low': 'haiku', 'medium': 'sonnet', 'high': 'sonnet'},
        'medium': {'low': 'sonnet', 'medium': 'sonnet', 'high': 'opus'},
        'high': {'low': 'opus', 'medium': 'opus', 'high': 'opus'},
    }
    configured_ladders = (config.get('pi') or {}).get('ladders')
    if configured_ladders is not None:
        if (not isinstance(configured_ladders, dict) or sorted(configured_ladders) != sorted(PI_LADDERS)
                or any(not isinstance(row, dict) or sorted(row) != ['high', 'low', 'medium']
                       or not all(isinstance(value, str) and value.strip() for value in row.values())
                       for row in configured_ladders.values())):
            raise ValueError('pi.ladders must mirror the ladder shape with non-empty string models')
        PI_LADDERS = configured_ladders
    if model is None and args.tier:
        model = PI_LADDERS[args.tier][args.complexity or 'medium']
except (OSError, ValueError, AttributeError) as error:
    fail(f'Invalid Pi lane input: {error}')

column = card['status']
def result(status, detail):
    print(json.dumps({'status': status, 'column': column, 'detail': detail}))

readiness = script_path.with_name('super-board-verification-ready.py')
def require_verification_ready():
    if subprocess.run([sys.executable, str(readiness), '--config', str(config_path)]).returncode:
        result('halted', 'verification-readiness: repair verify_commands; preserve claims, worktrees and card state, then restart explicitly')
        sys.exit(9)
require_verification_ready()

def git_path(option):
    return Path(subprocess.check_output(['git', 'rev-parse', option], text=True).strip()).resolve()

try:
    root = git_path('--show-toplevel')
    git_dir = git_path('--git-dir')
    common_dir = git_path('--git-common-dir')
except subprocess.CalledProcessError:
    fail('Pi lane must start inside the target git repository')
os.chdir(root)
helper = script_path.with_name('super-board-github-read.py')
if not helper.exists() or subprocess.run([sys.executable, str(helper), '--check']).returncode:
    result('halted', 'required GitHub reads halted or helper missing; preserve claims and worktrees')
    sys.exit(79)

resolver_path = script_path.with_name('super-board-skills-ready.py')
try:
    spec = importlib.util.spec_from_file_location('skills_ready', resolver_path)
    resolver = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(resolver)
    resolver.hydrate([card], root)
    skills = resolver.report(root, 'pi', [card], lane=args.lane,
                             home=os.environ.get('SUPER_BOARD_SKILLS_HOME'), catalog=os.environ.get('SUPER_BOARD_SKILLS_CATALOG'))
except SystemExit as error:
    result('halted', 'required GitHub reads halted while hydrating skills; preserve claims and worktrees')
    sys.exit(error.code)
except (OSError, ValueError, TypeError, KeyError) as error:
    result('halted', 'skills-readiness: ' + str(error))
    sys.exit(64)
if not skills['ready']:
    result('halted', 'skills-readiness: missing ' + ', '.join(dict.fromkeys(e['name'] for e in skills['entries'] if e['status'] == 'missing')))
    sys.exit(10)

skill = {'build': 'super-build', 'qa': 'super-qa', 'review': 'super-review'}[args.lane]
section = {'build': 'Builder', 'qa': 'Tester', 'review': 'Reviewer'}[args.lane]

# The launcher's own model/flag contract, split from the prompt so both the
# review consent text and the result-file path can reference them.
counts = {key: {'type': 'integer'} for key in ['fixed', 'notFixed', 'noLongerApplies']}
properties = {
    'status': {'type': 'string', 'enum': ['advanced', 'bounced', 'blocked', 'human-gate', 'failed', 'halted']},
    'column': {'type': 'string'}, 'detail': {'type': 'string'},
    'prUrl': {'type': ['string', 'null']}, 'branch': {'type': ['string', 'null']},
    'priorFindings': {'anyOf': [{'type': 'null'}, {'type': 'object', 'properties': counts,
                      'required': list(counts), 'additionalProperties': False}]},
}
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
with tempfile.TemporaryDirectory(prefix='super-board-pi-') as temporary:
    result_path = Path(temporary) / 'result.json'
    prompt = f'''Run {skill} for issue #{card['number']} as a Pi lane worker.
First operation: recheck .claude/bin/super-board-skills-ready.py --root {root} --host pi --cards - --lane {args.lane} with the Card JSON below as a one-element stdin array, before worktree creation, classification or lifecycle writes. Exit 10 means status=halted, detail=skills-readiness:, preserve all state. Load resolved_path files and only declared fallback IDs from the report. Before activating any conditional helper, repeat with --require <exact-name>.
Resolved skill report: {json.dumps(skills)}
Config: {config_path}
Card: {json.dumps(card)}
Read .claude/skills/{skill}/SKILL.md and .claude/skills/super-board/references/run.md → {section} lifecycle; follow all its board, branch, worktree, comments, test and merge requirements.
Source .claude/bin/super-board-gh-guard.sh and use its quota checks. Required GitHub reads go through .claude/bin/super-board-github-read.py; a read that misses its --kind shape exits 64 for that call only and prints the valid form, so fix the read. Check --check before new writes, migrations and merges; exit 79 means status=halted, no more GitHub calls, preserve claims/worktree/card/approval. Never retry a mutation.
Use .claude/bin/super-board-card.sh for board reads/moves and .claude/bin/super-board-pr-body.sh for owned PR blocks; follow writing-standard.md and pr-author-notes.md.
Use your own worktree under .claude/worktrees/; never edit the main checkout. Clean up on ordinary exit, preserve work on halt/interruption.
Pi adaptation: do not launch Claude or other sub-agents. Perform preflight, classification, independent review and truth-check duties inline. This changes the execution host, never the evidence requirements, confidence threshold or merge policy.
Result file: {result_path}
Write your final JSON object (no other content) to the Result file above with the write tool as your last action; do not print it to stdout. Shape: status=advanced|bounced|blocked|human-gate|failed|halted; column=current board column; detail=one line; prUrl/branch when known, otherwise null; priorFindings=review counts or null. A non-advanced exit ends this card's lane chain. On merge-gate exit 9, return status=halted with detail starting exactly "verification-readiness:"; preserve work and never bounce/retry.
'''
    if args.lane == 'build':
        prompt += '''Before creating any worktree or changing code, perform run.md's Builder pre-flight inline: call super-board-preflight.sh, judge its candidates semantically, and act on proceed/hold/sequence/skipped. Blind preflight leaves Ready and returns failed. Your own issue branch PR is not a duplicate. Read the issue and all comments; preserve qa/bug/feature labels. Existing docs/ux/tests/refactor/tech-debt rows keep their label chain: classify complexity without adding feature/bug. If truly untyped, classify feature or bug, re-run skills-ready on the proposed labelled card before adding that label, never qa. Then follow the Builder lifecycle.
'''
    elif args.lane == 'qa' and card['status'] == 'Ready':
        prompt += 'This qa-labelled Ready card skips Building: move Ready → QA and create the issue branch from the base; test the existing product per run.md qa cards.\n'
    elif args.lane == 'review':
        prompt += '''The owner explicitly chose run --pi: you may review and own the merge. First load the latest <!-- super-review:report -->; grade prior R-ids fixed/not fixed/no longer applies, bounce any not fixed and edit the same report in place. Form hypotheses from the issue AC and diff before reading the Builder narrative.
Rerun the Tester's tests. When truth_gate triggers, apply super-review's fixed Adversarial mode brief inline in two distinct passes (code-grounder and historian); collect evidence and aggregate confidence against truth_threshold. Over-engineering is Should fix, never Blocker alone and never lowers confidence. Missing evidence fails closed.
Merge ONLY through the unchanged .claude/bin/super-board-merge-gate.sh, pinning the exact head you reviewed at review pass using --expect-head "$HEAD" --config <config> --pr <N> --subject <title> --body-file <msg.md>. Never run bare gh pr merge or bypass the gate. Follow run.md Merge protocol and route every gate exit exactly: 2/5 rebase pass, 3 Blocked, 4 stay Review, 6 fresh review, 7/8 human gate with pinned approval-request; 9 verification-readiness means halt and preserve card/worktree/approval/claims until config repair and explicit restart, never a Build bounce or rebase retry. Respect human_approves_merge and merge_policy. Confirm MERGED <sha>, fetch base and prove merge-base --is-ancestor <sha> origin/<base> before closing issue or moving Done.
'''
    # Pi needs no sandbox flags: it has no approval system, and the project's
    # guard extension plus the worktree contract carry the same protections.
    # -a trusts this repository's project config so .pi/extensions (guards) and
    # project skills load; the tool allowlist keeps the lane deterministic.
    command = ['pi', '-p', '-a', '--tools', 'read,bash,edit,write,grep,find,ls']
    if model and model.strip():
        command += ['--model', model]
    command.append(prompt)
    try:
        child = subprocess.Popen(command, stdout=sys.stderr, text=True)
        child.wait()
        require_verification_ready()
        if child.returncode:
            result('halted' if child.returncode in (9, 10, 79) else 'failed',
                   'verification-readiness: repair verify_commands and restart explicitly; preserve work'
                   if child.returncode == 9 else 'skills-readiness: required skills became unavailable; preserve work' if child.returncode == 10 else f'pi exited {child.returncode}')
            sys.exit(child.returncode if child.returncode in (9, 10, 79) else 1)
        parsed = json.loads(result_path.read_text())
        if (not isinstance(parsed, dict) or parsed.get('status') not in properties['status']['enum']
                or not all(isinstance(parsed.get(key), str) for key in ['column', 'detail'])):
            raise ValueError('lane result needs status, column and detail')
        print(json.dumps(parsed))
        sys.exit(10 if parsed['status'] == 'halted' and parsed['detail'].startswith('skills-readiness:')
                 else 9 if parsed['status'] == 'halted' and parsed['detail'].startswith('verification-readiness:')
                 else 79 if parsed['status'] == 'halted' else 0)
    except (OSError, ValueError) as error:
        result('failed', f'Pi returned no valid lane result: {error}')
        sys.exit(1)
PY
