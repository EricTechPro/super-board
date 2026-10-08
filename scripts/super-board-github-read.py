#!/usr/bin/env python3
"""Bounded, read-only GitHub evidence. Exit 79 stops this repository's board run.

A logical read gets three total attempts. Success resets its own sequence; other
reads cannot reset it. Permanent query/auth errors stop on the first attempt.
The halt file is shared through the main checkout, including linked worktrees.
Only an explicit new run clears it with --resume after preserving the old reason.
Mutations never enter this retry helper. For the agent-facing kinds in FORMS, a
payload that fails its shape on every attempt is the caller's malformed read, not
an outage: that call exits 64 with the valid form and the run keeps going. Scripts
whose commands are fixed set SB_GITHUB_READ_STRICT=1 to keep halting on it.
"""
from __future__ import annotations

import argparse
import json
import os
from pathlib import Path
import re
import subprocess
import sys
import time

HALTED = 79


class ReadHalted(Exception):
    pass


class GitHubErrors(ValueError):
    """GitHub's own error payload: an outage, never the caller's shape."""


# Valid read per --kind, quoted back when a payload fails its shape.
FORMS = {
    'issue': 'issue view <N> --json number,title,body',
    'comments': 'api repos/{owner}/{repo}/issues/<N>/comments --paginate --slurp',
    'json': '<gh args> (JSON output; no --jq that prints a plain string)',
    'head': 'pr view <N> --json headRefName,headRefOid --jq \'"\\(.headRefName) \\(.headRefOid)"\'',
    'body': 'pr view <N> --json body,headRefOid',
    'metadata': 'pr view <N> --json files,labels,body,additions,deletions,changedFiles',
    'state': 'issue view <N> --json state --jq .state',
}


def halt_path():
    override = os.environ.get('SB_GITHUB_HALT_FILE')
    if override:
        return Path(override)
    result = subprocess.run(['git', 'rev-parse', '--git-common-dir'], capture_output=True,
                            text=True, timeout=5, cwd=os.environ.get('SB_REPO_PATH'))
    cwd = Path(os.environ.get('SB_REPO_PATH') or Path.cwd())
    common = Path(result.stdout.strip())
    root = (cwd / common).resolve().parent if result.returncode == 0 else cwd
    return root / '.claude/super-board/github-halt.json'


def check_halt():
    if halt_path().exists():
        raise ReadHalted('GitHub reads are halted; inspect the saved reason and explicitly restart the run')


def halt(reason, attempts, operation=None):
    path = halt_path()
    path.parent.mkdir(parents=True, exist_ok=True)
    # Exclusive creation keeps the first failure's evidence when workers trip together.
    try:
        with path.open('x') as stream:
            json.dump({'reason': reason, 'attempts': attempts, 'at': int(time.time()), 'operation': operation}, stream)
    except FileExistsError:
        pass
    raise ReadHalted(reason)


def read_only(args):
    if len(args) < 2:
        return False
    if args[0] in ('pr', 'issue', 'project', 'repo'):
        return args[1] in ('view', 'list', 'diff', 'checks', 'item-list', 'field-list')
    if args[0] != 'api':
        return False
    if any(a == '--input' or a.startswith('--input=') for a in args):
        return False
    if 'graphql' in args:
        # GraphQL queries use POST, but only a literal query may be retried.
        queries = [arg[6:] for arg in args if arg.startswith('query=')]
        return (len(queries) == 1 and re.match(r'\s*query\b', queries[0]) is not None
                and re.search(r'\b(?:mutation|subscription)\b', queries[0]) is None
                and not any(a.startswith('operationName=') for a in args))
    for i, arg in enumerate(args):
        if arg in ('-X', '--method') and (i + 1 == len(args) or args[i + 1] != 'GET'):
            return False
        if arg.startswith('-X') and arg not in ('-X', '-XGET'):
            return False
        if arg.startswith(('-f', '-F')):
            return False
        if arg.startswith('--method=') and arg != '--method=GET':
            return False
        if arg in ('-f', '-F', '--field', '--raw-field', '--input') or arg.startswith(('--field=', '--raw-field=', '--input=')):
            return False
    return True


def permanent_error(text):
    if re.search(r'rate limit|secondary rate', text, re.I):
        return False
    return re.search(r'Cannot query field|Unknown (?:argument|type)|Syntax Error|Parse error on|'
                     r'GRAPHQL_VALIDATION_FAILED|undefinedField|variableRequiresValidType|'
                     r'HTTP 40[134]|Bad credentials|requires authentication|Resource not accessible|'
                     r'Could not resolve to (?:a|an) |missing required scopes', text, re.I) is not None


def require(condition, why):
    if not condition:
        raise ValueError(why)


