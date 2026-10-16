#!/usr/bin/env python3
"""Bounded, read-only Gitea evidence through the tea CLI. Exit 79 stops the run.

The gitea twin of super-board-github-read.py: same CLI surface, same retry
discipline (three attempts, permanent errors stop on the first), same halt
file (.claude/super-board/github-halt.json — one halt per repo, name kept for
compatibility), same exit codes (79 halted, 64 caller's malformed shape).
It reuses github-read's halt machinery and diff validator by importing it.

Two call styles:

1. Passthrough — validate whatever a read-only tea command printed:
     super-board-gitea-read.py --kind json -- api repos/{owner}/{repo}/issues
   read_only_tea() rejects any method but GET and any body/field flag.

2. Composite — the wrapper performs the (paginated, multi-endpoint) read and
   prints the SAME normalized shape the github path produces, so card.sh,
   wave-plan, merge-policy and friends stay shape-stable across forges:
     --issue N          kinds: issue · state · comments
     --pr N             kinds: head · body · merge-state · metadata · diff (--meta) · approval
     --items O/R/PROJECT kind items   (project = the Gitea project's API id)
     --fields O/R/PROJECT kind fields (Status field synthesized from columns)
     --project O/R/P · --projects O/R · --permission O/R
     --issue-history O/R · --prs-open O/R · --prs-merged O/R · --issues-closed O/R
     --quota            (header probe; rate_limits_disabled:true when the
                         instance sends no X-RateLimit-* — resources then carry
                         sentinel 5000s so old readers never sleep forever)

Gitea degradations, documented in references/gitea.md: approval's
closingIssuesReferences becomes a `Closes #N` body parse (fail-closed: no
trailer, no link); stateReason does not exist (closed issues validate as
COMPLETED); DraftIssue cards do not exist.

Env: SB_FORGE_LOGIN (tea --login), GITEA_REPO or SB_FORGE_OWNER/SB_FORGE_REPO
(tea api placeholder context), SB_GITEA_TIMEOUT (default 30s per spawn — a
broken tea binary hangs instead of failing), SB_GITEA_RETRY_DELAY,
SB_GITEA_READ_STRICT, SB_GITHUB_HALT_FILE, SB_REPO_PATH.
"""
from __future__ import annotations

import argparse
import importlib.util
import json
import os
from pathlib import Path
import re
import shlex
import subprocess
import sys
import time

# ── shared machinery from the github twin ─────────────────────────────────────
_spec = importlib.util.spec_from_file_location(
    'super_board_github_read', Path(__file__).resolve().with_name('super-board-github-read.py'))
ghread = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(ghread)

HALTED = ghread.HALTED            # 79
ReadHalted = ghread.ReadHalted
halt_path = ghread.halt_path
check_halt = ghread.check_halt
halt = ghread.halt
require = ghread.require

PAGE_LIMIT = 50                   # per-request page size for Gitea list endpoints
MAX_PAGES = 40                    # truncation guard: 2000 issues/PRs per list
TEA_TIMEOUT = int(os.environ.get('SB_GITEA_TIMEOUT', '30'))

# Agent-facing kinds whose payload is the caller's responsibility (passthrough).
FORMS = {
    'json': 'api <GET endpoint> (JSON output)',
    'scalar': 'api <GET endpoint> printing one value',
    'object': 'api <GET endpoint> (JSON object)',
    'array': 'api <GET endpoint> (JSON array)',
    'issue-number': 'api <GET endpoint> printing an issue number or nothing',
}

class GiteaErrors(ValueError):
    """The server's own error payload: an outage, never the caller's shape."""


def read_only_tea(args):
    """Only GETs may be retried. Mirrors github-read's read_only gate."""
    if not args:
        return False
    if args[0] == 'version':
        return True
    if args[0] == 'login':
        return args[1:2] in (['ls'], ['list'])
    if args[0] != 'api':
        return False
    rest = args[1:]
    for i, a in enumerate(rest):
        if a in ('-X', '--method'):
            if i + 1 >= len(rest) or rest[i + 1].upper() != 'GET':
                return False
        elif a.startswith('--method='):
            if a.split('=', 1)[1].upper() != 'GET':
                return False
        elif a.startswith('-X'):
            if a[2:].upper() != 'GET':
                return False
        elif a in ('-d', '--data', '-f', '-F', '--input') or a.startswith(('-d', '-f', '-F', '--input=', '--data=')):
            return False
    return True


