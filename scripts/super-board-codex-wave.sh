#!/usr/bin/env bash
# Dispatch an explicitly selected Codex wave; stdout/--output matches the
# Claude workflow's {cards:[summary...], halted} reconciliation contract.
# Usage: --config f --cards '<JSON array>' --codex[=model] [--tier low|medium|high] [--output f]
# Unless one model is pinned (--codex=<model> or codex.model), a cheap router
# (ROUTER_MODEL) grades each Ready card low/medium/high; the lane launcher maps
# tier x grade to a model through its CODEX_LADDERS table.
set -euo pipefail
exec python3 - "${BASH_SOURCE[0]}" "$@" <<'PY'
import argparse
from concurrent.futures import ThreadPoolExecutor
import json
import os
from pathlib import Path
import signal
import subprocess
import sys
import tempfile
import threading
import time

parser = argparse.ArgumentParser(description='Dispatch one explicitly opted-in Codex wave.')
parser.add_argument('--config', required=True)
parser.add_argument('--cards', required=True, help='planner card array JSON or JSON file')
parser.add_argument('--output')
parser.add_argument('--tier', default='medium', choices=['low', 'medium', 'high'])
raw = sys.argv[2:]
codex = [arg for arg in raw if arg == '--codex' or arg.startswith('--codex=')]
if len(codex) != 1 or (codex[0].startswith('--codex=') and not codex[0].partition('=')[2].strip()):
    parser.error('exactly one explicit --codex[=<non-empty-model>] is required')
args = parser.parse_args([arg for arg in raw if arg not in codex])
output_path = Path(args.output).resolve() if args.output else None
launcher = Path(sys.argv[1]).resolve().with_name('super-board-codex-lane.sh')
try:
    config_path = Path(args.config).resolve()
    config = json.loads(config_path.read_text())
    cards = json.loads(args.cards if args.cards.lstrip().startswith('[') else Path(args.cards).read_text())
    if not isinstance(config, dict) or not isinstance(cards, list):
        raise ValueError('config must be an object; cards must be an array')
    numbers = set()
    for card in cards:
        if (not isinstance(card, dict) or type(card.get('number')) is not int or card['number'] < 1
                or card.get('status') not in ['Ready', 'QA', 'Review']):
            raise ValueError('each card needs a positive number and Ready/QA/Review status')
        if card['number'] in numbers:
            raise ValueError('duplicate card number')
        numbers.add(card['number'])
        if card.get('lane') not in [None, 'build', 'qa', 'review']:
            raise ValueError('invalid card lane')
        if card['status'] == 'Ready' and card.get('lane') == 'review':
            raise ValueError('a Ready card must enter build or qa')
    workers = config.get('max_workers', 0)
    if type(workers) is not int or workers < 0:
        raise ValueError('max_workers must be a non-negative integer')
    workers = workers or max(1, min(16, (os.cpu_count() or 2) - 2))
    root = Path(subprocess.check_output(['git', 'rev-parse', '--show-toplevel'], text=True).strip()).resolve()
    configured = (config.get('codex') or {}).get('model')
    pinned = codex[0].startswith('--codex=') or (isinstance(configured, str) and configured.strip())
except (OSError, ValueError, subprocess.CalledProcessError) as error:
    parser.error(str(error))
os.chdir(root)
halted = threading.Event()
mutex = threading.RLock()
active = set()
inflight = root / '.claude/super-board/inflight'
marker = root / '.claude/super-board/codex-wave.pid'
inflight.mkdir(parents=True, exist_ok=True)
owner = str(os.getpid())

def cancel(signum, frame):
    halted.set()
    with mutex:
        processes = list(active)
        for process in processes:
            try:
                os.killpg(process.pid, signal.SIGTERM)
            except ProcessLookupError:
                pass
    # Process groups include the launcher, Codex, and shell descendants. Kill
    # lingering descendants too, even when their launcher already exited.
    time.sleep(2)
    for process in processes:
        try:
            os.killpg(process.pid, signal.SIGKILL)
        except ProcessLookupError:
            pass

signal.signal(signal.SIGTERM, cancel)
signal.signal(signal.SIGINT, cancel)
try:
    with marker.open('x') as stream:
        stream.write(owner + '\n')
except FileExistsError:
    parser.error('Codex wave PID marker exists; reconcile the previous wave before starting another')

# The router only grades scope; it writes nothing. A Codex-only run grades with
# the cheapest Codex model rather than waking Claude.
ROUTER_MODEL = 'gpt-6-luna'
GRADE_SCHEMA = {'type': 'object', 'additionalProperties': False, 'required': ['complexity'],
                'properties': {'complexity': {'type': 'string', 'enum': ['low', 'medium', 'high']}}}

