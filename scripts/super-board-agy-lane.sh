#!/usr/bin/env bash
# One headless lane on Google Antigravity (`agy -p`). Mirrors super-board-codex-lane.sh:
# --agy is the run owner's explicit opt-in; without it, usage fallback may build/test
# but must never own a review or merge. Without --agy the board config must say
# "usage_fallback": "agy" (exit 78 otherwise).
# Usage: --config f --card '<JSON>' --lane build|qa|review [--agy[=model]]
#        [--tier low|medium|high] [--complexity low|medium|high]
# Model:  --agy=<model>, else agy.model, else agy.ladder[tier][complexity], else the CLI default.
# Effort: agy.effort, else review → high, else AGY_EFFORT[tier][complexity], passed as
#         --effort. A slug that already names an effort (gemini-3.8-flash-low) gets no
#         --effort: agy 1.4.6 refuses the pair as a conflict.
#
# HOW agy IS CALLED (verified on agy 1.4.6):
#   agy -p <pointer> --output-format json --json-schema <file> --print-timeout <agy.timeout>
#       [--model <slug>] [--effort low|medium|high|xhigh|max]
# The brief is a file under .claude/super-board/inflight/ (the pointer prompt names it:
# a Windows command line caps at 8 KB). agy has no working-directory flag, so this script
# chdirs to the repo root first. The run prints one JSON line: {status, response,
# structured_output?, denied_actions?, error?, ...}; the lane result is `structured_output`,
# checked against the lane schema like the Codex lane does. Anything else fails closed and
# keeps the raw run under .claude/super-board/inflight/agy-<n>-<lane>.last.json so the
# cause (prose answer, backend retry, denied tool) can be read afterwards.
# Headless agy auto-denies every tool call that permissions.allow does not cover and still
# exits 0: `denied_actions` in the run names them, and the lane adds a ⚠️ to its detail.
# Over quota agy exits 3 with status ERROR / RESOURCE_EXHAUSTED: that is a halt (79), not a
# failure. SB_AGY_BIN overrides the binary with a full command line (tests).
set -euo pipefail
exec python3 - "${BASH_SOURCE[0]}" "$@" <<'PY'
import argparse
import importlib.util
import json
import os
from pathlib import Path
import re
import shlex
import shutil
import signal
import subprocess
import sys
import tempfile

def fail(message, code=64):
    print(message, file=sys.stderr)
    sys.exit(code)

parser = argparse.ArgumentParser(description='Run one Antigravity board lane (agy -p, no sub-agents).')
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
    if arg == '--agy':
        explicit = True
    elif arg.startswith('--agy='):
        explicit = True
        model = arg.partition('=')[2]
        if not model.strip():
            fail('--agy=<model> requires a non-empty model')
    else:
        rest.append(arg)
args = parser.parse_args(rest)
script_path = Path(sys.argv[1]).resolve()
if args.lane == 'review' and not explicit:
    fail('Antigravity review refused: run must be started with explicit --agy; usage fallback cannot review.', 78)
