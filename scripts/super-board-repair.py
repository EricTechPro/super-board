#!/usr/bin/env python3
"""Persist bounded repair transitions in the existing canonical issue handoff."""
import argparse
import json
import sys
import re
import subprocess
from pathlib import Path


def transition(state, event, owner='', cause='', test='', cap=2):
    if not isinstance(state, dict):
        raise ValueError('repair record must be an object')
    cap = min(max(int(cap), 0), 2)
    s = dict(state)
    phase = s.get('phase', 'idle')
    repairs = s.get('repairs', 0)
    if type(repairs) is not int or repairs < 0 or repairs > 2:
        raise ValueError('invalid repairs count')
    if phase not in ('idle', 'reserved', 'diagnosis', 'final', 'exhausted'):
        raise ValueError('invalid phase')
    for key in ('diagnosis_used', 'final_used', 'different_cause'):
        if key in s and type(s[key]) is not bool:
            raise ValueError(f'invalid {key}')
    if s.get('final_used') and not s.get('diagnosis_used'):
        raise ValueError('final repair requires diagnosis evidence')
    causes = s.get('causes', [])
    if not isinstance(causes, list) or any(not isinstance(c, str) for c in causes):
        raise ValueError('invalid cause history')
    causes = list(causes)
    if s.get('cause') and s['cause'] not in causes:
        causes.append(s['cause'])
    if event == 'reserve':
        if not owner:
            raise ValueError('reservation requires the existing claim owner')
        if phase in ('reserved', 'diagnosis', 'final'):
            raise ValueError('reconcile existing reservation before redispatch')
        if phase == 'exhausted':
            raise ValueError('repair budget exhausted')
        if repairs < cap:
            s.update(phase='reserved', repairs=repairs + 1)
        elif not s.get('diagnosis_used'):
            s.update(phase='diagnosis', diagnosis_used=True)
        elif s.get('different_cause') and not s.get('final_used'):
            s.update(phase='final', final_used=True)
        else:
            raise ValueError('repair budget exhausted')
        s['owner'] = owner
    elif event in ('failed', 'succeeded', 'diagnosed', 'interrupted'):
        if not owner or s.get('owner') != owner or phase not in ('reserved', 'diagnosis', 'final'):
            raise ValueError('event requires the reservation owner')
        if event == 'diagnosed':
            if phase != 'diagnosis':
                raise ValueError('no diagnosis reserved')
            different = bool(cause.strip() and test.strip() and cause not in causes)
            s.update(different_cause=different, diagnosis_cause=cause, diagnosis_test=test,
                     phase='idle' if different else 'exhausted')
        elif event == 'succeeded':
            if phase == 'diagnosis':
                raise ValueError('diagnosis requires diagnosed evidence')
            s['phase'] = 'idle'
        elif phase in ('diagnosis', 'final'):
            s['phase'] = 'exhausted'
        else:
            s['phase'] = 'idle'
        s.pop('owner', None)
    else:
        raise ValueError('unknown event')
    if cause and event != 'diagnosed':
        s['cause'] = cause
    if cause and cause not in causes:
        causes.append(cause)
    s['causes'] = causes
    return s


