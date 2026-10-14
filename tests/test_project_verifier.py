#!/usr/bin/env python3
"""Exercise project-map inspection and selection through the shipped CLI."""
import hashlib
import json
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest

KIT = Path(__file__).resolve().parents[1]
CLI = KIT / 'scripts/super-board-project-verifier.py'


class ProjectVerifier(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name) / 'app'
        self.root.mkdir()
        self.skill = '.agents/skills/verify-example/SKILL.md'
        self.map = '.agents/skills/verify-example/references/feature-map.json'
        for name, content in [(self.skill, 'Real app instructions'),
                              ('checks/cart.py', 'assert result == 3'),
                              ('src/cart.py', 'product code')]:
            self.put(name, content)
        self.data = dict(version=1, app='Example', skill=self.skill, features=[dict(
            id='cart.total', description='Cart totals', route='/cart', owners=['src/*.py'],
            scenario='checks/cart.py', witness='checks/cart.test.py:12',
            expected='Three items are shown', side_effects=['API responses are mocked'])])
        self.save()

    def put(self, name, content):
        path = self.root / name
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(content)
        return path

    def save(self):
        self.put(self.map, json.dumps(self.data))

    def run_cli(self, command='inspect', changed=None, extra=(), expected=0):
        process = subprocess.run([sys.executable, str(CLI), command, '--root', str(self.root),
                                  '--map', self.map, *(['--changed', '-'] if changed is not None else []), *extra],
                                 input=json.dumps(changed) if changed is not None else None,
                                 capture_output=True, text=True)
        self.assertEqual(process.returncode, expected, process.stderr or process.stdout)
        return json.loads(process.stdout)

    def test_inspect_reports_actual_inputs_without_claiming_a_test_pass(self):
        result = self.run_cli()
        self.assertTrue(result['valid'])
        self.assertEqual(result['features'], ['cart.total'])
        self.assertEqual(result['inputs']['map']['path'], self.map)
        self.assertEqual(result['inputs']['skill']['sha256'], hashlib.sha256(b'Real app instructions').hexdigest())
        self.assertEqual(result['inputs']['scenarios'][0]['path'], 'checks/cart.py')
        self.assertNotIn('passed', result)
        self.assertNotIn('Real app instructions', json.dumps(result))

    def test_selection_unions_shared_owners_and_explicit_ids_in_map_order(self):
        self.put('docs/notes.md', 'instructions')
        shared = dict(self.data['features'][0], id='cart.checkout')
        separate = dict(shared, id='docs.guide', owners=['docs/*.md'])
        self.data['features'] += [shared, separate]
        self.save()
        result = self.run_cli('select', ['src/cart.py', 'README.md', 'README.md'],
                              extra=['--feature', 'docs.guide'])
        self.assertEqual(result['selected'], ['cart.total', 'cart.checkout', 'docs.guide'])
        self.assertEqual(result['uncovered_paths'], ['README.md'])
        self.assertEqual(self.run_cli('select', [])['selected'], [])

    def test_owner_patterns_are_root_anchored_and_match_deleted_recursive_files(self):
        self.data['features'][0]['owners'] = ['src/**/*.py']
        self.save()
        result = self.run_cli('select', ['src/deleted.py', 'src/nested/deleted.py', 'other/src/cart.py'])
        self.assertEqual(result['selected'], ['cart.total'])
        self.assertEqual(result['uncovered_paths'], ['other/src/cart.py'])

    def test_bad_schema_and_unknown_ids_are_usage_errors(self):
        self.run_cli('select', [], extra=['--feature', 'unknown'], expected=64)
        self.data['features'].append(dict(self.data['features'][0]))
        self.save(); self.run_cli(expected=64)
        self.data['features'].pop()
        for key, value in [('version', True), ('app', ''), ('features', [])]:
            saved = self.data[key]; self.data[key] = value
            self.save(); self.run_cli(expected=64)
            self.data[key] = saved
        self.put(self.map, '{'); self.run_cli(expected=64)

    def test_missing_empty_unreadable_and_broken_inputs_are_setup_errors(self):
        for name in [self.map, self.skill, 'checks/cart.py']:
            path = self.root / name
            original = path.read_bytes()
            path.write_text(''); self.run_cli(expected=9)
            path.write_bytes(original); path.chmod(0)
            self.run_cli(expected=9)
            path.chmod(0o644); path.unlink(); self.run_cli(expected=9)
            path.symlink_to(self.root / 'absent'); self.run_cli(expected=9)
            path.unlink(); path.write_bytes(original)
        self.data['features'][0]['owners'] = ['missing/*.py']
        self.save(); self.run_cli(expected=9)

    def test_absolute_traversal_nul_and_symlink_escape_are_rejected(self):
        for path in ['/tmp/outside', '../outside', 'src/../cart.py', 'C:/outside', 'src\\cart.py', 'src/\x00x']:
            self.run_cli('select', [path], expected=64)
        for key in ['scenario', 'owners']:
            saved = self.data['features'][0][key]
            self.data['features'][0][key] = ['../outside'] if key == 'owners' else '../outside'
            self.save(); self.run_cli(expected=64)
            self.data['features'][0][key] = saved
        self.save()
        outside = Path(self.temp.name) / 'outside'; outside.mkdir()
        (outside / 'file.py').write_text('private')
        (self.root / 'escape').symlink_to(outside, target_is_directory=True)
        self.run_cli('select', ['escape/file.py'], expected=9)
        self.data['features'][0]['owners'] = ['escape/*.py']
        self.save(); self.run_cli(expected=9)
        self.data['features'][0]['owners'] = ['*/absent/*.py', 'src/*.py']
        self.save(); self.run_cli(expected=9)
        self.data['features'][0]['owners'] = ['src/*.py']
        self.data['features'][0]['scenario'] = 'escape/file.py'
        self.save(); self.run_cli(expected=9)

    def test_actual_hash_changes_and_every_operation_preserves_project_bytes(self):
        def snapshot():
            return {str(path.relative_to(self.root)): path.read_bytes() for path in self.root.rglob('*') if path.is_file()}
        before = snapshot()
        initial = self.run_cli()
        self.run_cli('select', ['src/cart.py'])
        self.run_cli('select', [], extra=['--feature', 'unknown'], expected=64)
        self.assertEqual(before, snapshot())
        self.put('checks/cart.py', 'assert result == 4')
        updated = self.run_cli()
        self.assertNotEqual(initial['inputs']['scenarios'], updated['inputs']['scenarios'])
        self.put(self.skill, 'Revised instructions')
        self.assertNotEqual(updated['inputs']['skill'], self.run_cli()['inputs']['skill'])
        self.data['extra_app_specific_field'] = {'allowed': True}
        self.save()
        self.assertNotEqual(initial['inputs']['map'], self.run_cli()['inputs']['map'])

    def test_installed_helper_inspects_project_without_creating_verifier_coverage(self):
        process = subprocess.run(['bash', str(KIT / 'install.sh'), '--no-hooks', str(self.root)],
                                 capture_output=True, text=True)
        self.assertEqual(process.returncode, 0, process.stderr)
        installed = self.root / '.claude/bin/super-board-project-verifier.py'
        process = subprocess.run([sys.executable, str(installed), 'inspect', '--root', str(self.root),
                                  '--map', self.map], capture_output=True, text=True)
        self.assertEqual(process.returncode, 0, process.stderr or process.stdout)
        self.assertEqual(json.loads(process.stdout)['features'], ['cart.total'])
        starter = self.root / '.claude/skills/super-qa/templates/project-verifier/feature-map.json'
        self.assertEqual(json.loads(starter.read_text())['features'], [])
        self.assertEqual((self.root / self.skill).read_text(), 'Real app instructions')

    def test_root_symlink_loop_returns_setup_error_without_traceback(self):
        loop = Path(self.temp.name) / 'loop'
        loop.symlink_to(loop, target_is_directory=True)
        result = self.run_cli(extra=['--root', str(loop)], expected=9)
        self.assertFalse(result['valid'])


if __name__ == '__main__':
    unittest.main()