EFFORTS = ['low', 'medium', 'high', 'xhigh', 'max']
# Effort ladder, the one copy: run tier x card complexity -> --effort. Review is always high.
AGY_EFFORT = {
    'low': {'low': 'low', 'medium': 'low', 'high': 'medium'},
    'medium': {'low': 'low', 'medium': 'medium', 'high': 'high'},
    'high': {'low': 'medium', 'medium': 'high', 'high': 'high'},
}
try:
    config_path = Path(args.config).resolve()
    config = json.loads(config_path.read_text())
    card = json.loads(args.card if args.card.lstrip().startswith('{') else Path(args.card).read_text())
    if not isinstance(config, dict) or not isinstance(card, dict):
        raise ValueError('config/card must be objects')
    if type(card.get('number')) is not int or card['number'] < 1 or not isinstance(card.get('status'), str):
        raise ValueError('card needs a positive issue number and status')
    agy = config.get('agy') or {}
    if not isinstance(agy, dict):
        raise ValueError('agy must be an object')
    for key in ('model', 'effort', 'timeout', 'router_model'):
        if agy.get(key) is not None and not isinstance(agy[key], str):
            raise ValueError(f'agy.{key} must be a string')
    if agy.get('effort') and agy['effort'] not in EFFORTS:
        raise ValueError('agy.effort must be one of ' + ', '.join(EFFORTS))
    ladder = agy.get('ladder')
    if ladder is not None and not isinstance(ladder, dict):
        raise ValueError('agy.ladder must be an object of tier -> grade -> model')
    grade = args.complexity or 'medium'
    configured = agy.get('model')
    model = model if model is not None else (configured if configured and configured.strip() else None)
    if model is None and args.tier and ladder:
        cell = (ladder.get(args.tier) or {}).get(grade)
        model = cell if isinstance(cell, str) and cell.strip() else None
    effort = agy.get('effort') or ('high' if args.lane == 'review' else AGY_EFFORT[args.tier][grade] if args.tier else None)
    if model and re.search(r'-(low|medium|high|xhigh|max)$', model):
        effort = None  # the slug carries the effort; --effort would conflict
    timeout = agy.get('timeout') or '120m'
except (OSError, ValueError, AttributeError, KeyError) as error:
    fail(f'Invalid Antigravity lane input: {error}')
# Without --agy this is the usage fallback, and that is opt-in per board.
if not explicit and config.get('usage_fallback', 'none') != 'agy':
    fail(f'Antigravity fallback refused: usage_fallback is not "agy" in {config_path}; pass --agy for an explicit Antigravity run.', 78)

column = card['status']
def result(status, detail):
    print(json.dumps({'status': status, 'column': column, 'detail': detail}))

readiness = script_path.with_name('super-board-verification-ready.py')
def require_verification_ready():
    if subprocess.run([sys.executable, str(readiness), '--config', str(config_path)]).returncode:
        result('halted', 'verification-readiness: repair verify_commands; preserve claims, worktrees and card state, then restart explicitly')
        sys.exit(9)
require_verification_ready()

try:
    root = Path(subprocess.check_output(['git', 'rev-parse', '--show-toplevel'], text=True).strip()).resolve()