def no_errors(value):
    pages = value if isinstance(value, list) else [value]
    if any(isinstance(p, dict) and p.get('errors') for p in pages):
        raise GitHubErrors('GraphQL returned errors with incomplete data')


def validate(text, kind, meta=None):
    if kind == 'scalar':
        require(bool(text.strip()), 'required value missing')
        return text
    if kind == 'issue-number':
        require(not text.strip() or re.fullmatch(r'[1-9][0-9]*', text.strip()), 'invalid issue lookup result')
        return text
    if kind == 'head':
        require(re.fullmatch(r'\S+ [0-9a-f]{40}\s*', text) is not None, 'missing PR branch or full head')
        return text
    if kind == 'state':
        require(text.strip() in ('OPEN', 'CLOSED'), 'missing issue state')
        return text
    if kind == 'diff':
        require(isinstance(meta, dict), 'diff metadata missing')
        files = meta['files']
        if not files:
            require(not text.strip() and meta['additions'] == meta['deletions'] == 0, 'diff and file list disagree')
            return text
        lines = text.splitlines()
        require(sum(line.startswith('diff --git ') for line in lines) == len(files), 'diff file list incomplete')
        added = removed = 0
        old_left = new_left = 0
        for line in lines:
            if line.startswith('@@ '):
                require(old_left == new_left == 0, 'diff hunk truncated')
                hunk = re.match(r'@@ -(\d+)(?:,(\d+))? \+(\d+)(?:,(\d+))? @@', line)
                require(hunk is not None, 'diff hunk malformed')
                old_left = int(hunk[2] or 1)
                new_left = int(hunk[4] or 1)
            elif old_left or new_left:
                if line.startswith('\\ No newline'):
                    continue
                require(bool(line) and line[0] in ' +-', 'diff hunk data missing')
                if line[0] != '+': old_left -= 1
                if line[0] != '-': new_left -= 1
                if line[0] == '+': added += 1
                if line[0] == '-': removed += 1
                require(old_left >= 0 and new_left >= 0, 'diff hunk length disagrees')
            elif line and not line.startswith(('diff --git ', 'index ', '--- ', '+++ ',
                    'new file mode ', 'deleted file mode ', 'old mode ', 'new mode ',
                    'similarity index ', 'dissimilarity index ', 'rename from ', 'rename to ',
                    'copy from ', 'copy to ', 'Binary files ', '\\ No newline')):
                raise ValueError('unexpected content outside diff hunks')
        require(old_left == new_left == 0, 'diff hunk truncated')
        require(added == meta['additions'] and removed == meta['deletions'], 'diff line counts incomplete')
        return text
    value = json.loads(text)
    no_errors(value)
    if kind == 'metadata':
        require(isinstance(value, dict), 'PR metadata is not an object')
        require(isinstance(value.get('files'), list) and isinstance(value.get('labels'), list)
                and isinstance(value.get('body'), str), 'PR policy fields missing')
        require(all(type(value.get(k)) is int and value[k] >= 0 for k in ('additions', 'deletions', 'changedFiles')), 'PR counts missing')
        require(value['changedFiles'] == len(value['files']), 'PR file list truncated')
        require(all(isinstance(f, dict) and isinstance(f.get('path'), str) and f['path'] for f in value['files']), 'PR paths missing')
        require(all(isinstance(l, dict) and isinstance(l.get('name'), str) for l in value['labels']), 'PR labels missing')
    elif kind == 'items':
        require(isinstance(value, dict) and isinstance(value.get('items'), list), 'board items missing')
        require(type(value.get('totalCount')) is int and value['totalCount'] == len(value['items']), 'board item list incomplete')
        require(all(isinstance(i, dict) and isinstance(i.get('id'), str) and i['id'] and isinstance(i.get('content'), dict) for i in value['items']), 'board item data missing')
        for item in value['items']:
            content = item['content']
            require(content.get('type') in ('Issue', 'PullRequest', 'DraftIssue') and isinstance(content.get('title'), str), 'board content identity missing')
            if content['type'] != 'DraftIssue':
                require(type(content.get('number')) is int and content['number'] > 0, 'board issue number missing')
    elif kind == 'issues':
        require(isinstance(value, list) and bool(value), 'dependency pages missing')
        seen = set()
        for index, page in enumerate(value):
            connection = page['data']['repository']['issues']
            nodes, info = connection['nodes'], connection['pageInfo']
            require(isinstance(nodes, list) and type(info['hasNextPage']) is bool, 'dependency page malformed')
            require(info['hasNextPage'] == (index < len(value) - 1), 'dependency pagination incomplete')
            if info['hasNextPage']:
                require(isinstance(info.get('endCursor'), str) and info['endCursor'] and info['endCursor'] not in seen, 'dependency cursor repeated or missing')
                seen.add(info['endCursor'])
            require(all(isinstance(n, dict) and type(n.get('number')) is int and isinstance(n.get('body'), str)
                        and isinstance(n.get('title'), str) and n.get('state') == 'OPEN'
                        and isinstance(n.get('comments', {}).get('nodes'), list)
                        and isinstance(n.get('labels', {}).get('nodes'), list) for n in nodes), 'dependency issue fields missing')
    elif kind == 'quota':
        resources = value['resources']
        for bucket in ('graphql', 'core'):
            require(all(type(resources[bucket].get(k)) is int and resources[bucket][k] >= 0
                        for k in ('remaining', 'reset')), 'quota data missing')
    elif kind == 'projects':
        require(isinstance(value.get('projects'), list), 'project list missing')
    elif kind == 'project':
        require(isinstance(value, dict) and isinstance(value.get('id'), str) and value['id'], 'project ID missing')
    elif kind == 'fields':
        require(isinstance(value.get('fields'), list) and any(f.get('name') == 'Status' and f.get('id') and isinstance(f.get('options'), list) for f in value['fields']), 'Status field missing')
    elif kind == 'status-field':
        data = value['data']
        owner = data.get('user') or data.get('organization')
        field = owner['projectV2']['field']
        require(isinstance(field.get('id'), str) and field['id'] and isinstance(field.get('options'), list)
                and all(isinstance(o, dict) and o.get('id') and o.get('name') for o in field['options']), 'Status field missing')
    elif kind == 'permission':
        require(value.get('permission') in ('none', 'read', 'triage', 'write', 'maintain', 'admin'), 'collaborator permission missing')
    elif kind == 'comments':
        require(isinstance(value, list) and bool(value) and all(isinstance(p, list) for p in value), 'comment pages missing')
        require(all(isinstance(c, dict) and type(c.get('id')) is int and isinstance(c.get('body'), str)
                    and isinstance(c.get('user'), dict) and c.get('created_at') and c.get('updated_at')
                    for page in value for c in page), 'comment fields missing')
    elif kind == 'approval':
        require(isinstance(value, list) and bool(value), 'approval pages missing')
        heads = set()
        for i, page in enumerate(value):
            pr = page['data']['repository']['pullRequest']
            require(re.fullmatch(r'[0-9a-f]{40}', pr['headRefOid']) and pr['state'] in ('OPEN', 'CLOSED', 'MERGED'), 'PR identity missing')
            heads.add(pr['headRefOid'])
            links = pr['closingIssuesReferences']
            require(type(links['pageInfo']['hasNextPage']) is bool and links['pageInfo']['hasNextPage'] == (i < len(value) - 1), 'approval pagination incomplete')
            require(isinstance(links['nodes'], list), 'linked issues missing')
        require(len(heads) == 1, 'PR changed during approval read')
    elif kind == 'merge-state':
        require(value.get('state') in ('OPEN', 'CLOSED', 'MERGED') and re.fullmatch(r'[0-9a-f]{40}', value.get('headRefOid', '')), 'merge outcome unreadable')
        if value['state'] == 'MERGED':
            require(re.fullmatch(r'[0-9a-f]{40}', (value.get('mergeCommit') or {}).get('oid', '')), 'merged commit missing')
    elif kind == 'body':
        require(isinstance(value.get('body'), str) and re.fullmatch(r'[0-9a-f]{40}', value.get('headRefOid', '')), 'PR body/head missing')
    elif kind == 'dedupe':
        require(isinstance(value, list) and len(value) < 200, 'dedupe list missing or capped; fetch complete issue history before creating')
        require(all(isinstance(i, dict) and type(i.get('number')) is int and i['number'] > 0 and isinstance(i.get('body'), str) for i in value), 'dedupe issue fields missing')
    elif kind in ('prs-open', 'prs-merged', 'issues-closed', 'issue'):
        entries = [value] if kind == 'issue' else value
        require(isinstance(entries, list), 'required issue/PR list missing')
        for entry in entries:
            require(isinstance(entry, dict) and type(entry.get('number')) is int and entry['number'] > 0
                    and isinstance(entry.get('title'), str) and isinstance(entry.get('body'), str), 'issue/PR identity or body missing')
            if kind.startswith('prs-'):
                require(isinstance(entry.get('url'), str), 'PR URL missing')
            if kind == 'prs-open':
                require(isinstance(entry.get('headRefName'), str) and entry['headRefName'] and isinstance(entry.get('files'), list)
                        and all(isinstance(f, dict) and isinstance(f.get('path'), str) and f['path'] for f in entry['files']), 'open PR branch/files missing')
            if kind == 'issues-closed':
                require(entry.get('stateReason') in ('COMPLETED', 'NOT_PLANNED', 'REOPENED', None) and 'stateReason' in entry, 'closed issue reason missing')
    elif kind == 'object':
        require(isinstance(value, dict) and bool(value), 'required object missing')
    elif kind == 'array':
        require(isinstance(value, list), 'required list missing')
    return value


