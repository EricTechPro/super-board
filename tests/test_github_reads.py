#!/usr/bin/env python3
"""Offline CLI contract: bounded required reads, validated evidence, local stop."""
import json
import os
from pathlib import Path
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]
HELPER = ROOT / 'scripts/super-board-github-read.py'


class RequiredReadTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.root = Path(self.temp.name)
        self.log = self.root / 'calls'
        self.halt = self.root / 'halt.json'
        gh = self.root / 'gh'
        gh.write_text('''#!/usr/bin/env python3
import json, os, pathlib, sys
p = pathlib.Path(os.environ['READ_CALLS'])
n = int(p.read_text()) if p.exists() else 0
p.write_text(str(n + 1))
responses = json.loads(os.environ['READ_RESPONSES'])
r = responses[min(n, len(responses)-1)]
print(r.get('out', ''), end='')
print(r.get('err', ''), file=sys.stderr)
sys.exit(r.get('rc', 0))
''')
        gh.chmod(0o755)
        self.env = dict(os.environ, PATH=f'{self.root}:{os.environ["PATH"]}',
                        READ_CALLS=str(self.log), SB_GITHUB_HALT_FILE=str(self.halt),
                        SB_GITHUB_RETRY_DELAY='0')

    def tearDown(self):
        self.temp.cleanup()

    def read(self, responses, kind='json', command=None):
        self.env['READ_RESPONSES'] = json.dumps(responses)
        return subprocess.run(['python3', str(HELPER), '--kind', kind, '--',
                               *(command or ['api', 'rate_limit'])],
                              env=self.env, text=True, capture_output=True, cwd=self.root)

    def test_three_failed_attempts_halt_without_fabricated_output(self):
        r = self.read([{'rc': 1, 'err': 'HTTP 503 unavailable'}])
        self.assertEqual(r.returncode, 79, r.stderr)
        self.assertEqual(self.log.read_text(), '3')
        self.assertEqual(r.stdout, '')
        self.assertEqual(json.loads(self.halt.read_text())['attempts'], 3)
        again = self.read([{'out': '{}'}])
        self.assertEqual(again.returncode, 79)
        self.assertEqual(self.log.read_text(), '3', 'halted run must not read again')

    def test_recovery_resets_each_logical_read(self):
        response = [{'rc': 1}, {'out': '{}'}, {'rc': 1}, {'rc': 1}, {'out': '{}'}]
        self.assertEqual(self.read(response).returncode, 0)
        self.assertEqual(self.read(response).returncode, 0)
        self.assertEqual(self.log.read_text(), '5')
        self.assertFalse(self.halt.exists())

    def test_permanent_graphql_error_is_not_retried(self):
        r = self.read([{'rc': 1, 'err': 'GraphQL: Cannot query field wrong on type Query'}],
                      command=['api', 'graphql', '-f', 'query=query { wrong }'])
        self.assertEqual(r.returncode, 79)
        self.assertEqual(self.log.read_text(), '1')

    def test_successful_exit_with_malformed_or_partial_payload_halts(self):
        for out, kind in [('not json', 'json'), ('{"resources":{"graphql":null,"core":null}}', 'quota'), ('{"unexpected":true}', 'issue'), ('[{}]', 'prs-open'), ('{"items":[{"id":"I","content":{}}],"totalCount":1}', 'items'), ('{"items":[]}', 'items'),
                          ('{"items":[],"totalCount":1}', 'items'),
                          ('{"data":{},"errors":[{"message":"partial"}]}', 'json')]:
            with self.subTest(out=out):
                self.halt.unlink(missing_ok=True)
                self.log.unlink(missing_ok=True)
                r = self.read([{'out': out}], kind)
                self.assertEqual(r.returncode, 79)
                self.assertEqual(self.log.read_text(), '3')
                self.assertEqual(r.stdout, '')

    def test_no_mutation_can_be_retried(self):
        for command in [['pr', 'merge', '1'], ['issue', 'comment', '1'],
                        ['api', 'graphql', '-f', 'query=mutation { deleteIssue }'],
                        ['api', 'graphql', '-f', 'query=query Safe { viewer { login } } mutation Unsafe { deleteIssue }', '-f', 'operationName=Unsafe'],
                        ['api', 'repos/x/y/issues', '-XPOST'],
                        ['api', 'repos/x/y/issues', '-f', 'title=hi']]:
            with self.subTest(command=command):
                r = self.read([{'out': '{}'}], command=command)
                self.assertEqual(r.returncode, 64)
                self.assertFalse(self.log.exists())

    def test_clean_empty_board_is_valid(self):
        r = self.read([{'out': '{"items":[],"totalCount":0}'}], 'items')
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertEqual(self.log.read_text(), '1')

    def test_incomplete_dependency_pages_are_not_a_graph(self):
        page = {'data': {'repository': {'issues': {
            'nodes': [], 'pageInfo': {'hasNextPage': True, 'endCursor': 'next'}}}}}
        r = self.read([{'out': json.dumps([page])}], 'issues')
        self.assertEqual(r.returncode, 79)
        self.assertEqual(self.log.read_text(), '3')

    def test_failed_recovery_keeps_original_reason(self):
        self.assertEqual(self.read([{'rc': 1}]).returncode, 79)
        original = self.halt.read_text()
        result = subprocess.run(['python3', str(HELPER), '--resume'], env=self.env, capture_output=True)
        self.assertEqual(result.returncode, 79)
        self.assertEqual(self.halt.read_text(), original)

    def test_legacy_read_failure_preserves_snapshot_and_prevents_dispatch(self):
        self.env['READ_RESPONSES'] = json.dumps([{'rc': 1}])
        script = """SB_LIB_ONLY=1 . "$1"
set +e
PROJECT_OWNER=acme PROJECT_NUMBER=1
PROJECT_ITEMS_JSON='{"items":[{"id":"preserved"}]}'
fetch_project_items; rc=$?
printf '%s %s\n' "$rc" "$PROJECT_ITEMS_JSON"
dispatch_lane build 7
"""
        result = subprocess.run(['bash', '-c', script, 'test', str(ROOT / 'scripts/super-board-run.sh')],
                                cwd=self.root, env=self.env, text=True, capture_output=True)
        self.assertEqual(result.returncode, 79, result.stderr)
        self.assertIn('79 {"items":[{"id":"preserved"}]}', result.stdout)
        self.assertEqual(self.log.read_text(), '3', 'no claim/worker or extra API call after halt')

    def test_unknown_issue_state_never_means_open(self):
        self.env['READ_RESPONSES'] = json.dumps([{'rc': 1}])
        script = 'SB_LIB_ONLY=1 . "$1"; issue_is_open 7'
        result = subprocess.run(['bash', '-c', script, 'test', str(ROOT / 'scripts/super-board-run.sh')],
                                cwd=self.root, env=self.env, capture_output=True)
        self.assertEqual(result.returncode, 79)
        self.assertEqual(self.log.read_text(), '3')

    def test_missing_quota_never_means_full_allowance(self):
        self.env['READ_RESPONSES'] = json.dumps([{'rc': 1}])
        result = subprocess.run(['bash', '-c', '. "$1"; sb_gh_guard_check 200', 'test',
                                 str(ROOT / 'scripts/super-board-gh-guard.sh')], cwd=self.root,
                                env=self.env, capture_output=True)
        self.assertEqual(result.returncode, 79)
        self.assertEqual(self.log.read_text(), '3')

    def test_truncated_diff_is_not_complete_evidence(self):
        metadata = self.root / 'meta.json'
        metadata.write_text(json.dumps({'files':[{'path':'x.sql'}], 'additions':2,'deletions':0}))
        self.env['READ_RESPONSES'] = json.dumps([{'out':'diff --git a/x.sql b/x.sql\n@@ -0,0 +1,2 @@\n+one\n'}])
        result = subprocess.run(['python3', str(HELPER), '--kind', 'diff', '--meta', str(metadata),
                                 '--', 'pr', 'diff', '1'], env=self.env, cwd=self.root, capture_output=True)
        self.assertEqual(result.returncode, 79)
        self.assertEqual(result.stdout, b'')
        self.assertEqual(self.log.read_text(), '3')

    def test_corrected_query_can_resume_without_erasing_original_failure(self):
        bad = ['api', 'graphql', '-f', 'query=query { wrong }']
        self.assertEqual(self.read([{'rc':1,'err':'Cannot query field wrong'}], command=bad).returncode,79)
        original = self.halt.read_text()
        self.env['READ_RESPONSES'] = json.dumps([{'out':'{"resources":{"graphql":{"remaining":5000,"reset":0},"core":{"remaining":5000,"reset":0}}}'}])
        result = subprocess.run(['python3',str(HELPER),'--resume','--kind','json','--',
                                 'api','graphql','-f','query=query { viewer { login } }'],
                                env=self.env,cwd=self.root,capture_output=True)
        self.assertEqual(result.returncode,0,result.stderr)
        self.assertFalse(self.halt.exists())
        records = list(self.root.glob('github-halt-*.json'))
        self.assertEqual(len(records),1)
        self.assertEqual(records[0].read_text(),original)

    def test_failed_closed_card_reconcile_keeps_claim_and_lock(self):
        lock = self.root / 'inflight'; lock.mkdir()
        # No lock initially: the card is eligible for the closed-card reconcile path.
        self.env['READ_RESPONSES'] = json.dumps([{'out':'CLOSED'}, {'rc':1}])
        script = """SB_LIB_ONLY=1 . "$1"
INFLIGHT_DIR="$2/inflight"; RUN_MANIFEST="$2/run.log"; BOT_LOGIN=robot
STATUS_FIELD_ID=field; STATUS_OPTIONS_JSON='[{"id":"done","name":"Done"}]'
PROJECT_ITEMS_JSON='{"items":[{"id":"item","status":"Review","content":{"number":7,"type":"Issue","assignees":[]}}]}'
top_card_in_column Review
"""
        result = subprocess.run(['bash','-c',script,'test',str(ROOT / 'scripts/super-board-run.sh'),str(self.root)],
                                env=self.env,cwd=self.root,capture_output=True)
        self.assertEqual(result.returncode,79,result.stderr)
        self.assertEqual(self.log.read_text(),'4','one state read, three failed project reads, no claim release')

    def test_dedupe_capped_or_malformed_data_is_never_no_match(self):
        for data in [[{}], [{'number': n+1, 'body':'old'} for n in range(200)]]:
            self.halt.unlink(missing_ok=True); self.log.unlink(missing_ok=True)
            result = self.read([{'out':json.dumps(data)}],'dedupe', ['issue','list','--json','number,body'])
            self.assertEqual(result.returncode,79)
            self.assertEqual(result.stdout,'')
            self.assertEqual(self.log.read_text(),'3')

    def test_legacy_mutation_failure_pauses_without_retry_or_lock_removal(self):
        inflight = self.root / 'inflight'; inflight.mkdir()
        lock = inflight / '7'; lock.write_text('PID=\nLANE=build\n')
        self.env['READ_RESPONSES'] = json.dumps([{'rc':1}])
        script = 'SB_LIB_ONLY=1 . "$1"; INFLIGHT_DIR="$2/inflight"; RUN_MANIFEST="$2/run.log"; BOT_LOGIN=robot; reap_finished_locks'
        result = subprocess.run(['bash','-c',script,'test',str(ROOT / 'scripts/super-board-run.sh'),str(self.root)],
                                env=self.env,cwd=self.root,capture_output=True)
        self.assertEqual(result.returncode,79)
        self.assertEqual(self.log.read_text(),'1')
        self.assertTrue(self.halt.exists())
        self.assertTrue(lock.exists())

    def test_worktrees_share_halt_and_explicit_restart_preserves_reason(self):
        self.env.pop('SB_GITHUB_HALT_FILE')
        main = self.root / 'main'; main.mkdir()
        subprocess.run(['git', 'init', '-q', str(main)], check=True)
        subprocess.run(['git', '-C', str(main), '-c', 'user.name=test', '-c', 'user.email=test@test',
                        'commit', '--allow-empty', '-qm', 'initial'], check=True)
        linked = self.root / 'linked'
        subprocess.run(['git', '-C', str(main), 'worktree', 'add', '-q', '--detach', str(linked)], check=True)
        self.env['SB_REPO_PATH'] = str(linked)
        self.assertEqual(self.read([{'rc': 1}]).returncode, 79)
        marker = main / '.claude/super-board/github-halt.json'
        self.assertTrue(marker.exists())
        self.env['SB_REPO_PATH'] = str(main)
        self.assertEqual(self.read([{'out': '{}'}]).returncode, 79)
        self.env['READ_RESPONSES'] = json.dumps([{'out': '{"resources":{"graphql":{"remaining":5000,"reset":0},"core":{"remaining":5000,"reset":0}}}'}])
        subprocess.run(['python3', str(HELPER), '--resume'], env=self.env, check=True)
        self.assertFalse(marker.exists())
        self.assertEqual(len(list(marker.parent.glob('github-halt-*.json'))), 1)
        self.assertEqual(self.read([{'out': '{}'}]).returncode, 0)


if __name__ == '__main__':
    unittest.main()
