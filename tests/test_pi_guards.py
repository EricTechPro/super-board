#!/usr/bin/env python3
"""Exercise the real installed guard scripts through Pi input translation."""
import json
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest

KIT = Path(__file__).resolve().parents[1]


class PiGuards(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name) / 'repo'
        self.root.mkdir()
        subprocess.run(['git', 'init', '-q', str(self.root)], check=True)
        shutil.copytree(KIT / 'hooks', self.root / '.claude/hooks')
        self.env = dict(os.environ, HOME=self.temp.name, SUPER_BOARD_PI_ROOT=str(self.root))

    def guard(self, name, values, event='PreToolUse'):
        p = subprocess.run(['python3', str(KIT / 'scripts/super-board-pi-guards.py')],
                           env=self.env, input=json.dumps(dict(toolName=name, input=values, hookEventName=event)),
                           capture_output=True, text=True)
        return json.loads(p.stdout)

    def test_real_guards_block_secret_read_outside_delete_and_worktree(self):
        for name, values in [('read', {'path':'.env'}), ('bash', {'command':'rm /outside/data'}),
                             ('bash', {'command':'git worktree add ../outside -b topic'})]:
            with self.subTest(name=name, values=values):
                self.assertTrue(self.guard(name, values)['block'])
        self.assertEqual(self.guard('read', {'path':'README.md'}), {})
        self.assertEqual(self.guard('bash', {'command':'git diff --check'}), {})

    def test_key_literal_mapping(self):
        value = 'sk-' + 'a' * 30
        self.assertTrue(self.guard('write', {'path':'a.py','content':value})['block'])
        self.assertTrue(self.guard('edit', {'path':'a.py','oldText':'x','newText':value})['block'])
        (self.root / 'a.py').write_text(value)
        self.assertTrue(self.guard('write', {'path':'a.py','content':'ignored'}, 'PostToolUse')['block'])

    def test_custom_project_hooks_preserved_and_unsupported_fail_closed(self):
        settings = self.root / '.claude/settings.json'
        settings.write_text(json.dumps({'hooks':{'PreToolUse':[{'matcher':'*','hooks':[{
            'type':'command','command':"python3 -c 'import sys;sys.exit(2)'"}]}]}}))
        self.assertTrue(self.guard('read', {'path':'README.md'})['block'])
        settings.write_text(json.dumps({'hooks':{'PreToolUse':[{'matcher':'Read','hooks':[{'type':'prompt','prompt':'approval'}]}]}}))
        self.assertTrue(self.guard('read', {'path':'README.md'})['block'])

    def test_project_ask_requires_human_instead_of_allowing(self):
        hook = self.root / 'ask.py'
        hook.write_text('import json; print(json.dumps({"hookSpecificOutput":{"permissionDecision":"ask","permissionDecisionReason":"owner approval required"}}))')
        (self.root / '.claude/settings.json').write_text(json.dumps({'hooks':{'PreToolUse':[
            {'matcher':'Read','hooks':[{'type':'command','command':f'python3 {hook}'}]}]}}))
        self.assertTrue(self.guard('read', {'path':'README.md'})['block'])

    @unittest.skipUnless(shutil.which('pi'), 'real Pi CLI unavailable')
    def test_real_cli_loads_adapter_and_rejects_broken_extension_before_tools(self):
        # Exit on session_start, without configured credentials or a model request.
        probe = Path(self.temp.name) / 'inspect.ts'
        output = Path(self.temp.name) / 'tools.json'
        probe.write_text('import { writeFileSync } from "node:fs"; export default function(pi) {'
                         'pi.on("session_start", () => {'
                         'writeFileSync(process.env.PROBE_RESULT, JSON.stringify(pi.getActiveTools()));'
                         'process.exit(0); }); }')
        env = dict(PATH=os.environ['PATH'], HOME=self.temp.name,
                   PI_CODING_AGENT_DIR=str(Path(self.temp.name) / 'pi-agent'), PROBE_RESULT=str(output),
                   SUPER_BOARD_PI_ROOT=str(self.root), SUPER_BOARD_PI_PYTHON=shutil.which('python3'),
                   SUPER_BOARD_PI_GUARDS=str(KIT / 'scripts/super-board-pi-guards.py'))
        loader = Path(shutil.which('pi')).resolve().parent / 'core/extensions/loader.js'
        if loader.is_file() and shutil.which('node'):
            # Exercise the raw .ts module through Pi's installed TypeScript loader.
            source = ("const {loadExtensions}=await import(process.argv[1]);"
                      "const r=await loadExtensions([process.argv[2]],process.cwd());"
                      "if(r.errors.length)throw new Error(JSON.stringify(r.errors));"
                      "const h=r.extensions[0].handlers;"
                      "if(!h.has('tool_call')||!h.has('tool_result'))throw new Error('missing guards');"
                      "const x=await h.get('tool_call')[0]({toolName:'read',input:{path:'.env'}});"
                      "if(!x.block)throw new Error('raw adapter did not block secret read');")
            raw = subprocess.run(['node', '--input-type=module', '-e', source, loader.as_uri(),
                                  str(KIT / 'scripts/super-board-pi-guards.ts')],
                                 cwd=self.root, env=env, text=True, capture_output=True, timeout=30)
            self.assertEqual(raw.returncode, 0, raw.stderr)
        command = ['pi', '--print', '--no-session', '--no-extensions', '--no-skills',
                   '--no-prompt-templates', '--no-themes', '--no-mcp',
                   '--extension', str(KIT / 'scripts/super-board-pi-guards.ts'),
                   '--extension', str(probe), '--provider', 'openai', '--model', 'gpt-4o',
                   '--tools', 'read,bash,edit,write']
        loaded = subprocess.run(command, cwd=self.root, env=env, input='offline startup probe',
                                text=True, capture_output=True, timeout=30)
        self.assertEqual(loaded.returncode, 0, loaded.stderr)
        self.assertEqual(set(json.loads(output.read_text())), {'read', 'bash', 'edit', 'write'})
        output.unlink()
        broken = Path(self.temp.name) / 'broken.ts'
        broken.write_text('throw new Error("offline-guard-load-failed"); export default function(pi) {}')
        failed = subprocess.run(command + ['--extension', str(broken)], cwd=self.root, env=env,
                                input='offline startup probe', text=True, capture_output=True, timeout=30)
        self.assertNotEqual(failed.returncode, 0)
        self.assertIn('offline-guard-load-failed', failed.stderr)
        self.assertFalse(output.exists(), 'a failed extension must stop before session tools become available')

    def test_explicit_claude_permission_restrictions_cannot_be_silently_bypassed(self):
        settings = self.root / '.claude/settings.json'
        for field in ['deny', 'ask']:
            with self.subTest(field=field):
                settings.write_text(json.dumps({'permissions': {field: ['Read(private/**)']}}))
                result = self.guard('read', {'path':'README.md'})
                self.assertTrue(result['block'])
                self.assertIn('permissions.deny/ask', result['reason'])

    def test_missing_guard_fails_closed(self):
        (self.root / '.claude/hooks/guard-secrets.py').unlink()
        self.assertTrue(self.guard('read', {'path':'README.md'})['block'])


if __name__ == '__main__':
    unittest.main()
