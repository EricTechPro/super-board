#!/usr/bin/env python3
"""Exercise onboard helper repair with an offline installer and real readiness."""
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest

KIT = Path(__file__).resolve().parents[1]
SETUP = KIT / 'scripts/super-board-setup.py'


class HelperRepair(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.work = Path(self.temp.name)
        self.root = self.work / 'project'
        self.home = self.work / 'home'
        self.root.mkdir(); self.home.mkdir()
        bin_dir = self.work / 'bin'
        bin_dir.mkdir()
        self.log = self.work / 'installs.jsonl'
        installer = bin_dir / 'npx'
        installer.write_text('''#!/usr/bin/env python3
import json, os
from pathlib import Path
import sys
a = sys.argv[1:]
with open(os.environ['INSTALL_LOG'], 'a') as f:
    f.write(json.dumps(a) + '\\n')
if os.environ.get('INSTALL_FAILURE'):
    sys.stderr.write('fixture download failed')
    sys.exit(7)
agent = a[a.index('--agent') + 1] if '--agent' in a else a[a.index('-a') + 1]
directory = '.claude/skills' if agent == 'claude-code' else '.agents/skills'
if os.environ.get('INSTALL_EMPTY'):
    sys.exit(0)
if '--skill' in a:
    for name in a[a.index('--skill') + 1:]:
        if name.startswith('-'):
            break
        p = Path(directory) / name / 'SKILL.md'
        p.parent.mkdir(parents=True, exist_ok=True)
        p.write_text('Offline test fixture for ' + name + '\\n')
''')
        installer.chmod(0o755)
        self.env = dict(os.environ, HOME=str(self.home), INSTALL_LOG=str(self.log),
                        PATH=str(bin_dir) + os.pathsep + os.environ['PATH'])

    def fix(self, host='pi', extra=()):
        result = subprocess.run([sys.executable, str(SETUP), 'fix', '--root', str(self.root),
                                 '--pack', str(KIT), '--host', host, '--home', str(self.home), *extra],
                                env=self.env, text=True, capture_output=True)
        self.assertIn(result.returncode, (0, 1), result.stderr)
        return json.loads(result.stdout)

    def calls(self):
        return [json.loads(line) for line in self.log.read_text().splitlines()] if self.log.exists() else []

    def test_selected_hosts_install_the_complete_chain_and_retry_is_noop(self):
        for host, agent in [('claude', 'claude-code'), ('codex', 'codex'), ('pi', 'pi')]:
            with self.subTest(host=host):
                self.root = self.work / host
                self.root.mkdir()
                if self.log.exists():
                    self.log.unlink()
                surface = '.claude/skills' if host == 'claude' else '.agents/skills'
                keep = self.root / surface / 'tdd/SKILL.md'
                keep.parent.mkdir(parents=True)
                keep.write_text('Existing project instructions\n')
                result = self.fix(host)
                self.assertTrue(result['helper_skills'], [e['name'] for e in result['helper_readiness']['entries'] if e['status'] == 'missing'])
                self.assertTrue(result['green'], result)
                self.assertEqual(keep.read_text(), 'Existing project instructions\n')
                calls = self.calls()
                self.assertEqual(len(calls), 3, calls)
                self.assertTrue(all(c[c.index('--agent') + 1] == agent for c in calls), calls)
                self.assertTrue(all('--global' not in c and '-g' not in c for c in calls), calls)
                self.assertTrue(any('obra/superpowers' in c[3] for c in calls), calls)
                self.assertTrue(any('anthropics/knowledge-work-plugins' in c[3] for c in calls), calls)
                self.assertFalse(any('tdd' in c[c.index('--skill') + 1:] for c in calls), calls)
                self.assertTrue(self.fix(host)['helper_skills'])
                self.assertEqual(self.calls(), calls)

    def test_failed_or_empty_installer_cannot_report_ready(self):
        for mode in ['INSTALL_FAILURE', 'INSTALL_EMPTY']:
            with self.subTest(mode=mode):
                self.env[mode] = '1'
                result = self.fix()
                self.assertFalse(result['helper_skills'])
                self.assertFalse(result['green'])
                self.assertTrue(any('required skills remain unavailable' in note for note in result['notes']))
                if mode == 'INSTALL_FAILURE':
                    self.assertTrue(any('fixture download failed' in note for note in result['notes']))
                    text = subprocess.run([sys.executable, str(SETUP), 'fix', '--root', str(self.root),
                                           '--pack', str(KIT), '--host', 'pi', '--home', str(self.home), '--text'],
                                          env=self.env, text=True, capture_output=True)
                    self.assertIn('fixture download failed', text.stdout)
                del self.env[mode]

    def test_no_helpers_and_dry_run_do_not_install(self):
        for extra in [('--no-helpers',), ('--dry-run',)]:
            result = self.fix(extra=extra)
            self.assertFalse(result['helper_skills'])
            self.assertEqual(self.calls(), [])


if __name__ == '__main__':
    unittest.main()