def permanent_error(text):
    if re.search(r'rate limit|too many requests|\b429\b', text, re.I):
        return False
    return re.search(r'HTTP 40[134]|\b40[134]\b|\b422\b|invalid token|token (?:is )?required|'
                     r'unauthorized|forbidden|user does not exist|not found', text, re.I) is not None


def _tea_env():
    env = dict(os.environ)
    if not env.get('GITEA_REPO'):
        owner, repo = env.get('SB_FORGE_OWNER', ''), env.get('SB_FORGE_REPO', '')
        if owner and repo:
            env['GITEA_REPO'] = f'{owner}/{repo}'
    return env


def tea_cmd():
    """The tea executable, overridable like cleanup-wt.py's CLEANUP_WT_GH —
    tests point it at `bash evals/_stubs/bin/tea`. Quote paths with spaces;
    on Windows use forward slashes (posix shlex rules, which Git bash accepts)."""
    return shlex.split(os.environ.get('SB_GITEA_TEA', 'tea'))


def _tea(args):
    """One bounded tea spawn. Returns (stdout, stderr, returncode)."""
    cmd = tea_cmd()
    login = os.environ.get('SB_FORGE_LOGIN')
    if login:
        cmd += ['--login', login]
    cmd += args
    # encoding: tea prints UTF-8 JSON; on Windows text=True would otherwise
    # decode with the console codepage and mangle every emoji (reason tags!).
    r = subprocess.run(cmd, capture_output=True, text=True, encoding='utf-8',
                       errors='replace', timeout=TEA_TIMEOUT, env=_tea_env())
    return r.stdout, r.stderr, r.returncode


def tea_get(endpoint):
    """GET one endpoint through `tea api`; returns parsed JSON. Raises on failure."""
    out, err, rc = _tea(['api', '-X', 'GET', endpoint])
    if rc:
        raise GiteaErrors(f'tea api GET {endpoint} failed: {(err or out).strip()[:300]}')
    try:
        return json.loads(out)
    except ValueError:
        raise GiteaErrors(f'tea api GET {endpoint} printed non-JSON: {out.strip()[:200]}')


def tea_get_paged(endpoint):
    """Paginate a Gitea list endpoint. Raises when the cap truncates a full page."""
    sep = '&' if '?' in endpoint else '?'
    pages = []
    for page in range(1, MAX_PAGES + 1):
        batch = tea_get(f'{endpoint}{sep}page={page}&limit={PAGE_LIMIT}')
        require(isinstance(batch, list), f'{endpoint} page {page} is not a list')
        pages.append(batch)
        if len(batch) < PAGE_LIMIT:
            return pages
    raise GiteaErrors(f'{endpoint} still full after {MAX_PAGES} pages — evidence would be truncated')


def _or_path(spec):
    """'owner/repo' → (owner, repo); anything else is a usage error."""
    require(spec and re.fullmatch(r'[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+', spec) is not None,
            'expected owner/repo')
    return spec.split('/', 1)


def _or_project(spec):
    """'owner/repo/project' → (owner, repo, project id)."""
    parts = (spec or '').split('/')
    require(len(parts) == 3 and all(parts) and parts[2].isdigit(), 'expected owner/repo/project')
    return parts[0], parts[1], parts[2]


# ── normalization: Gitea REST → the shapes the github path prints ─────────────

def _labels(entry):
    return [{'name': l.get('name', '')} for l in (entry.get('labels') or [])]


def map_issue(i):
    return {'id': i.get('id'), 'number': i.get('number'), 'title': i.get('title', ''),
            'body': i.get('body') or '', 'state': (i.get('state') or '').upper(),
            'url': i.get('html_url', ''), 'labels': _labels(i),
            'assignees': [{'login': a.get('login', '')} for a in (i.get('assignees') or [])]}


