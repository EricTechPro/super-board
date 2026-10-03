#!/usr/bin/env python3
"""Offline upgrade acceptance tests through the setup CLI and a stateful gh boundary."""
import contextlib
import copy
import importlib.util
import io
import json
import os
from pathlib import Path
import subprocess
import tempfile
import unittest
from unittest.mock import patch

SOURCE = Path(__file__).resolve().parents[1] / 'scripts/super-board-setup.py'
spec = importlib.util.spec_from_file_location('board_setup', SOURCE)
setup = importlib.util.module_from_spec(spec)
spec.loader.exec_module(setup)


class GitHub:
    def __init__(self, count=2, complete=False):
        names = setup.COLUMNS if complete else ['Ready', 'QA', 'Review', 'Blocked', 'Done', 'Skipped']
        self.options = [dict(id='o'+str(i), name=n, color='GRAY', description='') for i,n in enumerate(names)]
        self.items = [dict(id=f'I{i}', status='Ready', updatedAt='t0',
                           content=dict(type='Issue', number=i, repository='demo/app'), labels=[])
                      for i in range(1, count+1)]
        self.labels = ['qa','bug','feature']
        self.calls = []
        self.fail = None
        self.after = None
        self.generation = 0

    def run(self, cmd, **kwargs):
        a = cmd[1:]
        self.calls.append(a)
        if self.fail and self.fail(a):
            return subprocess.CompletedProcess(cmd, 1, '', 'simulated GitHub failure')
        value = self.command(a, kwargs.get('input'))
        if self.after:
            self.after(a)
        return subprocess.CompletedProcess(cmd, 0, json.dumps(value), '')

    def node(self, item):
        status = None if item['status'] is None else dict(name=item['status'], optionId=next(o['id'] for o in self.options if o['name'] == item['status']))
        issue = item['content']
        labels = [dict(name=n) for n in sorted(item['labels'])]
        return dict(id=item['id'], updatedAt=item['updatedAt'], type='ISSUE', status=status,
                    content=dict(__typename='Issue', id='ISS'+str(issue['number']), number=issue['number'],
                                 repository=dict(nameWithOwner=issue['repository']),
                                 labels=self.page(labels, None)))

    def page(self, rows, after):
        offset = int(after or 0)
        end = min(offset+100, len(rows))
        return dict(totalCount=len(rows), nodes=rows[offset:end],
                    pageInfo=dict(hasNextPage=end<len(rows), endCursor=str(end)))

    def command(self, a, stdin):
        if a[:2] == ['project','view']:
            return {'id':'P1','url':'https://example.test/board'}
        if a[:2] == ['project','field-list']:
            return {'fields':[dict(id='F1', name='Status', options=self.options)]}
        if a[:2] == ['project','item-list']:
            return {'items':copy.deepcopy(self.items[:int(a[a.index('--limit')+1])]), 'totalCount':len(self.items)}
        if a[:2] == ['label','list']:
            return [dict(name=n) for n in self.labels]
        if a[:2] == ['label','create']:
            self.labels.append(a[2]); return {}
        if a[:2] == ['issue','edit']:
            item = next(i for i in self.items if i['content']['number'] == int(a[2]))
            if '--add-label' in a:
                for label in a[a.index('--add-label')+1].split(','):
                    if label not in item['labels']: item['labels'].append(label)
            if '--remove-label' in a:
                item['labels'] = [n for n in item['labels'] if n not in a[a.index('--remove-label')+1].split(',')]
            return {}
        if a[:2] == ['project','item-edit']:
            item = next(i for i in self.items if i['id'] == a[a.index('--id')+1])
            item['status'] = next(o['name'] for o in self.options if o['id'] == a[a.index('--single-select-option-id')+1])
            item['updatedAt'] += 'w'
            return {}
        if a[0] == 'api' and a[1].startswith('repos/'):
            return [[dict(name=n) for n in self.labels]]
        if a[:2] == ['api','graphql']:
            body = json.loads(stdin); query, v = body['query'], body['variables']
            if query.startswith('mutation'):
                self.generation += 1
                self.options = [dict(o, id=f'n{self.generation}-{i}') for i,o in enumerate(v['opts'])]
                for item in self.items:
                    item['status'] = None
                    item['updatedAt'] += 'r'
                return {'data':{'updateProjectV2Field':{'projectV2Field':{'options':copy.deepcopy(self.options)}}}}
            if 'items(first:' in query:
                return {'data':{'node':{'items':self.page([self.node(i) for i in self.items], v.get('after'))}}}
            if '... on ProjectV2Item{' in query:
                return {'data':{'node':self.node(next(i for i in self.items if i['id'] == v['id']))}}
            if '... on Issue{' in query:
                item = next(i for i in self.items if 'ISS'+str(i['content']['number']) == v['id'])
                return {'data':{'node':{'labels':self.page([dict(name=n) for n in sorted(item['labels'])], v.get('after'))}}}
            return {'data':{'node':{'options':copy.deepcopy(self.options)}}}
        raise AssertionError(a)


class UpgradeRecoveryTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name)
        self.config = self.root / 'config.json'
        self.config.write_text(json.dumps({'project':{'owner':'demo','number':1},
                                          'repo':{'remote':'https://github.com/demo/app.git'}, '_qa_all':True}))
        self.gh = GitHub(complete=True)

    def invoke(self, *args, explicit_root=True):
        output = io.StringIO()
        with patch.object(setup.subprocess, 'run', self.gh.run), contextlib.redirect_stdout(output):
            code = setup.main(['board-migrate', *(['--root',str(self.root)] if explicit_root else []), '--config',str(self.config),*args])
        return code, json.loads(output.getvalue())

    def test_restart_recovers_saved_status_after_options_rewrite(self):
        self.gh = GitHub()
        def crash(a):
            if a[:2] == ['api', 'graphql'] and self.gh.generation:
                raise KeyboardInterrupt('simulated power loss')
        self.gh.after = crash
        with self.assertRaises(KeyboardInterrupt):
            self.invoke()
        self.assertTrue(all(i['status'] is None for i in self.gh.items))
        self.gh.after = None
        code, result = self.invoke()
        self.assertEqual(code, 0, result)
        self.assertEqual([i['status'] for i in self.gh.items], ['Ready', 'Ready'])
        self.assertEqual(self.gh.generation, 1, 'do not replay an already-applied rewrite')

    def mutations(self):
        return [a for a in self.gh.calls if a[:2] in (['issue','edit'], ['label','create'], ['project','item-edit'])] + [['options']] * self.gh.generation

    def test_more_than_500_cards_are_snapshotted_and_restored(self):
        self.gh = GitHub(count=501)
        code, result = self.invoke()
        self.assertEqual(code, 0, result)
        self.assertEqual(len(self.gh.items), 501)
        self.assertTrue(all(i['status'] == 'Ready' and 'qa' in i['labels'] for i in self.gh.items))
        self.assertEqual(result['restored'], 501)

    def test_incomplete_snapshot_cannot_change_github(self):
        original = self.gh.command
        def incomplete(a, stdin):
            result = original(a, stdin)
            if a[:2] == ['api','graphql'] and 'items(first:' in json.loads(stdin)['query']:
                result['data']['node']['items']['totalCount'] += 1
            return result
        self.gh.command = incomplete
        code, result = self.invoke()
        self.assertEqual(code, 2, result)
        self.assertFalse(self.mutations())

    def test_read_failure_before_snapshot_cannot_change_github(self):
        self.gh.fail = lambda a: a[0] == 'api' and a[1].startswith('repos/')
        code, result = self.invoke()
        self.assertEqual(code, 2, result)
        self.assertFalse(self.mutations())

    def test_unwritable_recovery_record_cannot_change_github(self):
        with patch.object(setup, 'durable_json', side_effect=OSError('disk full')):
            code, result = self.invoke()
        self.assertEqual(code, 2, result)
        self.assertFalse(self.mutations())

    def test_failed_restore_resumes_from_same_snapshot(self):
        self.gh = GitHub()
        self.gh.fail = lambda a: a[:2] == ['project','item-edit']
        code, result = self.invoke()
        self.assertEqual(code, 2, result)
        self.assertTrue(json.loads(self.config.read_text())['_qa_all'])
        self.gh.fail = None
        code, result = self.invoke()
        self.assertEqual(code, 0, result)
        self.assertTrue(all(i['status'] == 'Ready' for i in self.gh.items))
        self.assertEqual(self.gh.generation, 1)

    def test_newer_status_after_interruption_is_preserved(self):
        self.gh = GitHub()
        def crash(a):
            if self.gh.generation:
                raise KeyboardInterrupt()
        self.gh.after = crash
        with self.assertRaises(KeyboardInterrupt): self.invoke()
        self.gh.after = None
        self.gh.items[0]['status'] = 'Review'
        self.gh.items[0]['updatedAt'] = 'later'
        code, result = self.invoke()
        self.assertEqual(code, 0, result)
        self.assertEqual([i['status'] for i in self.gh.items], ['Review','Ready'])
        self.assertEqual(result['preserved_edits'], ['I1'])

    def test_concurrent_edit_before_rewrite_stops_without_overwriting_it(self):
        self.gh = GitHub()
        def edit(a):
            if a[:2] == ['issue','edit']:
                self.gh.items[0]['status'] = 'Review'
                self.gh.items[0]['updatedAt'] = 'later'
        self.gh.after = edit
        code, result = self.invoke()
        self.assertEqual(code, 2, result)
        self.assertEqual(self.gh.generation, 0)
        self.assertEqual(self.gh.items[0]['status'], 'Review')

    def test_lost_rewrite_response_is_reconciled_without_replay(self):
        self.gh = GitHub()
        def lost(a):
            if self.gh.generation and not getattr(self, 'lost_once', False):
                self.lost_once = True
                raise RuntimeError('connection lost after mutation')
        self.gh.after = lost
        code, result = self.invoke()
        self.assertEqual(code, 0, result)
        self.assertEqual(self.gh.generation, 1)
        self.assertTrue(all(i['status'] == 'Ready' for i in self.gh.items))

    def test_dry_run_has_no_remote_or_recovery_writes(self):
        self.gh = GitHub()
        code, result = self.invoke('--dry-run')
        self.assertEqual(code, 0, result)
        self.assertFalse(self.mutations())
        self.assertFalse((self.root / '.claude').exists())
        self.assertTrue(json.loads(self.config.read_text())['_qa_all'])

    def test_success_maps_labels_and_skipped_then_clears_flag(self):
        self.gh = GitHub()
        self.gh.items[0]['status'] = 'Skipped'
        self.gh.items[1]['labels'] = ['build']
        code, result = self.invoke()
        self.assertEqual(code, 0, result)
        self.assertEqual([i['status'] for i in self.gh.items], ['Done','Ready'])
        self.assertEqual(self.gh.items[1]['labels'], ['feature'])
        self.assertNotIn('_qa_all', json.loads(self.config.read_text()))
        self.assertNotIn('Skipped', [o['name'] for o in self.gh.options])

    def test_corrupt_pending_record_is_not_replaced(self):
        self.gh.fail = lambda a: a[:2] == ['issue','edit']
        self.invoke()
        journal = next((self.root / '.claude/super-board/migrations').glob('*.json'))
        journal.write_text('{broken')
        self.gh.calls.clear(); self.gh.fail = None
        code, result = self.invoke()
        self.assertEqual(code, 2, result)
        self.assertFalse(self.mutations())
        self.assertEqual(journal.read_text(), '{broken')

    def test_graphql_partial_data_is_not_a_valid_snapshot(self):
        original = self.gh.command
        def partial(a, stdin):
            result = original(a, stdin)
            if a[:2] == ['api','graphql']:
                result['errors'] = [{'message':'insufficient permissions'}]
            return result
        self.gh.command = partial
        code, result = self.invoke()
        self.assertEqual(code, 2, result)
        self.assertFalse(self.mutations())

    def test_label_pagination_preserves_unrelated_labels(self):
        self.gh.items[0]['labels'] = [f'label-{i}' for i in range(105)] + ['build']
        code, result = self.invoke()
        self.assertEqual(code, 0, result)
        self.assertEqual(len(self.gh.items[0]['labels']), 106)
        self.assertIn('feature', self.gh.items[0]['labels'])
        self.assertIn('label-104', self.gh.items[0]['labels'])
        self.assertNotIn('build', self.gh.items[0]['labels'])

    def test_concurrent_clear_after_failed_restore_requires_manual_resolution(self):
        self.gh = GitHub()
        self.gh.fail = lambda a: a[:2] == ['project','item-edit']
        self.invoke()
        self.gh.items[0]['updatedAt'] = 'newer user edit'
        self.gh.fail = None; self.gh.calls.clear()
        code, result = self.invoke()
        self.assertEqual(code, 2, result)
        self.assertIsNone(self.gh.items[0]['status'])
        self.assertFalse(any(a[:2] == ['project','item-edit'] for a in self.gh.calls))

    def test_verified_restore_is_not_repeated_after_user_clears_it(self):
        self.gh = GitHub()
        def crash(a):
            if a[:2] == ['project','item-edit'] and a[a.index('--id')+1] == 'I2':
                raise KeyboardInterrupt()
            return False
        self.gh.fail = crash
        with self.assertRaises(KeyboardInterrupt): self.invoke()
        self.gh.fail = None; self.gh.calls.clear()
        self.gh.items[0]['status'] = None
        self.gh.items[0]['updatedAt'] = 'newer user edit'
        code, result = self.invoke()
        self.assertEqual(code, 0, result)
        self.assertIsNone(self.gh.items[0]['status'])
        self.assertEqual(self.gh.items[1]['status'], 'Ready')
        self.assertFalse(any(a[:2] == ['project','item-edit'] and a[a.index('--id')+1] == 'I1' for a in self.gh.calls))

    def test_concurrent_option_edit_stops_recovery(self):
        self.gh = GitHub()
        def crash(a):
            if self.gh.generation: raise KeyboardInterrupt()
        self.gh.after = crash
        with self.assertRaises(KeyboardInterrupt): self.invoke()
        self.gh.after = None
        self.gh.options[0]['description'] = 'user edit'
        code, result = self.invoke()
        self.assertEqual(code, 2, result)
        self.assertEqual(self.gh.options[0]['description'], 'user edit')
        self.assertEqual(self.gh.generation, 1)

    def test_foreign_issue_is_not_confused_with_same_number_in_configured_repo(self):
        self.gh.items[0]['content']['repository'] = 'another/project'
        code, result = self.invoke()
        self.assertEqual(code, 2, result)
        self.assertFalse(self.mutations())

    def test_semantically_corrupt_record_cannot_issue_writes(self):
        self.gh.fail = lambda a: a[:2] == ['issue','edit']
        self.invoke()
        journal = next((self.root / '.claude/super-board/migrations').glob('*.json'))
        saved = json.loads(journal.read_text())
        saved['items'][0]['want'] = 'Done'
        journal.write_text(json.dumps(saved))
        self.gh.fail = None; self.gh.calls.clear()
        code, result = self.invoke()
        self.assertEqual(code, 2, result)
        self.assertFalse(self.mutations())

    def test_repeated_success_does_not_rewrite_options(self):
        self.gh = GitHub()
        self.assertEqual(self.invoke()[0], 0)
        self.gh.calls.clear()
        self.assertEqual(self.invoke()[0], 0)
        self.assertEqual(self.gh.generation, 1)
        self.assertFalse(any(a[:2] == ['issue','edit'] for a in self.gh.calls))

    def test_absolute_config_finds_same_recovery_record_from_another_directory(self):
        self.gh = GitHub()
        destination = self.root / '.claude/super-board/configs/board.json'
        destination.parent.mkdir(parents=True)
        self.config.rename(destination)
        self.config = destination
        self.gh.fail = lambda a: a[:2] == ['project','item-edit']
        self.assertEqual(self.invoke(explicit_root=False)[0], 2)
        self.gh.fail = None
        with patch.object(setup.os, 'getcwd', return_value=str(self.root / 'different')):
            code, result = self.invoke(explicit_root=False)
        self.assertEqual(code, 0, result)
        self.assertTrue(all(i['status'] == 'Ready' for i in self.gh.items))
        self.assertEqual(self.gh.generation, 1)
        self.assertEqual(len(list(self.root.glob('**/migrations/*.json'))), 1)

    @unittest.skipIf(os.name == 'nt', 'POSIX lock assertion; Windows uses msvcrt')
    def test_second_upgrade_cannot_write_while_recovery_record_is_locked(self):
        import fcntl
        self.gh.fail = lambda a: a[:2] == ['issue','edit']
        self.invoke()
        journal = next((self.root / '.claude/super-board/migrations').glob('*.json'))
        self.gh.fail = None; self.gh.calls.clear()
        with open(str(journal)+'.lock', 'a+b') as stream:
            fcntl.flock(stream, fcntl.LOCK_EX | fcntl.LOCK_NB)
            code, result = self.invoke()
        self.assertEqual(code, 2, result)
        self.assertFalse(self.mutations())

    def test_empty_object_cannot_replace_interrupted_snapshot(self):
        self.gh = GitHub()
        def crash(a):
            if self.gh.generation: raise KeyboardInterrupt()
        self.gh.after = crash
        with self.assertRaises(KeyboardInterrupt): self.invoke()
        self.gh.after = None
        journal = next((self.root / '.claude/super-board/migrations').glob('*.json'))
        journal.write_text('{}')
        self.gh.calls.clear()
        code, result = self.invoke()
        self.assertEqual(code, 2, result)
        self.assertEqual(journal.read_text(), '{}')
        self.assertTrue(json.loads(self.config.read_text())['_qa_all'])
        self.assertFalse(any(a[:2] == ['project','item-edit'] for a in self.gh.calls))

    def test_missing_item_type_and_content_block_all_writes(self):
        self.gh = GitHub()
        self.gh.items[0]['labels'] = ['build']
        config = json.loads(self.config.read_text()); config.pop('_qa_all')
        self.config.write_text(json.dumps(config))
        original = self.gh.node
        def partial(item):
            node = original(item)
            if item['id'] == 'I1':
                node.pop('type'); node.pop('content')
            return node
        self.gh.node = partial
        code, result = self.invoke()
        self.assertEqual(code, 2, result)
        self.assertFalse(self.mutations())
        self.assertEqual(self.gh.items[0]['labels'], ['build'])

    def test_legitimate_non_issue_cards_keep_their_statuses(self):
        self.gh = GitHub(count=3)
        config = json.loads(self.config.read_text()); config.pop('_qa_all')
        self.config.write_text(json.dumps(config))
        original = self.gh.node
        def non_issue(item):
            node = original(item)
            kind, name = {'I1':('DRAFT_ISSUE','DraftIssue'), 'I2':('PULL_REQUEST','PullRequest'),
                          'I3':('REDACTED',None)}[item['id']]
            node['type'] = kind
            node['content'] = {'__typename':name} if name else None
            return node
        self.gh.node = non_issue
        code, result = self.invoke()
        self.assertEqual(code, 0, result)
        self.assertTrue(all(i['status'] == 'Ready' for i in self.gh.items))

    def test_failed_qa_label_write_keeps_upgrade_pending(self):
        self.gh.fail = lambda a: a[:2] == ['issue','edit']
        code, result = self.invoke()
        self.assertEqual(code, 2, result)
        self.assertTrue(json.loads(self.config.read_text())['_qa_all'])
        self.assertEqual([i['status'] for i in self.gh.items], ['Ready','Ready'])


if __name__ == '__main__':
    unittest.main()
