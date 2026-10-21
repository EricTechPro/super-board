#!/usr/bin/env python3
import importlib.util
from pathlib import Path
import unittest

spec = importlib.util.spec_from_file_location('repair', Path(__file__).resolve().parents[1] / 'scripts/super-board-repair.py')
repair = importlib.util.module_from_spec(spec)
spec.loader.exec_module(repair)


class RepairBudgetTests(unittest.TestCase):
    def exhausted_normal(self):
        s = {'phase': 'idle', 'repairs': 0, 'cause': 'original'}
        for i in range(2):
            s = repair.transition(s, 'reserve', 'owner')
            self.assertEqual(s['repairs'], i + 1)
            with self.assertRaises(ValueError):
                repair.transition(s, 'reserve', 'duplicate')
            s = repair.transition(s, 'failed', 'owner', cause=f'moved hash {i}')
        return s

    def test_no_new_cause_blocks(self):
        s = repair.transition(self.exhausted_normal(), 'reserve', 'diagnoser')
        self.assertEqual(s['phase'], 'diagnosis')
        s = repair.transition(s, 'diagnosed', 'diagnoser', cause=s['cause'], test='test command')
        self.assertEqual(s['phase'], 'exhausted')
        with self.assertRaises(ValueError):
            repair.transition(s, 'reserve', 'owner')

    def test_final_failure_exhausts(self):
        s = repair.transition(self.exhausted_normal(), 'reserve', 'diagnoser')
        s = repair.transition(s, 'diagnosed', 'diagnoser', cause='different cause', test='test command expects red')
        s = repair.transition(s, 'reserve', 'final-worker')
        self.assertEqual(s['phase'], 'final')
        self.assertTrue(s['final_used'])
        s = repair.transition(s, 'failed', 'final-worker', cause='yet another hash')
        self.assertEqual(s['phase'], 'exhausted')

    def test_restart_retains_reservation_and_interruption_consumes(self):
        s = repair.transition({}, 'reserve', 'owner')
        import json
        s = json.loads(json.dumps(s))
        with self.assertRaises(ValueError):
            repair.transition(s, 'reserve', 'new-owner')
        with self.assertRaises(ValueError):
            repair.transition(s, 'interrupted', 'new-owner')
        s = repair.transition(s, 'interrupted', 'owner')
        self.assertEqual(s['repairs'], 1)
        s = repair.transition(s, 'reserve', 'new-owner')
        self.assertEqual(s['repairs'], 2)

    def test_success_releases_owner_without_refund(self):
        s = repair.transition({}, 'reserve', 'owner')
        s = repair.transition(s, 'succeeded', 'owner')
        self.assertEqual(s['phase'], 'idle')
        self.assertNotIn('owner', s)
        self.assertEqual(s['repairs'], 1)
        s = repair.transition(s, 'reserve', 'next')
        self.assertEqual(s['repairs'], 2)

    def test_final_success_does_not_allow_more_repairs(self):
        s = repair.transition(self.exhausted_normal(), 'reserve', 'diagnoser')
        s = repair.transition(s, 'diagnosed', 'diagnoser', cause='different', test='test expects red')
        s = repair.transition(s, 'reserve', 'final')
        s = repair.transition(s, 'succeeded', 'final')
        with self.assertRaises(ValueError):
            repair.transition(s, 'reserve', 'again')

    def test_old_cause_is_not_fresh(self):
        s = repair.transition(self.exhausted_normal(), 'reserve', 'diagnoser')
        s = repair.transition(s, 'diagnosed', 'diagnoser', cause='original', test='run test')
        self.assertEqual(s['phase'], 'exhausted')

    def test_missing_test_diagnosis_exhausts(self):
        s = repair.transition(self.exhausted_normal(), 'reserve', 'diagnoser')
        s = repair.transition(s, 'diagnosed', 'diagnoser', cause='new')
        self.assertEqual(s['phase'], 'exhausted')

    def test_stricter_cap_and_invalid_state(self):
        s = repair.transition({}, 'reserve', 'owner', cap=0)
        self.assertEqual(s['phase'], 'diagnosis')
        with self.assertRaises(ValueError):
            repair.transition({'repairs': True}, 'reserve', 'owner')