def map_pull(owner, repo, p, with_files=False):
    head = p.get('head') or {}
    state = 'MERGED' if p.get('merged') else (p.get('state') or '').upper()
    out = {'number': p.get('number'), 'title': p.get('title', ''), 'body': p.get('body') or '',
           'state': state, 'url': p.get('html_url', ''), 'labels': _labels(p),
           'headRefName': head.get('ref', ''), 'headRefOid': head.get('sha', '')}
    if state == 'MERGED':
        out['mergeCommit'] = {'oid': p.get('merge_commit_sha') or head.get('sha', '')}
    if with_files:
        files = tea_get(f'repos/{owner}/{repo}/pulls/{p["number"]}/files')
        require(isinstance(files, list), 'PR file list is not a list')
        out['files'] = [{'path': f.get('filename', ''), 'additions': f.get('additions', 0),
                         'deletions': f.get('deletions', 0)} for f in files]
        out['additions'] = sum(f['additions'] for f in out['files'])
        out['deletions'] = sum(f['deletions'] for f in out['files'])
        out['changedFiles'] = len(out['files'])
    return out


CLOSES_RE = re.compile(r'\b(?:close[sd]?|fixe[sd]?|resolve[sd]?)\s*:?\s+#(\d+)', re.I)


def op_issue(owner, repo, n, kind):
    i = tea_get(f'repos/{owner}/{repo}/issues/{n}')
    require(isinstance(i, dict) and i.get('number') == int(n), f'issue {n} unreadable')
    if kind == 'state':
        state = (i.get('state') or '').upper()
        require(state in ('OPEN', 'CLOSED'), 'missing issue state')
        return state + '\n', None
    if kind == 'comments':
        pages = tea_get_paged(f'repos/{owner}/{repo}/issues/{n}/comments')
        norm = [[{'id': c.get('id'), 'body': c.get('body') or '', 'user': c.get('user') or {},
                  'created_at': c.get('created_at'), 'updated_at': c.get('updated_at')}
                 for c in page] for page in pages]
        require(bool(norm), 'comment pages missing')
        for page in norm:
            for c in page:
                require(type(c['id']) is int and isinstance(c['body'], str) and isinstance(c['user'], dict)
                        and c['created_at'] and c['updated_at'], 'comment fields missing')
        return json.dumps(norm), norm
    return json.dumps(map_issue(i)), None


def op_pr(owner, repo, n, kind, meta):
    p = tea_get(f'repos/{owner}/{repo}/pulls/{n}')
    require(isinstance(p, dict) and p.get('number') == int(n), f'PR {n} unreadable')
    m = map_pull(owner, repo, p, with_files=(kind in ('metadata', 'diff')))
    if kind == 'head':
        require(m['headRefName'] and re.fullmatch(r'[0-9a-f]{40}', m['headRefOid']),
                'missing PR branch or full head')
        return f"{m['headRefName']} {m['headRefOid']}\n", None
    if kind == 'body':
        return json.dumps({'body': m['body'], 'headRefOid': m['headRefOid']}), None
    if kind == 'merge-state':
        return json.dumps({'state': m['state'], 'headRefOid': m['headRefOid'],
                           'mergeCommit': m.get('mergeCommit')}), None
    if kind == 'metadata':
        return json.dumps(m), None
    if kind == 'diff':
        require(isinstance(meta, dict), 'diff metadata missing')
        out, err, rc = _tea(['api', '-X', 'GET', f'repos/{owner}/{repo}/pulls/{n}.diff'])
        require(rc == 0, f'PR diff unreadable: {err.strip()[:200]}')
        ghread.validate(out, 'diff', meta)   # same hunk-counting validator as github
        return out, None
    if kind == 'approval':
        # Gitea has no closingIssuesReferences; the writing standard's `Closes #N`
        # trailer is the contract. Fail-closed: no trailer means no linked issues,
        # and approval.py refuses to merge without them.
        numbers = sorted({int(x) for x in CLOSES_RE.findall(m['body'])})
        require(re.fullmatch(r'[0-9a-f]{40}', m['headRefOid']) and m['state'] in ('OPEN', 'CLOSED', 'MERGED'),
                'PR identity missing')
        return json.dumps({'headRefOid': m['headRefOid'], 'state': m['state'],
                           'closingIssues': [{'number': n} for n in numbers]}), None
    raise ValueError(f'--pr does not serve kind "{kind}"')