class CanonicalHandoff:
    """One issue comment, written only while the dispatcher owns its card lock."""
    marker = '<!-- super-board:repair -->'

    def __init__(self, issue, reader=None):
        self.issue = issue
        self.reader = Path(reader or Path(__file__).with_name('super-board-github-read.py'))
        self.comment_id = None
        self.state = None
        self.body = None
        self.comments = []

    def read(self):
        value = subprocess.check_output([sys.executable, str(self.reader), '--kind', 'comments', '--',
            'api', f'repos/{{owner}}/{{repo}}/issues/{self.issue}/comments', '--paginate', '--slurp'], text=True)
        pages = json.loads(value)
        comments = [c for page in pages for c in (page if isinstance(page, list) else [page])]
        self.comments = comments
        records = [c for c in comments if self.marker in c.get('body', '')]
        if len(records) > 1:
            raise ValueError('multiple canonical repair handoffs; reconcile before dispatch')
        self.state = None
        self.comment_id = None
        self.body = None
        if records:
            record = records[0]
            lines = re.findall(r'^repair-state: (.+)$', record['body'], re.M)
            if len(lines) != 1 or type(record.get('id')) is not int:
                raise ValueError('unreadable canonical repair handoff')
            self.body = record['body']
            self.state = json.loads(lines[0])
            if not isinstance(self.state, dict):
                raise ValueError('canonical repair state must be an object')
            self._validate()
            self.comment_id = record['id']
        return self.state

    def _validate(self):
        try:
            transition(self.state, 'reserve', 'validation')
        except ValueError as exc:
            if str(exc) not in ('reconcile existing reservation before redispatch', 'repair budget exhausted'):
                raise

    def write(self, state):
        subprocess.run([sys.executable, str(self.reader), '--check'], check=True, stdout=subprocess.DEVNULL)
        body = (self.marker + '\n[orchestrator] [report] repair budget · ' + state['phase'] +
                '\nrepair-state: ' + json.dumps(state, sort_keys=True))
        if self.body:
            body = re.sub(r'^repair-state: .+$', lambda _: 'repair-state: ' + json.dumps(state, sort_keys=True), self.body, flags=re.M)
            body = re.sub(r'^\[orchestrator\] \[report\] repair budget · .+$',
                          lambda _: '[orchestrator] [report] repair budget · ' + state['phase'], body, flags=re.M)
        endpoint = (f'repos/{{owner}}/{{repo}}/issues/comments/{self.comment_id}' if self.comment_id else
                    f'repos/{{owner}}/{{repo}}/issues/{self.issue}/comments')
        subprocess.run(['gh', 'api', '-X', 'PATCH' if self.comment_id else 'POST', endpoint, '--input', '-'],
                       input=json.dumps({'body': body}), text=True, check=True, stdout=subprocess.DEVNULL)
        self.read()
        if self.state != state:
            raise ValueError('canonical repair write could not be verified; preserve reservation')
        current = json.loads(subprocess.check_output([sys.executable, str(self.reader), '--kind', 'object', '--',
            'issue', 'view', str(self.issue), '--json', 'labels'], text=True))
        current_labels = {label['name'] for label in current['labels']}
        labels = [f"loop:rebuild-{state.get('repairs', 0)}"]
        phase = state['phase']
        if phase in ('diagnosis', 'final', 'exhausted'):
            labels.append('loop:repair-' + phase)
        for label in labels:
            subprocess.run([sys.executable, str(self.reader), '--check'], check=True, stdout=subprocess.DEVNULL)
            subprocess.run(['gh', 'label', 'create', label, '--color', 'D4C5F9', '--force'], check=True, stdout=subprocess.DEVNULL)
        command = ['gh', 'issue', 'edit', str(self.issue)]
        for label in labels:
            command.extend(['--add-label', label])
        for old in ('diagnosis', 'final', 'exhausted'):
            if old != phase and 'loop:repair-' + old in current_labels:
                command.extend(['--remove-label', 'loop:repair-' + old])
        subprocess.run([sys.executable, str(self.reader), '--check'], check=True, stdout=subprocess.DEVNULL)
        subprocess.run(command, check=True, stdout=subprocess.DEVNULL)
        return state

    def block(self, config, detail):
        settings = json.loads(Path(config).read_text())
        next_owner = (settings.get('project', {}).get('owner') or settings.get('notifications', {}).get('bot_identity') or settings.get('bot_identity') or 'repository maintainer')
        subprocess.run([sys.executable, str(self.reader), '--check'], check=True, stdout=subprocess.DEVNULL)
        body = (f'[orchestrator] [blocker] 🛑 blocked · 🛡 repair budget exhausted\n'
                f'Card: #{self.issue}\nReason tag: 🛡\nWhy blocked: {detail}\n'
                f'Evidence: canonical repair handoff comment {self.comment_id}; {json.dumps(self.state, sort_keys=True)}\n'
                'Checked: repair/diagnosis budget exhausted; branch and worktree preserved\n'
                'What blocks: owner must review failure evidence and decide the next change\n'
                'Why I (bot) cannot decide: authorized automated repair budget is exhausted\n'
                'To unblock: [ ] inspect canonical failure evidence and preserved branch before authorizing further work\n'
                f'Owner: {next_owner}\nMove back: Ready after the explicit next decision\nblocked-by: -')
        subprocess.run(['gh', 'issue', 'comment', str(self.issue), '--body', body], check=True, stdout=subprocess.DEVNULL)
        if self.state and self.state.get('prUrl'):
            subprocess.run([sys.executable, str(self.reader), '--check'], check=True, stdout=subprocess.DEVNULL)
            subprocess.run(['gh', 'pr', 'comment', self.state['prUrl'], '--body', body], check=True, stdout=subprocess.DEVNULL)
        subprocess.run([sys.executable, str(self.reader), '--check'], check=True, stdout=subprocess.DEVNULL)
        subprocess.run(['bash', str(self.reader.with_name('super-board-card.sh')), '--config', str(config),
                        'move', str(self.issue), 'Blocked'], check=True, stdout=subprocess.DEVNULL)


    def prepare(self, owner, lane, labels=(), cap=2):
        state = self.read()
        needs = state is not None and (state.get('phase') in ('reserved', 'diagnosis', 'final', 'exhausted')
                or state.get('pending_lane') == lane or lane == 'build')
        needs = needs or (state is None and any(re.fullmatch(r'loop:rebuild-[1-9]\d*', str(label)) for label in labels))
        return self.reserve(owner, labels, cap) if needs else None

    def diagnose_claude(self, state, owner, cap=2):
        schema = {'type': 'object', 'properties': {key: {'type':'string'} for key in ('cause','test','expected')},
                  'required': ['cause','test','expected'], 'additionalProperties': False}
        accepted = subprocess.check_output([sys.executable, str(self.reader), '--kind', 'issue', '--', 'issue', 'view', str(self.issue), '--json', 'number,title,body'], text=True)
        prompt = ('Fresh independent read-only diagnosis. Do not mutate code, issues or board. '
                  'Read the accepted behavior and failing evidence below. Identify a different cause from ALL prior causes. '
                  'Return cause plus a falsifying shell test command and expected result. Empty values if none.\n' + json.dumps(state) + '\nDurable failure handoffs: ' + json.dumps(self.comments) + '\nAccepted issue: ' + accepted)
        command = ['claude', '-p', '--no-session-persistence', '--restricted', '--tools', 'Read,Grep,Glob',
                   '--strict-mcp-config', '--mcp-config', '{"mcpServers":{}}', '--output-format', 'json',
                   '--json-schema', json.dumps(schema), prompt]
        completed = subprocess.run(command, capture_output=True, text=True)
        if completed.returncode < 0 or completed.returncode in (9, 10, 79):
            raise subprocess.CalledProcessError(completed.returncode, command)
        try:
            if completed.returncode:
                raise ValueError(f'diagnosis exited {completed.returncode}')
            envelope = json.loads(completed.stdout)
            if not isinstance(envelope, dict):
                raise ValueError('diagnosis envelope must be an object')
            value = envelope.get('structured_output')
            if envelope.get('is_error') or not isinstance(value, dict) or any(not isinstance(value.get(k), str) for k in schema['required']):
                raise ValueError('independent Claude diagnosis returned invalid evidence')
        except (ValueError, TypeError) as exc:
            return self.event('failed', owner, 'independent diagnosis failed: ' + str(exc))
        evidence = value['test'] + ' => ' + value['expected'] if value['test'].strip() and value['expected'].strip() else ''
        result = self.event('diagnosed', owner, value['cause'], evidence)
        return result if result['phase'] == 'exhausted' else self.reserve(owner, cap=cap)

    def reserve(self, owner, labels=(), cap=2):
        state = self.read()
        lower = max((int(m.group(1)) for label in labels
                     if (m := re.fullmatch(r'loop:rebuild-(\d+)', str(label)))), default=0)
        if state is None and lower == 0:
            return None
        state = dict(state or {'phase': 'idle', 'repairs': min(lower, 2)})
        if lower > 2:
            state.update(phase='exhausted', legacy_rebuild_count=lower)
            self.write(state)
            raise ValueError('legacy repair budget exhausted')
        state['repairs'] = max(state.get('repairs', 0), min(lower, 2))
        try:
            reserved = transition(state, 'reserve', owner, cap=cap)
        except ValueError as exc:
            if 'exhausted' in str(exc):
                state['phase'] = 'exhausted'
                self.write(state)
            raise
        return self.write(reserved)

    def event(self, event, owner, cause='', test='', pending_lane=None, pr_url=None):
        state = self.read()
        if event == 'failed' and (state is None or state.get('phase') == 'idle') and not pending_lane:
            raise ValueError('unreserved failure requires pending repair lane')
        if state is None:
            state = {'phase': 'idle', 'repairs': 0, 'causes': [cause] if cause else []}
        elif event == 'failed' and state.get('phase') == 'idle':
            state = dict(state)
            state['causes'] = list(dict.fromkeys(state.get('causes', []) + ([cause] if cause else [])))
            state['cause'] = cause
            if state.get('final_used'):
                state['phase'] = 'exhausted'
        else:
            state = transition(state, event, owner, cause, test)
        if pr_url:
            state['prUrl'] = pr_url
        if pending_lane:
            state['pending_lane'] = pending_lane
        elif event == 'succeeded':
            state.pop('pending_lane', None)
        return self.write(state)


