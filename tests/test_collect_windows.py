"""Collector lock on a host without fcntl, fd inheritance or shebang exec (Windows, #64).

The real scripts run under a shim that hides fcntl and supplies an msvcrt stand-in, so the
whole intake suite and the lock-token guards are exercised through the non-POSIX path.
"""
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest

sys.path.insert(0, str(Path(__file__).resolve().parent))
import test_collect_intake_safety as intake  # noqa: E402

ROOT = intake.ROOT
STATE = ROOT/'scripts/super-board-collect-state.py'
SHIM = r'''#!/usr/bin/env python3
import fcntl as _real, os, runpy, sys, types
# Python 3.12+ stdlib (subprocess) probes `import msvcrt` to decide it is on Windows; load it
# before the stand-in exists so only the script under test sees msvcrt.
import subprocess  # noqa: F401
sys.modules['fcntl'] = None  # import fcntl -> ImportError, as on Windows
m = types.ModuleType('msvcrt'); m.LK_NBLCK, m.LK_UNLCK = 2, 0
def locking(fd, mode, nbytes):
    if mode == m.LK_UNLCK: return _real.flock(fd, _real.LOCK_UN)
    try: _real.flock(fd, _real.LOCK_EX | _real.LOCK_NB)
    except BlockingIOError: raise PermissionError(13, 'Permission denied')  # msvcrt's contention error
m.locking = locking; sys.modules['msvcrt'] = m
real = os.environ['SB_TEST_REAL_STATE']
if os.environ.get('SB_TEST_LOG_FDS'):
    with open(os.environ['SB_TEST_LOG_FDS'], 'a') as f: f.write(os.environ.get('SB_COLLECT_LOCK_FD', '') + '\n')
sys.argv[0] = real; runpy.run_path(real, run_name='__main__')
'''


def shim_bin(root):
    bin_dir = root/'bin'; bin_dir.mkdir()
    for f in (ROOT/'scripts').iterdir():
        if f.name != STATE.name:
            (bin_dir/f.name).symlink_to(f)
    (bin_dir/STATE.name).write_text(SHIM); (bin_dir/STATE.name).chmod(0o755)
    return bin_dir


class WindowsIntakeTests(intake.IntakeTests):
    """Every intake regression again, through the portable lock path."""
    def setUp(self):
        super().setUp()
        self.env.update(SUPER_BOARD_BIN=str(shim_bin(self.root)), SB_TEST_REAL_STATE=str(STATE))

    def test_portable_path_never_passes_an_fd_token(self):
        log = self.root/'fds.log'
        result = self.run_filer(SB_TEST_LOG_FDS=str(log))
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertNotIn('Errno 8', result.stderr)
        self.assertEqual(set(log.read_text().splitlines()), {''})

    def test_receipt_action_refuses_forged_or_stale_token(self):
        self.assertEqual(self.run_filer().returncode, 0)
        key = __import__('hashlib').sha256(b'acme/app').hexdigest()
        cmd = [sys.executable, str(self.root/'bin'/STATE.name), '--repo', 'acme/app', '--action', 'begin',
               '--fingerprint', 'custom|demo|one']
        for token in ['', 'forged']:
            with self.subTest(token=token):
                env = dict(self.env, SB_COLLECT_LOCK_HELD=key, SB_COLLECT_LOCK_TOKEN=token)
                result = subprocess.run(cmd, env=env, capture_output=True, text=True, timeout=15)
                self.assertEqual(result.returncode, 70, result.stderr)
                self.assertIn('require the held repository lock', result.stderr)
        state = json.loads(next((self.root/'collector-state').glob('*.json')).read_text())
        self.assertNotIn('pending', state)

    def test_interrupted_write_still_blocks_retry(self):
        first = self.run_filer(FAIL_CREATE_AFTER_STORE='1')
        self.assertEqual(first.returncode, 79, first.stderr)
        (self.root/'halt.json').unlink(missing_ok=True)
        second = self.run_filer()
        self.assertEqual(second.returncode, 79)
        self.assertIn('Collector write outcome unresolved', second.stderr)


class ImportTests(unittest.TestCase):
    def test_shim_loads_stdlib_before_the_msvcrt_stand_in(self):
        # Regression guard (PR #68 CI): on 3.12 a stand-in msvcrt visible to subprocess's
        # import flips it to its Windows branch (_winapi). Holds on every interpreter.
        self.assertLess(SHIM.index('import subprocess'), SHIM.index("sys.modules['msvcrt']"))

    def test_module_imports_without_fcntl(self):
        with tempfile.TemporaryDirectory() as tmp:
            bin_dir = shim_bin(Path(tmp))
            env = dict(os.environ, SB_TEST_REAL_STATE=str(STATE))
            result = subprocess.run([sys.executable, str(bin_dir/STATE.name), '--help'],
                                    env=env, capture_output=True, text=True, timeout=15)
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertNotIn('ModuleNotFoundError', result.stderr)


if __name__ == '__main__':
    unittest.main()