except subprocess.CalledProcessError:
    fail('Antigravity lane must start inside the target git repository')
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
    skills = resolver.report(root, 'agy', [card], lane=args.lane,
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
py = 'python' if os.name == 'nt' else 'python3'
prompt = f'''Run {skill} for issue #{card['number']} as an Antigravity lane worker.
First operation: recheck .claude/bin/super-board-skills-ready.py --root {root} --host agy --cards - --lane {args.lane} with the Card JSON below as a one-element stdin array, before worktree creation, classification or lifecycle writes. Exit 10 means status=halted, detail=skills-readiness:, preserve all state. Load resolved_path files and only declared fallback IDs from the report. Before activating any conditional helper, repeat with --require <exact-name>.
Resolved skill report: {json.dumps(skills)}
Config: {config_path}
Card: {json.dumps(card)}
Read .claude/skills/{skill}/SKILL.md and .claude/skills/super-board/references/run.md → {section} lifecycle; follow all its board, branch, worktree, comments, test and merge requirements.
Source .claude/bin/super-board-gh-guard.sh and use its quota checks. Required GitHub reads go through .claude/bin/super-board-github-read.py; a read that misses its --kind shape exits 64 for that call only and prints the valid form, so fix the read. Check --check before new writes, migrations and merges; exit 79 means status=halted, no more GitHub calls, preserve claims/worktree/card/approval. Never retry a mutation.
Use .claude/bin/super-board-card.sh for board reads/moves and .claude/bin/super-board-pr-body.sh for owned PR blocks; follow writing-standard.md and pr-author-notes.md.
Use your own worktree under .claude/worktrees/, created from the repository root with a path relative to it; never edit the main checkout. Clean up on ordinary exit, preserve work on halt/interruption.
Antigravity adaptation: do not call invoke_subagent or define_subagent. Perform preflight, classification, independent review and truth-check duties inline. Run shell commands with run_command; the shell is {"PowerShell 5.1 (no && chains: separate commands or use ;) and the Python launcher is `python`" if os.name == 'nt' else "sh and the Python launcher is python3"}; where a brief or script shows `python3`, run `{py}`. Keep scratch files under .claude/super-board/inflight/. A tool call denied by permissions means the allowlist is incomplete: report status=failed naming the command in detail, never work around it. This changes the execution host, never the evidence requirements, confidence threshold or merge policy.
Return JSON: status=advanced|bounced|blocked|human-gate|failed|halted; column=current board column; detail=one line; prUrl/branch when known, otherwise null; priorFindings=review counts or null. A non-advanced exit ends this card's lane chain. On merge-gate exit 9, return status=halted with detail starting exactly "verification-readiness:"; preserve work and never bounce/retry.
'''
if args.lane == 'build':
    prompt += '''Before creating any worktree or changing code, perform run.md's Builder pre-flight inline: call super-board-preflight.sh, judge its candidates semantically, and act on proceed/hold/sequence/skipped. Blind preflight leaves Ready and returns failed. Your own issue branch PR is not a duplicate. Read the issue and all comments; preserve qa/bug/feature labels. Existing docs/ux/tests/refactor/tech-debt rows keep their label chain: classify complexity without adding feature/bug. If truly untyped, classify feature or bug, re-run skills-ready on the proposed labelled card before adding that label, never qa. Then follow the Builder lifecycle.
'''
elif args.lane == 'qa' and card['status'] == 'Ready':
    prompt += 'This qa-labelled Ready card skips Building: move Ready → QA and create the issue branch from the base; test the existing product per run.md qa cards.\n'
elif args.lane == 'review':
    prompt += '''The owner explicitly chose run --agy: you may review and own the merge. First load the latest <!-- super-review:report -->; grade prior R-ids fixed/not fixed/no longer applies, bounce any not fixed and edit the same report in place. Form hypotheses from the issue AC and diff before reading the Builder narrative.
Rerun the Tester's tests. When truth_gate triggers, apply super-review's fixed Adversarial mode brief inline in two distinct passes (code-grounder and historian); collect evidence and aggregate confidence against truth_threshold. Over-engineering is Should fix, never Blocker alone and never lowers confidence. Missing evidence fails closed.
Merge ONLY through the unchanged .claude/bin/super-board-merge-gate.sh, pinning the exact head you reviewed at review pass using --expect-head "$HEAD" --config <config> --pr <N> --subject <title> --body-file <msg.md>. Never run bare gh pr merge or bypass the gate. Follow run.md Merge protocol and route every gate exit exactly: 2/5 rebase pass, 3 Blocked, 4 stay Review, 6 fresh review, 7/8 human gate with pinned approval-request; 9 verification-readiness means halt and preserve card/worktree/approval/claims until config repair and explicit restart, never a Build bounce or rebase retry. Respect human_approves_merge and merge_policy. Confirm MERGED <sha>, fetch base and prove merge-base --is-ancestor <sha> origin/<base> before closing issue or moving Done.
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
JSON_TYPES = {'object': dict, 'array': list, 'string': str, 'null': type(None)}
def conforms(value, rule):
    # The subset of JSON Schema the lane schema uses: type, enum, anyOf, properties/required/additionalProperties.
    if 'anyOf' in rule:
        return any(conforms(value, option) for option in rule['anyOf'])
    kinds = rule['type'] if isinstance(rule['type'], list) else [rule['type']]
    if not any(type(value) is int if kind == 'integer' else isinstance(value, JSON_TYPES[kind]) for kind in kinds):
        return False
    if 'enum' in rule and value not in rule['enum']:
        return False
    if isinstance(value, dict):
        if set(value) - set(rule['properties']) or not set(rule['required']) <= set(value):
            return False
        return all(conforms(value[key], rule['properties'][key]) for key in value)
    return True

# The Antigravity CLI. SB_AGY_BIN overrides it with a full command line (tests: an
# interpreter plus a stub); shutil.which resolves agy.exe / agy.cmd on Windows.
AGY = shlex.split(os.environ.get('SB_AGY_BIN', '')) or [shutil.which('agy') or 'agy']
inflight = root / '.claude/super-board/inflight'
inflight.mkdir(parents=True, exist_ok=True)
brief = inflight / f"agy-{card['number']}-{args.lane}.prompt.md"
last = inflight / f"agy-{card['number']}-{args.lane}.last.json"
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

def keep_raw(returncode, stdout, stderr):
    try:
        last.write_text(json.dumps({'exit': returncode, 'stdout': stdout, 'stderr': stderr}, indent=1))
    except OSError:
        pass

with tempfile.TemporaryDirectory(prefix='super-board-agy-') as temporary:
    schema_path = Path(temporary) / 'schema.json'
    schema_path.write_text(json.dumps(schema))
    brief.write_text(prompt, encoding='utf-8')
    pointer = (f"Read {brief.relative_to(root).as_posix()} and follow it exactly; it is your whole task. "
               "Return only the JSON the brief asks for, matching the schema.")
    command = AGY + ['-p', pointer, '--output-format', 'json', '--json-schema', str(schema_path), '--print-timeout', timeout]
    if model and model.strip():
        command += ['--model', model]
    if effort:
        command += ['--effort', effort]
    try:
        child = subprocess.Popen(command, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True, encoding='utf-8', errors='replace')
        stdout, stderr = child.communicate()
        sys.stderr.write(stderr)
        require_verification_ready()
        lines = [line for line in stdout.splitlines() if line.strip()]
        try:
            run = json.loads(lines[-1]) if lines else None
        except ValueError:
            run = None
        error = (run or {}).get('error') if isinstance(run, dict) else None
        if child.returncode or not isinstance(run, dict) or run.get('status') != 'SUCCESS':
            keep_raw(child.returncode, stdout, stderr)
            text = f"{error or ''} {stderr}"
            if 'RESOURCE_EXHAUSTED' in text or 'quota' in text.lower():
                result('halted', f"agy quota exhausted: {(error or 'RESOURCE_EXHAUSTED').strip()[:160]}; resume when it resets (raw run: {last.relative_to(root).as_posix()})")
                sys.exit(79)
            status = (run or {}).get('status') if isinstance(run, dict) else None
            raise ValueError(f"agy exited {child.returncode}, run status {status or '?'}{': ' + error[:160] if error else ''}")
        parsed = run.get('structured_output')
        if not conforms(parsed, schema):
            keep_raw(child.returncode, stdout, stderr)
            raise ValueError('lane result does not match the lane schema')
        denied = run.get('denied_actions') or []
        if denied:
            names = ', '.join(sorted({str(d.get('display_name') or d.get('action') or '?') for d in denied if isinstance(d, dict)}))
            parsed['detail'] += (f' · ⚠️ {len(denied)} tool call(s) auto-denied by agy permissions ({names}): '
                                 'run .claude/bin/super-board-agy-permissions.py --apply')
        print(json.dumps(parsed))
        sys.exit(10 if parsed['status'] == 'halted' and parsed['detail'].startswith('skills-readiness:')
                 else 9 if parsed['status'] == 'halted' and parsed['detail'].startswith('verification-readiness:')
                 else 79 if parsed['status'] == 'halted' else 0)
    except (OSError, ValueError) as error:
        result('failed', f'Antigravity returned no valid lane result: {error} (raw run: {last.relative_to(root).as_posix()})')
        sys.exit(1)
    finally:
        try:
            brief.unlink()
        except OSError:
            pass
PY