def op_items(owner, repo, project):
    columns = tea_get(f'repos/{owner}/{repo}/projects/{project}/columns')
    require(isinstance(columns, list) and bool(columns), 'project has no columns')
    items, seen = [], set()
    for col in columns:
        cid, title = col.get('id'), col.get('title', '')
        require(cid is not None and title, 'column identity missing')
        for page in tea_get_paged(f'repos/{owner}/{repo}/projects/{project}/columns/{cid}/issues'):
            for entry in page:
                gid = entry.get('id')
                require(gid is not None and gid not in seen, 'board item duplicated or id-less')
                seen.add(gid)
                is_pr = entry.get('pull_request') is not None
                item = {'id': f'gitea:{gid}', 'status': title, 'title': entry.get('title', ''),
                        'content': {'type': 'PullRequest' if is_pr else 'Issue',
                                    'number': entry.get('number'), 'title': entry.get('title', ''),
                                    'url': entry.get('html_url', ''), 'repository': f'{owner}/{repo}'}}
                names = [l.get('name') for l in (entry.get('labels') or []) if l.get('name')]
                if names:
                    item['labels'] = names
                items.append(item)
    payload = {'items': items, 'totalCount': len(items)}
    ghread.validate(json.dumps(payload), 'items')   # same board validator as github
    return json.dumps(payload), payload


def op_fields(owner, repo, project):
    columns = tea_get(f'repos/{owner}/{repo}/projects/{project}/columns')
    require(isinstance(columns, list) and bool(columns), 'project has no columns')
    options = [{'id': str(c['id']), 'name': c.get('title', '')} for c in columns]
    require(all(c.get('id') is not None and c.get('title') for c in columns), 'column identity missing')
    payload = {'fields': [{'name': 'Status', 'id': f'gitea:status:{project}', 'options': options}]}
    ghread.validate(json.dumps(payload), 'fields')
    return json.dumps(payload), payload


def op_project(owner, repo, project):
    p = tea_get(f'repos/{owner}/{repo}/projects/{project}')
    require(isinstance(p, dict) and p.get('id') is not None, 'project unreadable')
    payload = {'id': str(p['id']), 'title': p.get('title', '')}
    ghread.validate(json.dumps(payload), 'project')
    return json.dumps(payload), payload


def op_projects(owner, repo):
    projects = []
    for page in tea_get_paged(f'repos/{owner}/{repo}/projects'):
        projects += [{'id': p.get('id'), 'title': p.get('title', ''), 'description': p.get('description', '')}
                     for p in page]
    payload = {'projects': projects}
    ghread.validate(json.dumps(payload), 'projects')
    return json.dumps(payload), payload


def op_permission(owner, repo):
    r = tea_get(f'repos/{owner}/{repo}')
    perms = (r or {}).get('permissions') or {}
    level = 'admin' if perms.get('admin') else 'write' if perms.get('push') else 'read' if perms.get('pull') else 'none'
    payload = {'permission': level}
    ghread.validate(json.dumps(payload), 'permission')
    return json.dumps(payload), payload


def op_issue_history(owner, repo):
    out = []
    for state in ('open', 'closed'):
        for page in tea_get_paged(f'repos/{owner}/{repo}/issues?state={state}&type=issues'):
            for i in page:
                require(type(i.get('number')) is int and i['number'] > 0 and isinstance(i.get('body') or '', str),
                        'issue history fields missing')
                out.append({'number': i['number'], 'state': (i.get('state') or '').upper(), 'body': i.get('body') or ''})
    numbers = [i['number'] for i in out]
    require(len(numbers) == len(set(numbers)), 'issue history duplicated a number')
    return json.dumps(out), out


