#!/usr/bin/env bash
# One fresh Pi print-mode lane using the existing board lifecycle and result contract.
set -euo pipefail
exec python3 - "${BASH_SOURCE[0]}" "$@" <<'PY'
import argparse
import importlib.util
import json
import os
from pathlib import Path
import runpy
import signal
import subprocess
import sys

def fail(message, code=64):
    print(message, file=sys.stderr)
    sys.exit(code)

parser = argparse.ArgumentParser(description='Run one Pi board lane (no Claude sub-agents).')
parser.add_argument('--config', required=True)
parser.add_argument('--card', required=True, help='card JSON or a JSON file')
parser.add_argument('--lane', required=True, choices=['build', 'qa', 'review'])
parser.add_argument('--tier', choices=['low', 'medium', 'high'], help='wave compatibility; Pi uses the configured model')
parser.add_argument('--complexity', choices=['low', 'medium', 'high'], help='wave compatibility; Pi uses the configured model')
parser.add_argument('--pi', action='store_true', required=True)
parser.add_argument('--diagnosis', action='store_true', help='fresh read-only diagnosis, no lifecycle mutations')
args = parser.parse_args(sys.argv[2:])
script_path = Path(sys.argv[1]).resolve()
try:
    config_path = Path(args.config).resolve()
    config = json.loads(config_path.read_text())
    card = json.loads(args.card if args.card.lstrip().startswith('{') else Path(args.card).read_text())
    if not isinstance(config, dict) or not isinstance(card, dict):
        raise ValueError('config/card must be objects')
    if type(card.get('number')) is not int or card['number'] < 1 or not isinstance(card.get('status'), str):
        raise ValueError('card needs a positive issue number and status')
    pi_config = config.get('pi') or {}
    provider, model = pi_config.get('provider'), pi_config.get('model')
    if not all(isinstance(value, str) and value.strip() and not value.startswith('-') for value in [provider, model]):
        raise ValueError('pi.provider and pi.model must be explicit non-empty identifiers')
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

def git_path(option):
    return Path(subprocess.check_output(['git', 'rev-parse', option], text=True).strip()).resolve()

try:
    root = git_path('--show-toplevel')
    require_checkout = runpy.run_path(str(script_path.with_name('super-board-checkout.py')))['require_checkout']
    root = require_checkout(root, (config.get('repo') or {}).get('path'))
except subprocess.CalledProcessError:
    fail('Pi lane must start inside the target git repository')
except (OSError, ValueError) as error:
    fail(f'Invalid Pi lane input: {error}')
