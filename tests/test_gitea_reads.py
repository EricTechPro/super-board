#!/usr/bin/env python3
"""Offline CLI contract for the gitea twin: bounded reads, normalized shapes, shared halt."""
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]
HELPER = ROOT / 'scripts/super-board-gitea-read.py'
TEA_STUB = ROOT / 'evals/_stubs/bin/tea'
SHA = 'a' * 40

DIFF = '''diff --git a/a.ts b/a.ts
index 1234567..89abcde 100644
--- a/a.ts
+++ b/a.ts
@@ -1,3 +1,4 @@
 line1
-line2
+line2x
+line2y
 line3
'''

PULL = {'number': 7, 'title': 'Fix cart', 'body': 'Closes #1\nmore', 'state': 'open',
        'merged': False, 'head': {'ref': 'fix-cart', 'sha': SHA},
        'html_url': 'https://gitea.example/example/shop/pulls/7', 'labels': []}

ISSUES = [
    {'id': 101, 'number': 1, 'title': 'Cart bug', 'body': 'broken', 'state': 'open',
     'labels': [{'id': 3, 'name': 'bug'}], 'html_url': 'u1',
     'created_at': '2026-01-01T00:00:00Z', 'updated_at': '2026-01-01T00:00:00Z'},
    {'id': 102, 'number': 2, 'title': 'Done thing', 'body': 'ok', 'state': 'closed',
     'labels': [], 'html_url': 'u2',
     'created_at': '2026-01-01T00:00:00Z', 'updated_at': '2026-01-01T00:00:00Z'},
    {'id': 103, 'number': 3, 'title': 'PR entry', 'body': '', 'state': 'open',
     'labels': [], 'html_url': 'u3', 'pull_request': {},
     'created_at': '2026-01-01T00:00:00Z', 'updated_at': '2026-01-01T00:00:00Z'},
]

COLUMNS = [{'id': 10, 'title': 'Ready', 'color': '#2563eb'},
           {'id': 11, 'title': 'Done', 'color': '#16a34a'}]


def base_state():
    issues = json.loads(json.dumps(ISSUES))
    issues[0]['_column'] = 10
    issues[1]['_column'] = 11
    return {'issues': issues, 'pulls': [json.loads(json.dumps(PULL))],
            'labels': [{'id': 3, 'name': 'bug', 'color': '#d73a4a'}],
            'projects': [{'id': 4, 'title': 'Shop Board'}],
            'columns': COLUMNS,
            'comments': {'1': [{'id': 9, 'body': 'looked into it', 'user': {'login': 'eval-bot'},
                                'created_at': '2026-01-02T00:00:00Z', 'updated_at': '2026-01-02T00:00:00Z'}]},
            'writes': 0}


class GiteaReadTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.root = Path(self.temp.name)
        (self.root / '.git').mkdir()
        (self.root / '.git/tea-fixture').mkdir()
        (self.root / '.git/tea-fixture/pull-7.diff').write_text(DIFF)
        (self.root / '.git/tea-fixture/pull-7-files.json').write_text(
            json.dumps([{'filename': 'a.ts', 'additions': 2, 'deletions': 1}]))
        (self.root / '.git/tea-state.json').write_text(json.dumps(base_state()))
        self.bin = self.root / 'bin'
        self.bin.mkdir()
        self.stub = self.bin / 'tea'
        shutil.copy(TEA_STUB, self.stub)
        self.stub.chmod(0o755)
        self.halt = self.root / 'halt.json'
        # SB_GITEA_TEA names the executable (like CLEANUP_WT_GH): on Windows a
        # PATH stub can't be spawned by CreateProcess and a real tea.exe would
        # shadow it, so the stub is invoked through bash explicitly.
        if os.name == 'nt':
            git_bash = Path(r'C:\Program Files\Git\usr\bin\bash.exe')
            bash = str(git_bash) if git_bash.exists() else 'bash'
        else:
            bash = 'bash'
        # forward slashes: SB_GITEA_TEA is split with posix shlex rules and Git
        # bash accepts C:/… paths, so one spelling works on every platform.
        tea = f'"{bash.replace(chr(92), "/")}" "{str(self.stub).replace(chr(92), "/")}"'
        self.env = dict(os.environ, PATH=f'{self.bin}:{os.environ["PATH"]}',
                        SB_GITEA_TEA=tea,
                        GITEA_REPO='example/shop', SB_GITHUB_HALT_FILE=str(self.halt),
                        SB_GITEA_RETRY_DELAY='0', SB_GITHUB_RETRY_DELAY='0')

    def tearDown(self):
        self.temp.cleanup()

    def read(self, *args, expect=0):
        r = subprocess.run([sys.executable, str(HELPER), *args], env=self.env,
                           text=True, capture_output=True, cwd=self.root)
        self.assertEqual(r.returncode, expect, f'{" ".join(args)}: {r.stderr}')
        return r

    def state(self):
        return json.loads((self.root / '.git/tea-state.json').read_text())

    def failing_tea(self, message, rc=1):
        script = self.bin / 'tea'
        script.write_text('#!/usr/bin/env bash\n'
                          f'echo "tea $*" >> "$PWD/.git/tea-calls.log"\n'
                          f'echo "{message}" >&2\nexit {rc}\n')
        script.chmod(0o755)

    # ── halt discipline ──────────────────────────────────────────────────────

    def test_three_failed_attempts_halt(self):
        self.failing_tea('ServerError: 500 boom')
        r = self.read('--kind', 'json', '--', 'api', 'repos/{owner}/{repo}/projects', expect=79)
        self.assertEqual(r.stdout, '')
        self.assertEqual(json.loads(self.halt.read_text())['attempts'], 3)
        self.assertIn('retry 2/3', r.stderr)
        # a halted run must not read again
        shutil.copy(TEA_STUB, self.bin / 'tea'); (self.bin / 'tea').chmod(0o755)
        self.read('--kind', 'json', '--', 'api', 'repos/{owner}/{repo}/projects', expect=79)
        calls = (self.root / '.git/tea-calls.log').read_text()
        self.assertEqual(calls.count('tea api'), 3)

    def test_permanent_404_halts_on_first_attempt(self):
        self.failing_tea('ServerError: 404 not found')
        self.read('--kind', 'json', '--', 'api', 'repos/{owner}/{repo}/projects', expect=79)
        self.assertEqual(json.loads(self.halt.read_text())['attempts'], 1)

    def test_check_and_resume_roundtrip(self):
        self.failing_tea('ServerError: 500 boom')
        self.read('--issue-history', 'example/shop', expect=79)
        self.read('--check', expect=79)
        shutil.copy(TEA_STUB, self.bin / 'tea'); (self.bin / 'tea').chmod(0o755)
        r = self.read('--resume')
        self.assertFalse(self.halt.exists())
        self.assertTrue(list(self.halt.parent.glob('github-halt-*.json')), 'halt not archived')
        numbers = sorted(i['number'] for i in json.loads(r.stdout))
        self.assertEqual(numbers, [1, 2])   # PR-shaped entries stay out of issue history

    def test_halt_flag_records_ambiguous_write(self):
        self.read('--halt', 'Gitea POST merge response failed', expect=79)
        self.assertEqual(json.loads(self.halt.read_text())['attempts'], 1)

    # ── passthrough ──────────────────────────────────────────────────────────

    def test_passthrough_json(self):
        r = self.read('--kind', 'json', '--', 'api', 'repos/{owner}/{repo}/projects')
        self.assertEqual(json.loads(r.stdout), [{'id': 4, 'title': 'Shop Board'}])

    def test_passthrough_rejects_writes(self):
        r = self.read('--kind', 'json', '--', 'api', '-X', 'POST',
                      'repos/{owner}/{repo}/issues', '-d', '{}', expect=64)
        self.assertIn('read-only', r.stderr)

    def test_passthrough_rejects_non_get_method_flag(self):
        self.read('--kind', 'json', '--', 'api', '-X', 'PATCH', 'repos/o/r/pulls/1', expect=64)

    # ── issue composites ─────────────────────────────────────────────────────

    def test_issue_state_and_comments(self):
        r = self.read('--kind', 'state', '--issue', '1')
        self.assertEqual(r.stdout.strip(), 'OPEN')
        r = self.read('--kind', 'issue', '--issue', '1')
        i = json.loads(r.stdout)
        self.assertEqual((i['id'], i['number'], i['state']), (101, 1, 'OPEN'))
        self.assertNotIn('_column', json.dumps(i))
        r = self.read('--kind', 'comments', '--issue', '1')
        pages = json.loads(r.stdout)
        self.assertEqual(pages[0][0]['body'], 'looked into it')

    # ── PR composites ────────────────────────────────────────────────────────

    def test_pr_head_body_merge_state(self):
        r = self.read('--kind', 'head', '--pr', '7')
        self.assertEqual(r.stdout.strip(), f'fix-cart {SHA}')
        body = json.loads(self.read('--kind', 'body', '--pr', '7').stdout)
        self.assertEqual(body['headRefOid'], SHA)
        ms = json.loads(self.read('--kind', 'merge-state', '--pr', '7').stdout)
        self.assertEqual((ms['state'], ms['headRefOid']), ('OPEN', SHA))

    def test_pr_metadata_and_diff(self):
        meta = json.loads(self.read('--kind', 'metadata', '--pr', '7').stdout)
        self.assertEqual((meta['additions'], meta['deletions'], meta['changedFiles']), (2, 1, 1))
        self.assertEqual(meta['files'][0]['path'], 'a.ts')
        meta_path = self.root / 'meta.json'
        meta_path.write_text(json.dumps(meta))
        r = self.read('--kind', 'diff', '--pr', '7', '--meta', str(meta_path))
        self.assertIn('diff --git a/a.ts', r.stdout)

    def test_pr_approval_parses_closes_trailer(self):
        a = json.loads(self.read('--kind', 'approval', '--pr', '7').stdout)
        self.assertEqual(a['closingIssues'], [{'number': 1}])
        self.assertEqual(a['headRefOid'], SHA)

    # ── board composites ─────────────────────────────────────────────────────

    def test_items_shape_matches_github_validator(self):
        r = self.read('--kind', 'items', '--items', 'example/shop/4')
        board = json.loads(r.stdout)
        self.assertEqual(board['totalCount'], 2)  # issue 3 has no column
        ready = [i for i in board['items'] if i['status'] == 'Ready'][0]
        self.assertEqual(ready['id'], 'gitea:101')
        self.assertEqual(ready['content']['number'], 1)
        self.assertEqual(ready['content']['repository'], 'example/shop')
        self.assertEqual(ready['labels'], ['bug'])

    def test_fields_synthesizes_status_field(self):
        f = json.loads(self.read('--kind', 'fields', '--fields', 'example/shop/4').stdout)
        status = f['fields'][0]
        self.assertEqual(status['name'], 'Status')
        self.assertEqual({o['name']: o['id'] for o in status['options']}, {'Ready': '10', 'Done': '11'})

    def test_project_and_projects_and_permission(self):
        p = json.loads(self.read('--kind', 'project', '--project', 'example/shop/4').stdout)
        self.assertEqual(p['id'], '4')
        ps = json.loads(self.read('--kind', 'projects', '--projects', 'example/shop').stdout)
        self.assertEqual(ps['projects'][0]['title'], 'Shop Board')
        perm = json.loads(self.read('--kind', 'permission', '--permission', 'example/shop').stdout)
        self.assertEqual(perm['permission'], 'admin')

    # ── lists ────────────────────────────────────────────────────────────────

    def test_issue_history_covers_both_states(self):
        r = self.read('--issue-history', 'example/shop')
        states = {i['number']: i['state'] for i in json.loads(r.stdout)}
        # type=issues excludes the PR-shaped entry (#3), like GraphQL repository.issues
        self.assertEqual(states, {1: 'OPEN', 2: 'CLOSED'})

    def test_prs_open_prs_merged_issues_closed(self):
        opens = json.loads(self.read('--kind', 'prs-open', '--prs-open', 'example/shop').stdout)
        self.assertEqual(opens[0]['headRefName'], 'fix-cart')
        self.assertEqual(opens[0]['files'], [{'path': 'a.ts'}])
        self.assertEqual(json.loads(self.read('--kind', 'prs-merged',
                                              '--prs-merged', 'example/shop').stdout), [])
        closed = json.loads(self.read('--kind', 'issues-closed', '--issues-closed', 'example/shop').stdout)
        self.assertEqual(closed[0]['stateReason'], 'COMPLETED')

    # ── quota ────────────────────────────────────────────────────────────────

    def test_quota_reads_headers(self):
        q = json.loads(self.read('--kind', 'quota', '--quota').stdout)
        self.assertEqual(q['rate_limits_disabled'], False)
        self.assertEqual(q['resources']['core']['remaining'], 3597)
        self.assertEqual(q['resources']['graphql']['remaining'], 3597)

    def test_quota_disabled_instances_get_sentinels(self):
        (self.root / '.git/tea-fixture/no-ratelimit').write_text('')
        q = json.loads(self.read('--kind', 'quota', '--quota').stdout)
        self.assertEqual(q['rate_limits_disabled'], True)
        self.assertEqual(q['resources']['core']['remaining'], 5000)

    # ── usage ────────────────────────────────────────────────────────────────

    def test_composite_flag_kind_mismatch_is_usage(self):
        self.read('--kind', 'json', '--items', 'example/shop/4', expect=64)

    def test_bad_owner_repo_spec_is_usage(self):
        self.read('--issue-history', 'bad spec', expect=64)


if __name__ == '__main__':
    unittest.main()
