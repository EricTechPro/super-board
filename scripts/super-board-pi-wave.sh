#!/usr/bin/env bash
# Dispatch an explicitly selected Pi wave; stdout/--output matches the
# Claude workflow's {cards:[summary...], halted} reconciliation contract.
# Usage: --config f --cards '<JSON array>' --pi[=model] [--tier low|medium|high] [--output f]
# Unless one model is pinned (--pi=<model> or pi.model), a cheap router
# (pi.router_model, default claude-haiku-latest) grades each Ready card
# low/medium/high; the lane launcher maps tier x grade to a model through its
# PI_LADDERS table.
set -euo pipefail
exec python3 - "${BASH_SOURCE[0]}" "$@" <<'PY'
import argparse
import importlib.util
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

parser = argparse.ArgumentParser(description='Dispatch one explicitly opted-in Pi wave.')
parser.add_argument('--config', required=True)
parser.add_argument('--cards', required=True, help='planner card array JSON or JSON file')
parser.add_argument('--output')
parser.add_argument('--tier', default='medium', choices=['low', 'medium', 'high'])
raw = sys.argv[2:]
pi_flags = [arg for arg in raw if arg == '--pi' or arg.startswith('--pi=')]
if len(pi_flags) != 1 or (pi_flags[0].startswith('--pi=') and not pi_flags[0].partition('=')[2].strip()):
    parser.error('exactly one explicit --pi[=<non-empty-model>] is required')
args = parser.parse_args([arg for arg in raw if arg not in pi_flags])
output_path = Path(args.output).resolve() if args.output else None
launcher = Path(sys.argv[1]).resolve().with_name('super-board-pi-lane.sh')
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
    configured = (config.get('pi') or {}).get('model')
    pinned = pi_flags[0].startswith('--pi=') or (isinstance(configured, str) and configured.strip())
    router = (config.get('pi') or {}).get('router_model') or 'claude-haiku-latest'
    if not isinstance(router, str) or not router.strip():
        raise ValueError('pi.router_model must be a non-empty string')
    ROUTER_MODEL = router
except (OSError, ValueError, subprocess.CalledProcessError) as error:
    parser.error(str(error))
readiness = launcher.with_name('super-board-verification-ready.py')
if subprocess.run([sys.executable, str(readiness), '--config', str(config_path)]).returncode:
    result = json.dumps({'cards': [dict(number=c['number'], finalStatus='halted', lastLane='none',
                                       column=c['status'], detail='verification-readiness: repair verify_commands and restart explicitly',
                                       lanesRun='none:halted') for c in cards], 'halted': True})
    if output_path:
        output_path.write_text(result + '\n')
    print(result)
    sys.exit(9)
os.chdir(root)
resolver_path = launcher.with_name('super-board-skills-ready.py')
try:
    spec = importlib.util.spec_from_file_location('skills_ready', resolver_path)
    resolver = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(resolver)
    resolver.hydrate(cards, root)
    skills = resolver.report(root, 'pi', cards, home=os.environ.get('SUPER_BOARD_SKILLS_HOME'),
                             catalog=os.environ.get('SUPER_BOARD_SKILLS_CATALOG'))
except SystemExit as error:
    code, detail = error.code, 'required GitHub reads halted while hydrating skills; preserve claims and worktrees'
except (OSError, ValueError, TypeError, KeyError) as error:
    code, detail = 64, 'skills-readiness: ' + str(error)
else:
    code = 0 if skills['ready'] else 10
    detail = 'skills-readiness: missing ' + ', '.join(dict.fromkeys(e['name'] for e in skills['entries'] if e['status'] == 'missing'))
if code:
    result = json.dumps(dict(cards=[dict(number=c['number'], finalStatus='halted', lastLane='none', column=c['status'],
                                       detail=detail, lanesRun='none:halted') for c in cards], halted=True))
    if output_path:
        output_path.write_text(result + '\n')
    print(result)
    sys.exit(code)