def op_deps(owner, repo):
    """Open issues with their last 8 comments — in the GraphQL node shape the
    deps.sh parser reads (labels.nodes / comments.nodes; its jq `//` fallbacks
    cannot catch a plain array, indexing it errors first).
    One list read plus one comments read per open issue: Gitea has no single
    query for both (documented degradation vs the GitHub GraphQL call)."""
    out = []
    for page in tea_get_paged(f'repos/{owner}/{repo}/issues?state=open&type=issues'):
        for i in page:
            require(type(i.get('number')) is int and i['number'] > 0, 'deps issue number missing')
            comments = []
            for cpage in tea_get_paged(f'repos/{owner}/{repo}/issues/{i["number"]}/comments'):
                comments += [{'body': c.get('body') or ''} for c in cpage if isinstance(c, dict)]
            out.append({'number': i['number'], 'title': i.get('title', ''),
                        'body': i.get('body') or '', 'state': 'OPEN',
                        'labels': {'nodes': [{'name': l.get('name', '')} for l in (i.get('labels') or [])
                                             if isinstance(l, dict)]},
                        'comments': {'nodes': comments[-8:]}})
    return json.dumps(out), out


def op_prs(owner, repo, kind):
    state = 'open' if kind == 'prs-open' else 'closed'
    out = []
    for page in tea_get_paged(f'repos/{owner}/{repo}/pulls?state={state}&sort=oldest'):
        for p in page:
            if kind == 'prs-merged' and not p.get('merged'):
                continue
            m = map_pull(owner, repo, p, with_files=(kind == 'prs-open'))
            entry = {'number': m['number'], 'title': m['title'], 'body': m['body'], 'url': m['url']}
            if kind == 'prs-open':
                entry['headRefName'] = m['headRefName']
                entry['files'] = [{'path': f['path']} for f in m['files']]
            out.append(entry)
    require(isinstance(out, list), 'PR list missing')
    for e in out:
        require(type(e.get('number')) is int and e['number'] > 0 and isinstance(e.get('title'), str)
                and isinstance(e.get('body'), str) and isinstance(e.get('url'), str), 'PR identity missing')
        if kind == 'prs-open':
            require(isinstance(e.get('headRefName'), str) and e['headRefName'] and isinstance(e['files'], list)
                    and all(isinstance(f, dict) and f.get('path') for f in e['files']), 'open PR branch/files missing')
    return json.dumps(out), out


def op_issues_closed(owner, repo):
    out = []
    for page in tea_get_paged(f'repos/{owner}/{repo}/issues?state=closed&type=issues'):
        for i in page:
            require(type(i.get('number')) is int and i['number'] > 0 and isinstance(i.get('body') or '', str),
                    'closed issue fields missing')
            # Gitea has no stateReason; a closed issue validates as COMPLETED.
            out.append({'number': i['number'], 'title': i.get('title', ''), 'body': i.get('body') or '',
                        'stateReason': 'COMPLETED'})
    return json.dumps(out), out


def op_quota():
    # `-i` prints response headers to stderr; stdout stays clean JSON.
    out, err, rc = _tea(['api', '-i', '-X', 'GET', 'version'])
    require(rc == 0, f'quota probe failed: {err.strip()[:200]}')
    headers = {k.lower(): v.strip() for k, _, v in (line.partition(':') for line in err.splitlines())}
    now = int(time.time())
    disabled = 'x-ratelimit-limit' not in headers

    def bucket(prefix):
        if disabled:
            return {'limit': 5000, 'remaining': 5000, 'used': 0, 'reset': now + 3600}
        limit = int(headers.get(f'x-ratelimit-{prefix}', '0') or 0)
        remaining = int(headers.get(f'x-ratelimit-remaining', '0') or 0)
        reset = int(headers.get(f'x-ratelimit-reset', '0') or 0)
        return {'limit': limit, 'remaining': remaining, 'used': max(0, limit - remaining),
                'reset': reset if reset > 0 else now + 3600}

    core = bucket('limit')
    payload = {'resources': {'core': core, 'graphql': dict(core)}, 'rate_limits_disabled': disabled}
    ghread.validate(json.dumps(payload), 'quota')
    return json.dumps(payload), payload


