#!/usr/bin/env python3
"""Offline checkout identity regression at source and installed CLI boundaries."""
import hashlib
import json
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest

KIT = Path(__file__).resolve().parents[1]
CARD = {'number': 4, 'status': 'Ready', 'title': 'checkout identity'}


class CheckoutIdentityTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.temp = tempfile.TemporaryDirectory()
        cls.base = Path(cls.temp.name).resolve()
        cls.a, cls.b, cls.linked = [cls.base / name for name in ('a', 'b', 'linked')]
        cls.bin = cls.base / 'bin'
        cls.bin.mkdir()
        cls.calls = cls.base / 'calls'
        cls.config = cls.base / 'config.json'
        cls.env = dict(os.environ, HOME=str(cls.base / 'home'),
                       SUPER_BOARD_SKILLS_HOME=str(cls.base / 'home'),
                       PATH=str(cls.bin) + os.pathsep + os.environ['PATH'],
                       SB_CHECKOUT_CALLS=str(cls.calls))
        cls.env.pop('SUPER_BOARD_SKILLS_CATALOG', None)
        for repo in (cls.a, cls.b):
            cls.run_cmd(['git', 'init', '-q', str(repo)])
            (repo / 'tracked.txt').write_text('preserve this checkout\n')
            cls.run_cmd(['git', '-C', str(repo), 'add', 'tracked.txt'])
            cls.run_cmd(['git', '-C', str(repo), '-c', 'user.name=Fixture', '-c',
                         'user.email=fixture@example.test', 'commit', '-qm', 'fixture'])
        cls.run_cmd(['git', '-C', str(cls.b), 'worktree', 'add', '-qb', 'linked', str(cls.linked)])
        for repo in (cls.b, cls.linked):
            cls.run_cmd(['bash', str(KIT / 'install.sh'), '--hosts', 'claude,codex,pi', str(repo)])
            cls.run_cmd(['python3', str(KIT / 'tests/fixtures/install_worker_skills.py'), str(repo)])
        cls.alias = cls.base / 'alias'
        cls.alias.symlink_to(cls.b, target_is_directory=True)
        (cls.b / 'subdir').mkdir()
        for name in ('gh', 'pi', 'codex'):
            path = cls.bin / name
            path.write_text('''#!/usr/bin/env python3
import json, os, re, sys
from pathlib import Path
name = Path(sys.argv[0]).name
with open(os.environ['SB_CHECKOUT_CALLS'], 'a') as log:
    log.write(json.dumps({'name': name, 'cwd': os.getcwd(), 'args': sys.argv[1:]}) + '\\n')
if name == 'gh':
    if sys.argv[1:3] == ['issue', 'view']:
        print(json.dumps({'labels': ['docs']} if sys.argv[-1] == 'labels' else
                         {'number': 4, 'title': 'fixture', 'body': ''}))
    elif '--slurp' in sys.argv:
        print('[[]]')
    else:
        sys.exit('unexpected GitHub call')
else:
    prompt = sys.stdin.read()
    lane = re.search(r'Run super-(build|qa|review)', prompt)[1]
    result = json.dumps(dict(status='advanced', column={'build':'QA', 'qa':'Review', 'review':'Done'}[lane],
                            detail='fixture', prUrl=None, branch=None, priorFindings=None))
    if name == 'codex':
        Path(sys.argv[sys.argv.index('--output-last-message') + 1]).write_text(result)
    else:
        print(result)
''')
            path.chmod(0o755)

    @classmethod
    def tearDownClass(cls):
        cls.temp.cleanup()

    @classmethod
    def run_cmd(cls, command, **kwargs):
        return subprocess.run(command, env=cls.env, text=True, capture_output=True,
                              check=True, **kwargs)

    def snapshot(self):
        result = {}
        for repo in (self.a, self.b, self.linked):
            result[str(repo)] = {
                str(path.relative_to(repo)): ('link', os.readlink(path)) if path.is_symlink()
                else ('file', hashlib.sha256(path.read_bytes()).hexdigest()) if path.is_file()
                else ('dir', '')
                for path in repo.rglob('*') if '.git' not in path.relative_to(repo).parts
            }
            result[str(repo) + ':git'] = self.run_cmd(
                ['git', '-C', str(repo), 'status', '--porcelain', '--untracked-files=all']).stdout
        return result

    def invoke(self, host, wave, installed, configured, cwd=None, verify=True):
        config = {'verify_commands': ['git diff --check'] if verify else [],
                  'pi': {'provider': 'fixture', 'model': 'fixture'},
                  'codex': {'model': 'fixture'}, 'repo': {'path': configured}}
        if configured == 'OMITTED':
            config.pop('repo')
        self.config.write_text(json.dumps(config))
        scripts = self.b / '.claude/bin' if installed else KIT / 'scripts'
        script = 'super-board-codex-wave.sh' if wave else f'super-board-{host}-lane.sh'
        args = ['--cards', json.dumps([CARD])] if wave else ['--card', json.dumps(CARD), '--lane', 'build']
        if wave:
            args += ['--output', str(self.b / 'wave-result.json')]
        self.calls.unlink(missing_ok=True)
        return subprocess.run(['bash', str(scripts / script), '--config', str(self.config),
                               *args, '--' + host], cwd=cwd or self.b, env=self.env,
                              text=True, capture_output=True, timeout=30)

    def boundaries(self):
        for host in ('pi', 'codex'):
            for wave in (False, True):
                for installed in (False, True):
                    yield host, wave, installed

    def test_mismatches_refuse_before_any_startup_work(self):
        for boundary in self.boundaries():
            for actual, configured in ((self.b, self.a), (self.linked, self.b)):
                for verify in (True, False):
                    with self.subTest(boundary=boundary, actual=actual.name, verify=verify):
                        before = self.snapshot()
                        result = self.invoke(*boundary, str(configured), cwd=actual, verify=verify)
                        diagnostic = result.stderr + result.stdout
                        self.assertNotEqual(result.returncode, 0, diagnostic)
                        self.assertIn(str(actual), diagnostic)
                        self.assertIn(str(configured), diagnostic)
                        self.assertNotIn('Traceback', diagnostic)
                        self.assertNotIn('verification-readiness:', diagnostic)
                        self.assertFalse(self.calls.exists(), self.calls.read_text() if self.calls.exists() else '')
                        self.assertEqual(before, self.snapshot())

    def test_valid_paths_reach_workers(self):
        cases = [(str(self.b), self.b), (str(self.alias), self.b), (str(self.b), self.b / 'subdir'),
                 ('../b', self.b / 'subdir'), ('OMITTED', self.b), (None, self.b),
                 (str(self.linked), self.linked)]
        for boundary in self.boundaries():
            for configured, cwd in cases:
                with self.subTest(boundary=boundary, configured=configured, cwd=cwd.name):
                    result = self.invoke(*boundary, configured, cwd=cwd)
                    self.assertEqual(result.returncode, 0, result.stderr + result.stdout)
                    payload = json.loads(result.stdout)
                    if boundary[1]:
                        self.assertFalse(payload['halted'])
                        self.assertEqual(payload['cards'][0]['column'], 'Done')
                    else:
                        self.assertEqual(payload['status'], 'advanced')
                        self.assertEqual(payload['column'], 'QA')
                    calls = [json.loads(line) for line in self.calls.read_text().splitlines()]
                    self.assertTrue(any(call['name'] == 'gh' for call in calls))
                    workers = [call for call in calls if call['name'] == boundary[0]]
                    self.assertEqual(len(workers), 3 if boundary[1] else 1)
                    self.assertTrue(all(call['cwd'] == str(cwd if cwd == self.linked else self.b) for call in workers))
        (self.b / 'wave-result.json').unlink(missing_ok=True)

    def test_invalid_explicit_paths_fail_cleanly(self):
        for boundary in self.boundaries():
            for configured in ('', ' ', 7, [], {}, 'bad\x00path'):
                with self.subTest(boundary=boundary, configured=configured):
                    before = self.snapshot()
                    result = self.invoke(*boundary, configured)
                    self.assertNotEqual(result.returncode, 0)
                    self.assertNotIn('Traceback', result.stderr)
                    self.assertFalse(self.calls.exists())
                    self.assertEqual(before, self.snapshot())

    def test_setup_repairs_a_missing_installed_guard(self):
        helper = self.b / '.agents/bin/super-board-checkout.py'
        self.assertTrue(helper.is_file(), 'installer must ship the checkout guard')
        helper.unlink()
        command = ['python3', str(KIT / 'scripts/super-board-setup.py'), 'check',
                   '--root', str(self.b), '--pack', str(KIT), '--host', 'pi']
        checked = subprocess.run(command, env=self.env, text=True, capture_output=True)
        self.assertIn('script super-board-checkout.py', checked.stdout)
        fixed = self.run_cmd([*command[:2], 'fix', *command[3:], '--no-helpers'])
        self.assertTrue(helper.is_file(), fixed.stdout + fixed.stderr)
        result = self.invoke('pi', False, True, str(self.a))
        self.assertNotEqual(result.returncode, 0)
        self.assertIn(str(self.a), result.stderr)
        self.assertFalse(self.calls.exists())


if __name__ == '__main__':
    unittest.main()