readiness_halted = threading.Event()
skills_halted = threading.Event()
halted = threading.Event()
mutex = threading.RLock()
active = set()
inflight = root / '.claude/super-board/inflight'
marker = root / '.claude/super-board/pi-wave.pid'
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
    # Process groups include the launcher, Pi, and shell descendants. Kill
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
    parser.error('Pi wave PID marker exists; reconcile the previous wave before starting another')

# The router only grades scope; it writes nothing. A Pi run grades with the
# configured cheap model (pi.router_model, default claude-haiku-latest) rather
# than waking Claude; a failed grade falls back to the medium ladder cell.
def grade(card):
    """Return (complexity or None, halted). A failed grade falls back to the medium cell."""
    if pinned or card['status'] != 'Ready':
        return card.get('complexity') if card.get('complexity') in ['low', 'medium', 'high'] else None, False
    if card.get('complexity') in ['low', 'medium', 'high']:
        return card['complexity'], False
    prompt = (f"Read GitHub issue #{card['number']} (\"{card.get('title', '')}\") - body and all comments - with "
              f".claude/bin/super-board-github-read.py --kind issue -- issue view {card['number']} --json number,title,body and "
              f"--kind comments -- api repos/{{owner}}/{{repo}}/issues/{card['number']}/comments --paginate --slurp. "
              'Grade complexity (low|medium|high) by the scope of change required. Read only: change no file, '
              'label, comment or board state. Exit 79 from the read helper means stop and return nothing.\n')
    with tempfile.TemporaryDirectory(prefix='super-board-pi-grade-') as temporary:
        output = Path(temporary) / 'grade.json'
        prompt += (f'Result file: {output}\n'
                   'Write your final JSON object {"complexity": "low"|"medium"|"high"} (no other content) to the '
                   'Result file above with the write tool.\n')
        command = ['pi', '-p', '-a', '--tools', 'read,bash,write', '--model', ROUTER_MODEL, prompt]
        with mutex:
            if halted.is_set():
                return None, True
            try:
                process = subprocess.Popen(command, stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL,
                                           text=True, start_new_session=True)
            except OSError:
                return None, False
            active.add(process)
        try:
            process.wait()
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
            boundary = resolver.report(root, 'pi', [current], lane=lane,
                                       home=os.environ.get('SUPER_BOARD_SKILLS_HOME'), catalog=os.environ.get('SUPER_BOARD_SKILLS_CATALOG'))
            if not boundary['ready']:
                skills_halted.set()
                halted.set()
                history.append(dict(lane=lane, status='halted', column=current['status'],
                                    detail='skills-readiness: missing ' + ', '.join(e['name'] for e in boundary['entries'] if e['status'] == 'missing')))
                break
            process = None
            lock = inflight / str(card['number'])
            try:
                process = subprocess.Popen(['bash', str(launcher), '--config', str(config_path),
                                            '--card', json.dumps(current), '--lane', lane, pi_flags[0],
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
        preserve_lock = False
        try:
            stdout, _ = process.communicate()
            if process.returncode in (9, 10):
                preserve_lock = True
                (readiness_halted if process.returncode == 9 else skills_halted).set()
            try:
                result = json.loads(stdout)
                if (not isinstance(result, dict) or result.get('status') not in
                    ['advanced', 'bounced', 'blocked', 'human-gate', 'failed', 'halted']
                    or not all(isinstance(result.get(key), str) for key in ['column', 'detail'])):
                    raise ValueError('invalid lane result')
                if process.returncode and result['status'] != 'halted':
                    raise ValueError(f'lane exited {process.returncode}')
            except (ValueError, TypeError):
                result = dict(status='halted' if process.returncode in (9, 10, 79) or halted.is_set() else 'failed',
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
            current.pop('lane', None)
        finally:
            try:
                if not preserve_lock and lock.read_text().startswith(f'PID={process.pid}\n'):
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
sys.exit(10 if skills_halted.is_set() else 9 if readiness_halted.is_set() else 79 if halted.is_set() else 0)
PY