# ── bounded retry over a whole logical read ───────────────────────────────────

def read_logical(fn, kind, operation, recovering=False):
    """Three attempts over the whole composite read; same halt discipline."""
    if not recovering:
        check_halt()
    last = 'Gitea read failed'
    shape_only = True
    delay = float(os.environ.get('SB_GITEA_RETRY_DELAY', os.environ.get('SB_GITHUB_RETRY_DELAY', '1')))
    for attempt in range(1, 4):
        if not recovering:
            check_halt()
        try:
            output, _ = fn()
            if not recovering:
                check_halt()
            return output
        except GiteaErrors as error:
            shape_only = False
            last = f'Gitea required read failed: {error}'
            if permanent_error(str(error)):
                halt('Gitea rejected a required read (authentication, permission, or missing resource); '
                     'fix it before restarting', attempt, operation)
        except (ValueError, KeyError, TypeError, AttributeError, IndexError) as error:
            last = f'Gitea required read returned incomplete evidence: {error}'
        except (OSError, subprocess.SubprocessError):
            shape_only = False
            last = 'Gitea required read timed out or could not start (is tea installed and logged in?)'
        if attempt < 3:
            print(f'[gitea-read] {last}; retry {attempt + 1}/3', file=sys.stderr)
            time.sleep(max(0, delay) * attempt)
    if shape_only and kind in FORMS and not os.environ.get('SB_GITEA_READ_STRICT'):
        raise ValueError(f'{last}; this call failed, the run continues. Valid form: --kind {kind} -- {FORMS[kind]}')
    halt(f'{last}; stopped after 3 failed attempts', 3, operation)


def repo_context():
    """owner/repo from GITEA_REPO / SB_FORGE_* so composite ops work in worktrees."""
    spec = os.environ.get('GITEA_REPO')
    if not spec:
        owner, repo = os.environ.get('SB_FORGE_OWNER', ''), os.environ.get('SB_FORGE_REPO', '')
        spec = f'{owner}/{repo}' if owner and repo else ''
    require(spec, 'repo context missing: set GITEA_REPO (forge.sh exports it) or pass owner/repo flags')
    return _or_path(spec)


