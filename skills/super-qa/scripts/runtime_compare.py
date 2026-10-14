#!/usr/bin/env python3
"""Optional project-owned runtime scenarios: alternating baseline/changed evidence.

The scenario command prints one JSON object: correct (boolean), duration_ms
(nonnegative finite), environment (stable browser/scenario identity), and optional
memory_bytes. Commands are argv arrays, never shell snippets. See runtime-verification.md.
"""
import argparse
import hashlib
import json
import math
import os
from pathlib import Path
import signal
import statistics
import subprocess
import sys
import time
from urllib.error import HTTPError
from urllib.parse import urlsplit
from urllib.request import HTTPRedirectHandler, ProxyHandler, build_opener


def summary(values):
    return {'median': statistics.median(values), 'min': min(values), 'max': max(values), 'n': len(values)}


def compare(before, after, relative_tolerance=0.10, absolute_tolerance=5.0):
    if len(before) < 5 or len(after) < 5:
        return {'outcome': 'inconclusive', 'reason': 'at least five valid samples per side required'}
    b, a = summary(before), summary(after)
    delta = a['median'] - b['median']
    threshold = max(absolute_tolerance, abs(b['median']) * relative_tolerance)
    noisy = any(s['max'] - s['min'] > max(absolute_tolerance, s['median'] * .20) for s in (b, a))
    if noisy:
        outcome = 'inconclusive'
    elif abs(delta) <= threshold:
        outcome = 'unchanged'
    elif a['max'] < b['min']:
        outcome = 'faster'
    elif a['min'] > b['max']:
        outcome = 'slower'
    else:
        outcome = 'inconclusive'
    return {'outcome': outcome, 'baseline': b, 'changed': a, 'delta_ms': delta,
            'threshold_ms': threshold, 'reason': 'descriptive samples; overlapping ranges or high noise cannot establish a win'}


def command(value, name):
    if not isinstance(value, list) or not value or not all(isinstance(v, str) and v for v in value):
        raise ValueError(name + ' must be a nonempty argv array')
    return value


def finite(value):
    return isinstance(value, (int, float)) and not isinstance(value, bool) and math.isfinite(value) and value >= 0


def validate(config, root):
    if type(config.get('repetitions', 5)) is not int or not 5 <= config.get('repetitions', 5) <= 50:
        raise ValueError('repetitions must be an integer from 5 to 50')
    if type(config.get('warmups', 1)) is not int or not 1 <= config.get('warmups', 1) <= 10:
        raise ValueError('warmups must be an integer from 1 to 10')
    for key in ('scenario_id', 'data_id', 'environment_id'):
        if not isinstance(config.get(key), str) or not config[key]:
            raise ValueError(key + ' is required to identify the matching scenario/data/environment')
    command(config.get('scenario_command'), 'scenario_command')
    paths = config.get('scenario_files')
    if not isinstance(paths, list) or not paths:
        raise ValueError('scenario_files must list the scenario/data inputs to fingerprint')
    for p in paths:
        if not (root / p).is_file():
            raise ValueError('scenario input is missing: ' + str(p))
    for name in ('baseline', 'changed'):
        side = config.get(name, {})
        command(side.get('start_command'), name + '.start_command')
        if not (root / side.get('cwd', '.')).is_dir():
            raise ValueError(name + '.cwd does not exist')
        source_files = side.get('source_files', [])
        if not isinstance(source_files, list) or not all(isinstance(p, str) and (root / side.get('cwd', '.') / p).is_file() for p in source_files):
            raise ValueError(name + '.source_files must name existing source files')
        if not side.get('revision'):
            raise ValueError(name + ' needs a revision')
        require_local_url(side.get('url'))
    if config['baseline']['url'] == config['changed']['url']:
        raise ValueError('baseline and changed need separate local URLs')
    for key in ('timeout_seconds', 'ready_timeout_seconds'):
        if not finite(config.get(key, 30)) or config.get(key, 30) == 0:
            raise ValueError(key + ' must be positive and finite')
    for key in ('relative_tolerance', 'absolute_tolerance_ms'):
        if not finite(config.get(key, .10 if key == 'relative_tolerance' else 5)):
            raise ValueError(key + ' must be nonnegative and finite')
    env = config.get('environment', {})
    if not isinstance(env, dict) or not all(isinstance(k, str) and isinstance(v, str) for k, v in env.items()):
        raise ValueError('environment must be a string-to-string object')