def main():
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument('event', choices=['prepare', 'reserve', 'failed', 'succeeded', 'diagnosed', 'interrupted'])
    p.add_argument('--owner', required=True)
    p.add_argument('--issue', type=int, help='use the canonical issue handoff instead of stdin')
    p.add_argument('--pr-url')
    p.add_argument('--pending-lane', choices=['build','qa','review'])
    p.add_argument('--lane', choices=['build','qa','review'])
    p.add_argument('--config')
    p.add_argument('--diagnose-claude', action='store_true')
    p.add_argument('--labels', default='[]', help='legacy label lower bound as JSON')
    p.add_argument('--cause', default='')
    p.add_argument('--test', default='')
    p.add_argument('--cap', type=int, default=2)
    a = p.parse_args()
    try:
        if a.issue:
            handoff = CanonicalHandoff(a.issue)
            if a.event == 'prepare':
                if not a.lane:
                    raise ValueError('prepare requires lane')
                try:
                    state = handoff.prepare(a.owner, a.lane, json.loads(a.labels), a.cap)
                    if state and state['phase'] == 'diagnosis' and a.diagnose_claude:
                        state = handoff.diagnose_claude(state, a.owner, a.cap)
                except ValueError as exc:
                    if 'exhausted' not in str(exc) or not a.config:
                        raise
                    state = handoff.state
            else:
                state = handoff.reserve(a.owner, json.loads(a.labels), a.cap) if a.event == 'reserve' else handoff.event(a.event, a.owner, a.cause, a.test, pending_lane=a.pending_lane, pr_url=a.pr_url)
            if state and state['phase'] == 'exhausted' and a.config:
                handoff.block(a.config, 'automated repair budget exhausted')
        else:
            state = transition(json.load(sys.stdin), a.event, a.owner, a.cause, a.test, a.cap)
        print(json.dumps(state, sort_keys=True))
    except (ValueError, TypeError, OSError, subprocess.CalledProcessError) as exc:
        print(f'repair halt: {exc}', file=sys.stderr)
        return 1
    return 0


if __name__ == '__main__':
    sys.exit(main())