def grade(card):
    """Return (complexity or None, halted). A failed grade falls back to the medium cell."""
    if pinned or card['status'] != 'Ready':
        return card.get('complexity') if card.get('complexity') in ['low', 'medium', 'high'] else None, False
    if card.get('complexity') in ['low', 'medium', 'high']:
        return card['complexity'], False
    prompt = (f"Read GitHub issue #{card['number']} (\"{card.get('title', '')}\") - body and all comments - with "
              f".claude/bin/super-board-github-read.py --kind issue -- gh issue view {card['number']} --json title,body,comments. "
              'Grade complexity (low|medium|high) by the scope of change required. Read only: change no file, '
              'label, comment or board state. Exit 79 from the read helper means stop and return nothing.\n')
    with tempfile.TemporaryDirectory(prefix='super-board-codex-grade-') as temporary:
        schema_path, output = Path(temporary) / 'schema.json', Path(temporary) / 'grade.json'
        schema_path.write_text(json.dumps(GRADE_SCHEMA))
        command = ['codex', 'exec', '-m', ROUTER_MODEL, '-C', str(root), '-c', 'approval_policy="never"',
                   '-c', 'default_permissions="super-board-grade"',
                   '-c', 'permissions.super-board-grade.filesystem={":root"="read", ":slash_tmp"="write", ":tmpdir"="write"}',
                   '-c', 'permissions.super-board-grade.network.enabled=true',
                   '--output-schema', str(schema_path), '--output-last-message', str(output), '-']
        with mutex:
            if halted.is_set():
                return None, True
            try:
                process = subprocess.Popen(command, stdin=subprocess.PIPE, stdout=subprocess.DEVNULL,
                                           text=True, start_new_session=True)
            except OSError:
                return None, False
            active.add(process)
        try:
            process.communicate(prompt)
        finally:
            with mutex:
                active.discard(process)
        if process.returncode == 79:
            return None, True
        try:
            value = json.loads(output.read_text()).get('complexity')
        except (OSError, ValueError, AttributeError):
            return None, False
        return (value if value in ['low', 'medium', 'high'] else None), False

def run_card(card):
    complexity, stop = grade(card)
    if stop:
        halted.set()
        return dict(number=card['number'], finalStatus='halted', lastLane='none', column=card['status'],
                    detail='run halted while grading; preserve claims and worktrees', prUrl=None,
                    priorFindings=None, lanesRun='none:halted')
    labels = [str(label).lower() for label in card.get('labels', [])]
    first = card.get('lane') or ('qa' if 'qa' in labels else 'build')
    entry = 'review' if card['status'] == 'Review' else 'qa' if card['status'] == 'QA' else first
    lanes = ['build', 'qa', 'review'][['build', 'qa', 'review'].index(entry):]
    history = []
    current = dict(card)
    for lane in lanes:
        with mutex:
            if halted.is_set():
                history.append(dict(lane='none', status='halted', column=current['status'], detail='run halted; preserve claims and worktrees'))
                break
            process = None
            lock = inflight / str(card['number'])
            try:
                process = subprocess.Popen(['bash', str(launcher), '--config', str(config_path),
                                            '--card', json.dumps(current), '--lane', lane, codex[0],
                                            '--tier', args.tier] + (['--complexity', complexity] if complexity else []),
                                           stdout=subprocess.PIPE, text=True, start_new_session=True)
                active.add(process)
                lock.write_text(f'PID={process.pid}\nLANE={lane}\nSTARTED={time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime())}\n')
            except OSError as error:
                if process is not None:
                    try:
                        os.killpg(process.pid, signal.SIGKILL)
                    except ProcessLookupError:
                        pass
                    process.wait()
                    active.discard(process)
                history.append(dict(lane=lane, status='failed', column=current['status'],
                                    detail=f'could not start {lane} lane: {error}'))
                break
        try:
            stdout, _ = process.communicate()
            try:
                result = json.loads(stdout)
                if (not isinstance(result, dict) or result.get('status') not in
                    ['advanced', 'bounced', 'blocked', 'human-gate', 'failed', 'halted']
                    or not all(isinstance(result.get(key), str) for key in ['column', 'detail'])):
                    raise ValueError('invalid lane result')
                if process.returncode and result['status'] != 'halted':
                    raise ValueError(f'lane exited {process.returncode}')
            except (ValueError, TypeError):
                result = dict(status='halted' if process.returncode == 79 or halted.is_set() else 'failed',
                              column=current['status'], detail=f'{lane} lane returned no valid result (exit {process.returncode})')
            with mutex:
                if result['status'] == 'halted':
                    halted.set()
                active.discard(process)
            history.append(dict(lane=lane, **result))
            if result['status'] != 'advanced':
                break
            expected = {'build': 'QA', 'qa': 'Review', 'review': 'Done'}[lane]
            if result['column'] != expected:
                history[-1].update(status='failed', detail=f'{lane} claimed advanced without reaching {expected}')
                break
            current['status'] = result['column']
        finally:
            try:
                if lock.read_text().startswith(f'PID={process.pid}\n'):
                    lock.unlink()
            except FileNotFoundError:
                pass
    last = history[-1]
    return dict(number=card['number'], finalStatus=last['status'], lastLane=last['lane'],
                column=last['column'], detail=last['detail'], prUrl=last.get('prUrl'),
                priorFindings=last.get('priorFindings'),
                lanesRun=' → '.join(f"{item['lane']}:{item['status']}" for item in history))

try:
    with ThreadPoolExecutor(max_workers=workers) as pool:
        summaries = list(pool.map(run_card, cards))
    result = json.dumps(dict(cards=summaries, halted=halted.is_set()))
    if output_path:
        output = output_path
        temporary = output.with_name(output.name + f'.{owner}.tmp')
        temporary.write_text(result + '\n')
        temporary.replace(output)
    print(result)
finally:
    if marker.exists() and marker.read_text().strip() == owner:
        marker.unlink()
sys.exit(79 if halted.is_set() else 0)
PY
