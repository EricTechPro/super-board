#!/usr/bin/env python3
"""Approval routing must retain mandatory and stricter project rules."""
import json
from pathlib import Path
import subprocess
import tempfile
import unittest

POLICY = Path(__file__).resolve().parents[1] / 'scripts/super-board-merge-policy.py'


class MergePolicyTests(unittest.TestCase):
    def categories(self, rules, *, label='', path='src/index.ts', added=''):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            (root / 'config').write_text(json.dumps({'merge_policy': {'always_human': rules}}))
            (root / 'meta').write_text(json.dumps({'files': [{'path': path}], 'labels': [{'name': label}]}))
            (root / 'diff').write_text('+' + added + '\n')
            result = subprocess.run(['python3', str(POLICY), '--config', str(root / 'config'),
                                     '--meta', str(root / 'meta'), '--diff', str(root / 'diff')],
                                    check=True, capture_output=True, text=True)
            return {hit['category'] for hit in json.loads(result.stdout)['human']}

    def test_new_category_does_not_replace_existing_restrictions(self):
        rules = {'external-sharing': {'paths': ['custom/export/**']},
                 'legal': {'labels': ['legal-review']}}
        for label, category in [('money', 'money'), ('auth', 'auth'), ('permissions', 'auth'),
                                ('schema', 'schema'), ('data-sharing', 'external-sharing'),
                                ('legal-review', 'legal')]:
            with self.subTest(label=label):
                self.assertIn(category, self.categories(rules, label=label))
        self.assertIn('external-sharing', self.categories(rules, path='custom/export/data.py'))

    def test_same_category_custom_rules_cannot_weaken_defaults(self):
        rules = {'auth': {'labels': ['custom-auth'], 'paths': ['private/**'],
                          'keywords': ['custom_guard(']}, 'schema': {}}
        for kwargs in [{'label': 'auth'}, {'label': 'custom-auth'},
                       {'path': 'src/permissions/check.py'}, {'path': 'private/check.py'},
                       {'added': 'jwt.sign(token)'}, {'added': 'custom_guard(user)'}]:
            with self.subTest(kwargs=kwargs):
                self.assertIn('auth', self.categories(rules, **kwargs))
        self.assertIn('schema', self.categories(rules, added='DROP TABLE users;'))

    def test_empty_map_retains_required_categories(self):
        self.assertIn('money', self.categories({}, path='src/billing/charge.py'))
        self.assertIn('external-sharing', self.categories({}, added='navigator.sendBeacon(url, data)'))

    def test_routine_change_stays_eligible(self):
        self.assertEqual(set(), self.categories({}, path='src/format.py', added='return value.strip()'))


if __name__ == '__main__':
    unittest.main()