def require_local_url(url):
    message = 'a loopback HTTP URL with an explicit port and no credentials is required'
    try:
        parsed = urlsplit(url) if isinstance(url, str) else None
        valid = (parsed is not None and parsed.scheme == 'http' and
                 parsed.hostname in ('127.0.0.1', 'localhost') and
                 parsed.username is None and parsed.password is None and
                 parsed.port is not None and 1 <= parsed.port <= 65535)
    except ValueError:
        valid = False
    if not valid:
        raise ValueError(message)


class LocalRedirectHandler(HTTPRedirectHandler):
    def redirect_request(self, req, fp, code, msg, headers, newurl):
        require_local_url(newurl)
        return super().redirect_request(req, fp, code, msg, headers, newurl)


def local_http(url, timeout):
    # Validated app URLs are loopback-only. Host/system proxies must not intercept them.
    # Keep this opener local so adapters and unrelated network traffic retain their policy.
    require_local_url(url)
    return build_opener(ProxyHandler({}), LocalRedirectHandler()).open(url, timeout=timeout)


def ready(url, process, timeout):
    last_probe = 'no response'
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        if process.poll() is not None:
            raise RuntimeError('app exited before becoming ready')
        try:
            with local_http(url, timeout=min(1, timeout)) as response:
                if response.status == 200:
                    return
                last_probe = 'HTTP ' + str(response.status)
        except OSError as exc:
            last_probe = type(exc).__name__ + ': ' + str(exc)
        time.sleep(.05)
    raise RuntimeError('app readiness timed out; last probe: ' + last_probe)


def group_members(group):
    """Read actual live members: killpg(..., 0) is unreliable for residual groups."""
    result = subprocess.run(['ps', '-axo', 'pid=,pgid=,stat=,uid='],
                            capture_output=True, text=True, timeout=.5)
    if result.returncode:
        raise RuntimeError('could not inspect owned process group during cleanup')
    members = {}
    for line in result.stdout.splitlines():
        fields = line.split()
        if len(fields) == 4 and int(fields[1]) == group and not fields[2].startswith('Z'):
            members[int(fields[0])] = int(fields[3])
    return members


def stop(process, grace=.5):
    """Terminate live owned group members, including children of an exited wrapper."""
    try:
        parent_exited = process.poll() is not None
        original = group_members(process.pid)
        if not original:
            return  # Empty/zombie-only groups need reaping, not more signals.
        if parent_exited and process.pid in original:
            raise RuntimeError('process group id was reused; refusing unrelated group')
        if any(uid != os.getuid() for uid in original.values()):
            raise RuntimeError('cannot safely signal foreign process group members')
        try:
            os.killpg(process.pid, signal.SIGTERM)
        except ProcessLookupError:
            pass
        except PermissionError:
            if group_members(process.pid):
                raise RuntimeError('permission denied cleaning live process group')
            return
        deadline = time.monotonic() + grace
        remaining = original
        while time.monotonic() < deadline:
            process.poll()
            remaining = group_members(process.pid)
            if not remaining:
                return
            if not set(remaining).intersection(original):
                raise RuntimeError('owned group identity changed; refusing unrelated processes')
            time.sleep(.02)
        try:
            os.killpg(process.pid, signal.SIGKILL)
        except ProcessLookupError:
            pass
        except PermissionError:
            if group_members(process.pid):
                raise RuntimeError('permission denied killing live process group')
            return
        deadline = time.monotonic() + grace
        while time.monotonic() < deadline:
            process.poll()
            if not group_members(process.pid):
                return
            time.sleep(.02)
        raise RuntimeError('live descendants remain after bounded cleanup')
    finally:
        try:
            process.wait(timeout=grace)
        except subprocess.TimeoutExpired:
            pass