require_verification_ready()
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
prompt = f'''Run {skill} for issue #{card['number']} as a Pi lane worker.
The dispatcher owns canonical repair-state transitions for this wave. It persisted Card.repairReservation before dispatch when present. Consume that attempt once, write normal failure proof on the issue/PR and return the outcome. Do not reserve again or modify the canonical machine state or repair-count/phase labels; the dispatcher records completion. Initial implementation and read-only verification are not repairs. A fresh independent diagnosis must precede any final targeted repair. For phase final, target diagnosis_cause only and use diagnosis_test to falsify that cause before changing code.
First operation: recheck .claude/bin/super-board-skills-ready.py --root {root} --host pi --cards - --lane {args.lane} with the Card JSON below as a one-element stdin array, before worktree creation, classification or lifecycle writes. Exit 10 means status=halted, detail=skills-readiness:, preserve all state. Load resolved_path files and only declared fallback IDs from the report. Before activating any conditional helper, repeat with --require <exact-name>.
Resolved skill report: {json.dumps(skills)}
Config: {config_path}
Card: {json.dumps(card)}
Read .claude/skills/{skill}/SKILL.md and .claude/skills/super-board/references/run.md → {section} lifecycle; follow all its board, branch, worktree, comments, test and merge requirements.
Source .claude/bin/super-board-gh-guard.sh and use its quota checks. Required GitHub reads go through .claude/bin/super-board-github-read.py; a read that misses its --kind shape exits 64 for that call only and prints the valid form, so fix the read. Check --check before new writes, migrations and merges; exit 79 means status=halted, no more GitHub calls, preserve claims/worktree/card/approval. Never retry a mutation.
Use .claude/bin/super-board-card.sh for board reads/moves and .claude/bin/super-board-pr-body.sh for owned PR blocks; follow writing-standard.md and pr-author-notes.md.
Use your own worktree under .claude/worktrees/; never edit the main checkout. Clean up on ordinary exit, preserve work on halt/interruption.
Pi adaptation: do not launch a second lifecycle owner or reuse the Builder session for Review. Perform preflight, classification and truth-check duties in distinct evidence passes within this fresh lane session. This changes the execution host, never the evidence requirements, confidence threshold or merge policy.
Return JSON: status=advanced|bounced|blocked|human-gate|failed|halted; column=current board column; detail=one line; prUrl/branch when known, otherwise null; priorFindings=review counts or null. A non-advanced exit ends this card's lane chain. On merge-gate exit 9, return status=halted with detail starting exactly "verification-readiness:"; preserve work and never bounce/retry.
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

spec = importlib.util.spec_from_file_location('lane_result', script_path.with_name('super-board-lane-result.py'))
lane_result = importlib.util.module_from_spec(spec)
spec.loader.exec_module(lane_result)
schema, conforms = lane_result.schema, lane_result.conforms
child = None
def interrupted(signum, frame):
    if child is not None:
        try:
            os.killpg(child.pid, signal.SIGTERM)
        except ProcessLookupError:
            pass
        try:
            child.wait(timeout=0.5)
        except subprocess.TimeoutExpired:
            pass
        try:
            os.killpg(child.pid, signal.SIGKILL)
        except ProcessLookupError:
            pass
        child.wait()
    result('halted', 'lane interrupted; preserve claims and worktrees')
    sys.exit(128 + signum)
signal.signal(signal.SIGTERM, interrupted)
signal.signal(signal.SIGINT, interrupted)
guards = script_path.with_name('super-board-pi-guards.py')
extension = script_path.with_name('super-board-pi-guards.ts')
env = dict(os.environ, SUPER_BOARD_PI_ROOT=str(root), SUPER_BOARD_PI_PYTHON=sys.executable,
           SUPER_BOARD_PI_GUARDS=str(guards), SUPER_BOARD_HOST='pi')
if not extension.is_file() or subprocess.run([sys.executable, str(guards), '--check'], env=env, stdout=sys.stderr).returncode:
    result('halted', 'Pi guards unavailable or unsupported project hook; preserve claims and worktrees')
    sys.exit(78)
# Disable ambient resources; only the resolved skills and guard extension are loaded.
command = ['pi', '--print', '--mode', 'text', '--no-extensions', '--no-skills',
           '--no-prompt-templates', '--no-themes', '--no-mcp',
           '--extension', str(extension), '--tools', 'read' if args.diagnosis else 'read,bash,edit,write',
           '--provider', provider, '--model', model]
for path in dict.fromkeys(e['resolved_path'] for e in skills['entries'] if e.get('resolved_path')):
    command += ['--skill', path]
if args.diagnosis:
    prompt = f'''You are a fresh independent read-only diagnostician for issue #{card['number']}.
Read the supplied accepted behavior, failure proof and all prior attempted causes from the Card below.
Use only read to inspect relevant source. Do not modify files, execute commands, push, merge, or write lifecycle state.
Identify a different cause, and a falsifying test command with its expected result.
The test must be a directly executable shell command. Use single quotes around Python code, without escaped outer quotes. A changed stack frame/hash is insufficient.
Return the existing lane JSON with status advanced, column {column}, prUrl/branch/priorFindings null.
Put a JSON string object with cause, test, expected in detail. Use empty strings if there is no new testable cause.
Card: {json.dumps(card)}
Resolved skills: {json.dumps(skills)}
'''
prompt += '\nReturn exactly one JSON object and no Markdown, logs or prose. Schema: ' + json.dumps(schema) + '\n'
try:
    child = subprocess.Popen(command, stdin=subprocess.PIPE, stdout=subprocess.PIPE, text=True, cwd=root, env=env,
                             start_new_session=True)
    stdout, _ = child.communicate(prompt)
    require_verification_ready()
    if child.returncode:
        result('halted' if child.returncode in (9, 10, 79) else 'failed',
               'verification-readiness: repair verify_commands and restart explicitly; preserve work'
               if child.returncode == 9 else 'skills-readiness: required skills became unavailable; preserve work'
               if child.returncode == 10 else f'pi --print exited {child.returncode}; preserve work')
        sys.exit(child.returncode if child.returncode in (9, 10, 79) else 1)
    parsed = json.loads(stdout)
    if not conforms(parsed, schema):
        raise ValueError('lane result does not match the lane schema')
    print(json.dumps(parsed))
    sys.exit(10 if parsed['status'] == 'halted' and parsed['detail'].startswith('skills-readiness:')
             else 9 if parsed['status'] == 'halted' and parsed['detail'].startswith('verification-readiness:')
             else 79 if parsed['status'] == 'halted' else 0)
except (OSError, ValueError) as error:
    result('failed', f'Pi returned no valid lane result: {error}; preserve work')
    sys.exit(1)