def serve(argv, recovering=False):
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument('--kind', default='json')
    parser.add_argument('--meta')
    parser.add_argument('--check', action='store_true')
    parser.add_argument('--halt', help='record an unresolved mutation outcome and stop; never retry it')
    parser.add_argument('--resume', action='store_true')
    parser.add_argument('--issue', help='issue/PR number in the resolved repo')
    parser.add_argument('--pr', help='PR number in the resolved repo')
    parser.add_argument('--items', help='owner/repo/project — whole board (kind items)')
    parser.add_argument('--fields', help='owner/repo/project — Status field from columns (kind fields)')
    parser.add_argument('--project', help='owner/repo/project — one project (kind project)')
    parser.add_argument('--projects', help='owner/repo — project list (kind projects)')
    parser.add_argument('--permission', help='owner/repo — collaborator level (kind permission)')
    parser.add_argument('--issue-history', help='owner/repo — complete all-state issue history')
    parser.add_argument('--deps', help='owner/repo — open issues + last 8 comments (deps.sh node shape)')
    parser.add_argument('--prs-open', help='owner/repo')
    parser.add_argument('--prs-merged', help='owner/repo')
    parser.add_argument('--issues-closed', help='owner/repo')
    parser.add_argument('--quota', action='store_true', help='rate-limit probe (kind quota)')
    parser.add_argument('command', nargs=argparse.REMAINDER)
    args = parser.parse_args(argv)
    command = args.command[1:] if args.command[:1] == ['--'] else args.command
    kind = args.kind
    composite = any([args.issue, args.pr, args.items, args.fields, args.project, args.projects,
                     args.permission, args.issue_history, args.deps, args.prs_open, args.prs_merged,
                     args.issues_closed, args.quota])

    try:
        if args.halt:
            halt(args.halt, 1)
        if args.check:
            check_halt()
            return 0
        if args.resume:
            path = halt_path()
            if path.exists():
                record = json.loads(path.read_text())
                operation = record.get('operation')
                if not isinstance(operation, dict) or not operation.get('gitea'):
                    raise ReadHalted('saved failure needs manual outcome reconciliation before restart')
                if command or composite:
                    if kind != operation.get('kind'):
                        raise ValueError('replacement recovery read must validate the same evidence kind')
                    replay = [a for a in argv if a != '--resume']
                else:
                    replay = operation.get('argv') or []
                rc = serve(replay, recovering=True)
                if rc == 0:
                    read_logical(op_quota, 'quota', {'gitea': True, 'argv': ['--quota'], 'kind': 'quota'},
                                 recovering=True)
                    path.replace(path.with_name(f'github-halt-{time.time_ns()}.json'))
                return rc
        meta = json.loads(Path(args.meta).read_text()) if args.meta else None
        operation = {'gitea': True, 'argv': list(argv), 'kind': kind}

        # Passthrough: validate a read-only tea command's own output.
        if command and not composite:
            require(read_only_tea(command), 'retry helper accepts read-only tea commands only')
            require(kind in FORMS, f'kind "{kind}" needs its composite flag; passthrough serves '
                                   + ', '.join(sorted(FORMS)))

            def _passthrough():
                out, err, rc = _tea(command)
                if rc:
                    raise GiteaErrors((err or out).strip()[:300])
                ghread.validate(out, kind)
                return out, None

            sys.stdout.write(read_logical(_passthrough, kind, operation, recovering))
            return 0

        # Composites: the wrapper performs and normalizes the read.
        def run_op():
            if args.quota:
                require(kind == 'quota', '--quota serves kind quota')
                return op_quota()
            if args.items:
                require(kind == 'items', '--items serves kind items')
                return op_items(*_or_project(args.items))
            if args.fields:
                require(kind == 'fields', '--fields serves kind fields')
                return op_fields(*_or_project(args.fields))
            if args.project:
                require(kind == 'project', '--project serves kind project')
                return op_project(*_or_project(args.project))
            if args.projects:
                require(kind == 'projects', '--projects serves kind projects')
                return op_projects(*_or_path(args.projects))
            if args.permission:
                require(kind == 'permission', '--permission serves kind permission')
                return op_permission(*_or_path(args.permission))
            if args.issue_history:
                return op_issue_history(*_or_path(args.issue_history))
            if args.deps:
                return op_deps(*_or_path(args.deps))
            if args.prs_open:
                require(kind == 'prs-open', '--prs-open serves kind prs-open')
                return op_prs(*_or_path(args.prs_open), 'prs-open')
            if args.prs_merged:
                require(kind == 'prs-merged', '--prs-merged serves kind prs-merged')
                return op_prs(*_or_path(args.prs_merged), 'prs-merged')
            if args.issues_closed:
                require(kind == 'issues-closed', '--issues-closed serves kind issues-closed')
                return op_issues_closed(*_or_path(args.issues_closed))
            if args.pr:
                require(kind in ('head', 'body', 'merge-state', 'metadata', 'diff', 'approval'),
                        f'--pr does not serve kind "{kind}"')
                owner, repo = repo_context()
                return op_pr(owner, repo, args.pr, kind, meta)
            if args.issue:
                require(kind in ('issue', 'state', 'comments'), f'--issue does not serve kind "{kind}"')
                owner, repo = repo_context()
                return op_issue(owner, repo, args.issue, kind)
            raise ValueError('nothing to read: pass a composite flag or -- <tea api GET …>')

        sys.stdout.write(read_logical(run_op, kind, operation, recovering))
        return 0
    except ReadHalted as error:
        print(f'[gitea-read] HALT: {error}. Saved at {halt_path()}', file=sys.stderr)
        return HALTED
    except (ValueError, OSError) as error:
        print(f'[gitea-read] {error}', file=sys.stderr)
        return 64


if __name__ == '__main__':
    sys.exit(serve(sys.argv[1:]))