def run_adapter(argv, cwd, env, timeout):
    process = subprocess.Popen(argv, cwd=cwd, env=env, stdout=subprocess.PIPE,
                               stderr=subprocess.PIPE, text=True, start_new_session=True)
    try:
        stdout, stderr = process.communicate(timeout=timeout)
        return subprocess.CompletedProcess(argv, process.returncode, stdout, stderr)
    except subprocess.TimeoutExpired as timeout_error:
        stop(process)
        try:
            process.communicate(timeout=.5)
        except subprocess.TimeoutExpired:
            # A detached descendant might retain pipes outside the owned group.
            # Close our ends rather than let it defeat the configured timeout.
            process.stdout.close()
            process.stderr.close()
        raise timeout_error
    finally:
        # Custom adapters may spawn children; do not leave them running.
        try:
            stop(process)
        finally:
            process.stdout.close()
            process.stderr.close()


def measure(config_path, output):
    config_path, output = Path(config_path).resolve(), Path(output).resolve()
    config, root = json.loads(config_path.read_text()), config_path.parent
    if not isinstance(config, dict):
        raise ValueError('config must be a JSON object')
    validate(config, root)
    output.mkdir(parents=True, exist_ok=False)
    report = {'schema_version': 1, 'scenario_id': config['scenario_id'], 'data_id': config['data_id'],
              'environment_id': config['environment_id'], 'config_sha256': hashlib.sha256(config_path.read_bytes()).hexdigest(),
              'input_sha256': {p: hashlib.sha256((root / p).read_bytes()).hexdigest() for p in config['scenario_files']},
              'revisions': {n: config[n]['revision'] for n in ('baseline', 'changed')},
              'sources': {},
              'order': [], 'samples': {'baseline': [], 'changed': []}, 'warmups': [],
              'correctness_failures': {'baseline': 0, 'changed': 0}, 'outcome': 'inconclusive'}
    processes, logs = {}, []
    common_env = dict(os.environ, **config.get('environment', {}))
    failure = None
    try:
        for name in ('baseline', 'changed'):
            side = config[name]
            source_dir = (root / side.get('cwd', '.')).resolve()
            source = {'cwd': str(source_dir), 'sha256': {}}
            for p in side.get('source_files', []):
                source['sha256'][p] = hashlib.sha256((source_dir / p).read_bytes()).hexdigest()
            try:
                head = subprocess.run(['git', '-C', str(source_dir), 'rev-parse', 'HEAD'], capture_output=True, text=True)
                if head.returncode == 0:
                    source['git_head'] = head.stdout.strip()
                    dirty = subprocess.run(['git', '-C', str(source_dir), 'status', '--porcelain'], capture_output=True, text=True)
                    source['git_dirty'] = bool(dirty.stdout.strip()) if dirty.returncode == 0 else None
            except OSError:
                pass
            report['sources'][name] = source
            # Refuse to measure an unrelated process already occupying the target.
            try:
                with local_http(side['url'], timeout=.3):
                    raise RuntimeError('app URL is already occupied: ' + name)
            except HTTPError:
                # An HTTP error still proves another server owns this URL.
                raise RuntimeError('app URL is already occupied: ' + name)
            except OSError:
                pass
            log = (output / (name + '-server.log')).open('w')
            logs.append(log)
            process = subprocess.Popen(side['start_command'], cwd=root / side.get('cwd', '.'),
                                       env=common_env, stdout=log, stderr=log, start_new_session=True)
            processes[name] = process
            ready(side['url'], process, config.get('ready_timeout_seconds', 30))
        identity = None
        total = config.get('warmups', 1) + config.get('repetitions', 5)
        for cycle in range(total):
            for name in (('baseline', 'changed') if cycle % 2 == 0 else ('changed', 'baseline')):
                phase = 'warmup' if cycle < config.get('warmups', 1) else 'sample'
                sample_dir = output / (f'{phase}-{cycle}-{name}')
                sample_dir.mkdir()
                env = dict(common_env, SB_RUNTIME_URL=config[name]['url'],
                           SB_RUNTIME_ARTIFACT_DIR=str(sample_dir))
                row = {'side': name, 'cycle': cycle, 'phase': phase}
                try:
                    result = run_adapter(config['scenario_command'], root, env, config.get('timeout_seconds', 30))
                    row['exit_code'] = result.returncode
                    (sample_dir / 'adapter.stderr.log').write_text(result.stderr)
                    payload = json.loads(result.stdout)
                    if not isinstance(payload, dict):
                        raise ValueError('adapter output must be a JSON object')
                    row.update(payload)
                    if result.returncode or row.get('correct') is not True or not finite(row.get('duration_ms')):
                        raise ValueError('scenario failed, correctness failed, or duration missing/invalid')
                    if not isinstance(row.get('environment'), dict) or not row['environment']:
                        raise ValueError('adapter must identify actual browser/environment')
                    if identity is None:
                        identity = row['environment']
                    if row['environment'] != identity:
                        raise ValueError('adapter environments do not match')
                    if 'memory_bytes' in row and not finite(row['memory_bytes']):
                        raise ValueError('memory measurement invalid')
                except (ValueError, subprocess.TimeoutExpired, OSError, RuntimeError) as exc:
                    row['correct'] = False
                    row['error'] = str(exc)
                    report['correctness_failures'][name] += 1
                row['artifacts'] = str(sample_dir.relative_to(output))
                if phase == 'warmup':
                    report['warmups'].append(row)
                else:
                    report['samples'][name].append(row)
                    report['order'].append(name)
        values = {n: [r['duration_ms'] for r in rows if r.get('correct') is True]
                  for n, rows in report['samples'].items()}
        verdict = compare(values['baseline'], values['changed'], config.get('relative_tolerance', .10),
                          config.get('absolute_tolerance_ms', 5))
        report['timing'] = verdict
        memory = {n: [r['memory_bytes'] for r in rows if r.get('correct') is True and 'memory_bytes' in r]
                  for n, rows in report['samples'].items()}
        report['memory'] = {n: summary(v) if v else None for n, v in memory.items()}
        if any(report['correctness_failures'].values()):
            report['timing']['outcome'] = 'inconclusive'
            report['reason'] = 'correctness or measurement failures invalidate performance claims'
        else:
            report['outcome'] = verdict['outcome']
            report['reason'] = verdict['reason']
    except (OSError, RuntimeError, ValueError) as exc:
        failure = str(exc)
        report['reason'] = failure
    finally:
        cleanup_errors = []
        for process in processes.values():
            try:
                stop(process)
            except (OSError, RuntimeError, subprocess.TimeoutExpired) as exc:
                cleanup_errors.append(str(exc))
        if cleanup_errors:
            failure = 'app cleanup failed'
            report['cleanup_errors'] = cleanup_errors
            report['outcome'] = 'inconclusive'
            report['reason'] = failure
            if 'timing' in report:
                report['timing']['outcome'] = 'inconclusive'
        for log in logs:
            log.close()
        (output / 'report.json').write_text(json.dumps(report, indent=2) + '\n')
    return report, 2 if failure or any(report['correctness_failures'].values()) else 0


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--config', required=True)
    parser.add_argument('--output', required=True, help='new evidence directory (never overwrite)')
    args = parser.parse_args()
    try:
        report, status = measure(args.config, args.output)
        print(json.dumps({'outcome': report['outcome'], 'report': str(Path(args.output).resolve() / 'report.json'),
                          'correctness_failures': report['correctness_failures']}))
        return status
    except (ValueError, OSError) as exc:
        print(json.dumps({'outcome': 'inconclusive', 'error': str(exc)}))
        return 2

if __name__ == '__main__':
    sys.exit(main())
