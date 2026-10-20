#!/usr/bin/env python3
"""Adapt Pi tool calls to the installed Claude command hooks. No sandbox claim."""
import json
import os
from pathlib import Path
import re
import subprocess
import sys

GUARDS = {
    'Bash': ['guard-worktree-path.py', 'guard-delete-outside.py', 'guard-secrets.py', 'guard-key-literals.py'],
    'Read': ['guard-secrets.py'],
    'Edit': ['guard-key-literals.py'],
    'Write': ['guard-key-literals.py'],
}


def commands(root, tool, event):
    hooks = root / '.claude/hooks'
    paths = GUARDS.get(tool, []) if event == 'PreToolUse' else (['guard-key-literals.py'] if tool in ('Write', 'Edit') else [])
    calls = [[sys.executable, str(hooks / name)] for name in paths]
    protected = hooks / 'guard-protected-push.py'
    if event == 'PreToolUse' and tool == 'Bash' and protected.exists():
        calls.append([sys.executable, str(protected)])
    for path in [Path.home() / '.claude/settings.json', root / '.claude/settings.json', root / '.claude/settings.local.json']:
        if not path.exists():
            continue
        data = json.loads(path.read_text())
        permissions = data.get('permissions') or {}
        if permissions.get('deny') or permissions.get('ask'):
            raise ValueError(f'Pi guard adapter cannot enforce permissions.deny/ask in {path}; retain the Claude path')
        for group in data.get('hooks', {}).get(event, []):
            if not re.fullmatch('.*' if group.get('matcher') in (None, '', '*') else group['matcher'], tool):
                continue
            for hook in group.get('hooks', []):
                if hook.get('type') != 'command' or not isinstance(hook.get('command'), str):
                    raise ValueError(f'Pi cannot execute non-command {event} hook in {path}')
                calls.append(hook['command'])
    return calls


def check(root):
    for name in {name for names in GUARDS.values() for name in names}:
        if not (root / '.claude/hooks' / name).is_file():
            raise ValueError(f'Pi requires installed guard {name}; reinstall with hooks enabled')
    for tool in GUARDS:
        for event in ['PreToolUse', 'PostToolUse']:
            commands(root, tool, event)


def main():
    root = Path(os.environ['SUPER_BOARD_PI_ROOT']).resolve()
    check(root)
    if '--check' in sys.argv:
        return
    event = json.load(sys.stdin)
    name = {'bash': 'Bash', 'read': 'Read', 'edit': 'Edit', 'write': 'Write'}.get(event['toolName'])
    if name is None:
        raise ValueError('unexpected Pi tool')
    values = event['input']
    payload = {'tool_name': name, 'hook_event_name': event.get('hookEventName', 'PreToolUse'),
               'cwd': str(root), 'tool_input': dict(values, file_path=values.get('path', ''),
                                                    new_string=values.get('newText', ''))}
    env = dict(os.environ, CLAUDE_PROJECT_DIR=str(root))
    for command in commands(root, name, payload['hook_event_name']):
        process = subprocess.run(command, shell=isinstance(command, str), input=json.dumps(payload),
                                 text=True, capture_output=True, cwd=root, env=env, timeout=30)
        if process.returncode:
            raise ValueError('project command hook refused or failed')
        if not process.stdout.strip():
            continue
        out = json.loads(process.stdout)
        specific = out.get('hookSpecificOutput', {})
        if out.get('continue') is False or specific.get('permissionDecision') in ('deny', 'ask') or specific.get('decision') == 'block' or out.get('decision') == 'block':
            print(json.dumps({'block': True, 'reason': specific.get('permissionDecisionReason') or out.get('reason') or 'project hook refused'}))
            return
        if specific.get('additionalContext'):
            print(json.dumps({'block': True, 'reason': specific['additionalContext']}))
            return
    print('{}')


if __name__ == '__main__':
    try:
        main()
    except Exception as error:
        print(json.dumps({'block': True, 'reason': 'Pi guard check failed: ' + str(error)}))
        sys.exit(1)