def read(args, kind='json', meta=None, recovering=False):
    if not read_only(args):
        raise ValueError('retry helper accepts read-only GitHub commands only')
    if not recovering:
        check_halt()
    operation = {'args': args, 'kind': kind, 'meta': meta}
    last = 'GitHub read failed'
    shape_only = True  # every attempt reached GitHub and got a payload of the wrong shape
    delay = float(os.environ.get('SB_GITHUB_RETRY_DELAY', '1'))
    for attempt in range(1, 4):
        if not recovering:
            check_halt()
        try:
            result = subprocess.run(['gh', *args], capture_output=True, text=True, timeout=30)
            diagnostic = result.stderr
            if result.returncode:
                diagnostic += result.stdout
            elif kind != 'diff':
                try:
                    payload = json.loads(result.stdout)
                    diagnostic += json.dumps([p.get('errors', []) for p in (payload if isinstance(payload, list) else [payload]) if isinstance(p, dict)])
                except ValueError:
                    pass
            if permanent_error(diagnostic):
                halt('GitHub rejected a required read (query, authentication, or permission error); fix it before restarting', attempt, operation)
            if result.returncode:
                shape_only = False
                status = re.search(r'HTTP [0-9]{3}', result.stderr)
                last = 'GitHub required read failed' + (f' ({status[0]})' if status else '')
            else:
                try:
                    value = validate(result.stdout, kind, meta)
                    if not recovering:
                        check_halt()
                    return result.stdout, value
                except (ValueError, KeyError, TypeError, AttributeError, IndexError) as error:
                    last = f'GitHub required read returned incomplete evidence: {error}'
                    shape_only = shape_only and not isinstance(error, GitHubErrors)
        except (OSError, subprocess.SubprocessError):
            shape_only = False
            last = 'GitHub required read timed out or could not start'
        if attempt < 3:
            print(f'[github-read] {last}; retry {attempt + 1}/3', file=sys.stderr)
            time.sleep(max(0, delay) * attempt)
    if shape_only and kind in FORMS and not os.environ.get('SB_GITHUB_READ_STRICT'):
        raise ValueError(f'{last}; this call failed, the run continues. Valid form: --kind {kind} -- {FORMS[kind]}')
    halt(f'{last}; stopped after 3 failed attempts', 3, operation)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--kind', choices=('json','scalar','issue-number','head','state','diff','metadata','items','issues','quota','projects','project','fields','status-field','permission','comments','approval','merge-state','body','dedupe','prs-open','prs-merged','issues-closed','issue','object','array'))
    parser.add_argument('--meta')
    parser.add_argument('--check', action='store_true')
    parser.add_argument('--halt', help='record an unresolved mutation outcome and stop; never retry it')
    parser.add_argument('--resume', action='store_true')
    parser.add_argument('command', nargs=argparse.REMAINDER)
    args = parser.parse_args()
    command = args.command[1:] if args.command[:1] == ['--'] else args.command
    try:
        if args.halt:
            halt(args.halt, 1)
        if args.resume:
            path = halt_path()
            if path.exists():
                record = json.loads(path.read_text())
                operation = record.get('operation')
                if not isinstance(operation, dict):
                    raise ReadHalted('saved failure needs manual outcome reconciliation before restart')
                if command:
                    if args.kind != operation['kind']:
                        raise ValueError('replacement recovery read must validate the same evidence kind')
                    meta = json.loads(Path(args.meta).read_text()) if args.meta else operation.get('meta')
                    if args.kind == 'diff':
                        validate(json.dumps(meta), 'metadata')
                    read(command, args.kind, meta, recovering=True)
                else:
                    read(operation['args'], operation['kind'], operation.get('meta'), recovering=True)
                read(['api', 'rate_limit'], 'quota', recovering=True)
                path.replace(path.with_name(f'github-halt-{time.time_ns()}.json'))
            return 0
        if args.check:
            check_halt()
            return 0
        meta = json.loads(Path(args.meta).read_text()) if args.meta else None
        output, _ = read(command, args.kind or 'json', meta)
        sys.stdout.write(output)
        return 0
    except ReadHalted as error:
        print(f'[github-read] HALT: {error}. Saved at {halt_path()}', file=sys.stderr)
        return HALTED
    except (ValueError, OSError) as error:
        print(f'[github-read] {error}', file=sys.stderr)
        return 64


if __name__ == '__main__':
    sys.exit(main())