class CanonicalHandoffTests(unittest.TestCase):
    def setUp(self):
        import tempfile, os
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.file = self.root / 'comments.json'
        self.file.write_text('[]')
        reader = self.root / 'reader.py'
        reader.write_text("import pathlib,sys\nif '--check' not in sys.argv: print('{\"labels\":[]}' if 'labels' in sys.argv else '['+pathlib.Path(" + repr(str(self.file)) + ").read_text()+']')\n")
        gh = self.root / 'gh'
        gh.write_text("#!/usr/bin/env python3\nimport json,pathlib,sys\np=pathlib.Path(" + repr(str(self.file)) + ")\nif sys.argv[1:3] in (['label','create'],['issue','edit']): raise SystemExit(0)\nbody=json.load(sys.stdin)['body']\np.write_text(json.dumps([{'id':1,'body':body}]))\n")
        gh.chmod(0o755)
        self.path = os.environ['PATH']
        os.environ['PATH'] = str(self.root) + os.pathsep + self.path
        self.addCleanup(os.environ.__setitem__, 'PATH', self.path)
        self.handoff = repair.CanonicalHandoff(12, reader)

    def test_initial_no_record_does_not_consume(self):
        self.assertIsNone(self.handoff.reserve('owner'))
        self.assertEqual(self.file.read_text(), '[]')

    def test_write_readback_before_dispatch_and_restart(self):
        self.handoff.event('failed', 'initial', 'initial failing test', pending_lane='build')
        reserved = self.handoff.reserve('owner')
        durable = self.handoff.read()
        self.assertEqual(durable, reserved)
        self.assertEqual(durable['repairs'], 1)
        # A separate dispatcher sees the same outstanding reservation and cannot dispatch.
        restarted = repair.CanonicalHandoff(12, self.handoff.reader)
        with self.assertRaises(ValueError):
            restarted.reserve('duplicate')
        restarted.event('interrupted', 'owner')
        next_state = restarted.reserve('new-owner')
        self.assertEqual(next_state['repairs'], 2)

    def test_halt_after_readback_stops_label_mutations(self):
        import subprocess
        halted = self.root / 'halted'
        labels = self.root / 'labels-mutated'
        self.handoff.reader.write_text(
            "import pathlib,sys\nh=pathlib.Path(" + repr(str(halted)) + ")\n"
            "if h.exists(): raise SystemExit(79)\n"
            "if '--check' in sys.argv: raise SystemExit(0)\n"
            "value=pathlib.Path(" + repr(str(self.file)) + ").read_text()\n"
            "print('['+value+']')\nif value != '[]': h.touch()\n")
        gh = self.root / 'gh'
        gh.write_text(gh.read_text().replace(
            "if sys.argv[1:3] in (['label','create'],['issue','edit']): raise SystemExit(0)",
            "if sys.argv[1:3] in (['label','create'],['issue','edit']): pathlib.Path(" + repr(str(labels)) + ").touch(); raise SystemExit(0)"))
        with self.assertRaises(subprocess.CalledProcessError):
            self.handoff.event('failed', 'initial', 'failure', pending_lane='build')
        self.assertFalse(labels.exists())
        self.assertIn('repair-state:', self.file.read_text())

    def test_backslashes_and_newlines_roundtrip(self):
        cause = 'C:\\users\\fixture\nfailed command'
        self.handoff.event('failed', 'initial', cause, pending_lane='build')
        s = self.handoff.reserve('owner')
        self.handoff.event('failed', 'owner', cause)
        self.assertEqual(self.handoff.read()['cause'], cause)

    def test_multiple_records_fail_closed(self):
        import json
        body = self.handoff.marker + '\nrepair-state: {"phase":"idle","repairs":0}'
        self.file.write_text(json.dumps([{'id':1,'body':body},{'id':2,'body':body}]))
        with self.assertRaises(ValueError):
            self.handoff.reserve('owner')

    def test_nonobject_canonical_state_fails_closed(self):
        import json
        for value in ([], None, 'text', 1):
            self.file.write_text(json.dumps([{'id':1,'body':self.handoff.marker + '\nrepair-state: ' + json.dumps(value)}]))
            with self.assertRaises(ValueError):
                self.handoff.prepare('owner', 'build')

    def test_legacy_lower_bound(self):
        s = self.handoff.reserve('owner', ['loop:rebuild-2'])
        self.assertEqual(s['phase'], 'diagnosis')
        self.assertEqual(s['repairs'], 2)

    def test_initial_qa_failure_reserves_first_repair(self):
        self.handoff.event('failed', 'initial', 'test suite failed', pending_lane='qa')
        self.assertEqual(self.handoff.prepare('qa-worker', 'qa')['repairs'], 1)

    def test_initial_failure_requires_pending_lane(self):
        with self.assertRaises(ValueError):
            self.handoff.event('failed', 'initial', 'test suite failed')

    def test_completed_bad_diagnosis_exhausts(self):
        from unittest.mock import patch
        import subprocess
        original = subprocess.run
        for code, output in [(1, ''), (0, 'not json'), (0, '{"is_error":true}'), (0, '{"structured_output":[]}')]:
            self.file.write_text('[]')
            state = self.handoff.reserve('diagnoser', ['loop:rebuild-2'])
            def run(command, *args, **kwargs):
                if command[0] == 'claude':
                    return subprocess.CompletedProcess(command, code, output, '')
                return original(command, *args, **kwargs)
            with patch.object(repair.subprocess, 'run', side_effect=run):
                result = self.handoff.diagnose_claude(state, 'diagnoser')
            self.assertEqual(result['phase'], 'exhausted')
            self.assertEqual(self.handoff.read()['phase'], 'exhausted')

    def test_interrupted_diagnosis_preserves_reservation(self):
        from unittest.mock import patch
        import subprocess
        original = subprocess.run
        state = self.handoff.reserve('diagnoser', ['loop:rebuild-2'])
        def run(command, *args, **kwargs):
            if command[0] == 'claude':
                return subprocess.CompletedProcess(command, 79, '', '')
            return original(command, *args, **kwargs)
        with patch.object(repair.subprocess, 'run', side_effect=run):
            with self.assertRaises(subprocess.CalledProcessError):
                self.handoff.diagnose_claude(state, 'diagnoser')
        self.assertEqual(self.handoff.read()['phase'], 'diagnosis')

    def test_prepare_does_not_charge_read_only_qa(self):
        self.handoff.event('failed', 'initial', 'failing test', pending_lane='build')
        self.handoff.prepare('owner', 'build')
        self.handoff.event('succeeded', 'owner')
        self.assertIsNone(self.handoff.prepare('qa', 'qa', ['loop:rebuild-1']))
        self.assertEqual(self.handoff.read()['repairs'], 1)

    def test_legacy_prepare_precedes_spawn(self):
        source = (Path(__file__).resolve().parents[1] / 'scripts/super-board-run.sh').read_text()
        dispatch = source[source.index('dispatch_lane()'):]
        self.assertLess(dispatch.index('super-board-repair.py" prepare'), dispatch.index('nohup claude -p'))
        self.assertIn('--diagnose-claude', dispatch)
        self.assertIn('exit 79', dispatch[:dispatch.index('nohup claude -p')])

    def test_legacy_failed_persistence_never_spawns(self):
        import os, subprocess, sys
        stub = self.root / 'python3'
        stub.write_text('#!' + sys.executable + '\nimport sys\nraise SystemExit(1 if any("super-board-repair.py" in a for a in sys.argv) else 0)\n')
        stub.chmod(0o755)
        claude = self.root / 'claude'
        sentinel = self.root / 'spawned'
        claude.write_text('#!/bin/sh\ntouch "' + str(sentinel) + '"\n')
        claude.chmod(0o755)
        runner = Path(__file__).resolve().parents[1] / 'scripts/super-board-run.sh'
        script = 'SB_LIB_ONLY=1 source "$1"\nissue_locked() { return 1; }\nissue_is_open() { return 0; }\ngh_checkpoint() { return 0; }\ntry_claim_assignee() { return 0; }\nlog() { :; }\nPROJECT_ITEMS_JSON='"'"'{"items":[{"content":{"number":1},"status":"Ready"}]}'"'"'\ndispatch_lane build 1\n'
        result = subprocess.run(['bash','-c',script,'fixture',str(runner)], env=os.environ, capture_output=True, text=True)
        self.assertEqual(result.returncode,79,result.stderr)
        self.assertFalse(sentinel.exists())

    def test_wave_reserves_before_launch(self):
        source = (Path(__file__).resolve().parents[1] / 'scripts/super-board-codex-wave.sh').read_text()
        self.assertLess(source.index('reservation = handoff.prepare'), source.index("process = subprocess.Popen(['bash', str(launcher)"))


if __name__ == '__main__':
    unittest.main()
