#!/usr/bin/env python3
"""Resolve the actual host-visible worker chain. Read-only; exits 10 if incomplete.

--cards accepts an array file or stdin (-). --hydrate fills absent issue bodies via
our guarded GitHub reader before resolution. --profile setup checks the pack and
unconditional helper union. --home and --catalog isolate authoritative inventories.
No directory, lockfile, or plugin cache is evidence of an available skill.
"""
from __future__ import annotations
import argparse
import json
import os
from pathlib import Path
import re
import stat
import subprocess
import sys

POLICY = 'skills/super-build/references/decision-policy.md'
REGISTRY = {
    'build_rows': [(['bug'], ['mattpocock-skills:diagnosing-bugs', 'mattpocock-skills:tdd']),
                   (['feature'], ['mattpocock-skills:implement', 'mattpocock-skills:tdd', 'mattpocock-skills:codebase-design']),
                   (['ux'], ['mattpocock-skills:implement', 'mattpocock-skills:tdd']),
                   (['refactor', 'tech-debt'], ['mattpocock-skills:codebase-design', 'mattpocock-skills:tdd']),
                   (['tests'], ['mattpocock-skills:tdd']), (['docs'], [])],
    'default': ['mattpocock-skills:tdd'],
    'boundaries': {
        'build': ['ponytail:ponytail', 'verification-before-completion', 'mattpocock-skills:code-review'],
        'qa': ['mattpocock-skills:tdd', 'mattpocock-skills:diagnosing-bugs', 'verification-before-completion',
               'testing-strategy', 'mattpocock-skills:code-review'],
        'review': ['mattpocock-skills:code-review', 'mattpocock-skills:codebase-design']},
    'conditional': {
        'build': ['vitest', 'playwright-best-practices', 'testing-strategy',
                  'mattpocock-skills:resolving-merge-conflicts', 'mattpocock-skills:domain-modeling'],
        'qa': ['mattpocock-skills:ask-matt', 'vitest', 'playwright-best-practices'], 'review': []},
    'optional': {'build': [], 'qa': [], 'review': ['ponytail:ponytail-review']},
    'aliases': {'mattpocock-skills': ['diagnosing-bugs', 'tdd', 'implement', 'codebase-design', 'code-review',
                                   'resolving-merge-conflicts', 'domain-modeling', 'ask-matt', 'to-spec', 'to-tickets', 'improve-codebase-architecture'],
                'ponytail': ['ponytail', 'ponytail-review']},
    'fallbacks': {'ponytail:ponytail': {'id': 'simplest-solution-first', 'source': POLICY + '#simplest-solution-first'},
                  'ponytail:ponytail-review': {'id': 'over-engineering-ladder', 'source': 'skills/super-review/SKILL.md#over-engineering'}},
}
CORE = ['super-board', 'super-build', 'super-qa', 'super-review', 'super-collect', 'visual', 'git-sync', 'ui-refine-loop']
LANES = ['build', 'qa', 'review']
NAME = re.compile(r'[a-zA-Z0-9][a-zA-Z0-9._-]*(?::[a-zA-Z0-9][a-zA-Z0-9._-]*)?\Z')
INTERACTIVE = {'grilling', 'shape', 'clarify', 'mattpocock-skills:grilling', 'mattpocock-skills:shape', 'mattpocock-skills:clarify'}


def valid_name(name):
    if not isinstance(name, str) or not NAME.fullmatch(name) or '..' in name:
        raise ValueError('invalid skill name: ' + repr(name))
    return name


def worker_name(name):
    valid_name(name)
    if name in INTERACTIVE:
        raise ValueError('interactive/prohibited worker skill: ' + name)
    return name


def override(body):
    if not isinstance(body, str):
        raise ValueError('each card needs its literal issue body')
    fence = None
    found = None
    for line in body.splitlines():
        match = re.match(r'^\s{0,3}(`{3,}|~{3,})', line)
        if match:
            marker = match.group(1)
            if fence is None:
                fence = marker
            elif marker[0] == fence[0] and len(marker) >= len(fence):
                fence = None
            continue
        match = re.match(r'^Skills:\s*(.*)$', line, re.I) if fence is None else None
        if not match:
            continue
        raw = match.group(1).strip()
        names = []
        for part in raw.split(',') if raw else []:
            token = part.strip()
            if token.startswith('`') or token.endswith('`'):
                if not (token.startswith('`') and token.endswith('`') and token.count('`') == 2):
                    raise ValueError('unbalanced skill backtick wrapper')
                token = token[1:-1]
            names.append(worker_name(token))
        if found is not None and names != found:
            raise ValueError('conflicting Skills: lines')
        found = names
    return found


def labels_of(card):
    labels = card.get('labels', [])
    if not isinstance(labels, list):
        raise ValueError('labels must be an array')
    values = [item.get('name') if isinstance(item, dict) else item for item in labels]
    if not all(isinstance(item, str) for item in values):
        raise ValueError('labels must contain names')
    return [item.lower() for item in values]


def remaining(card, lane=None):
    status = card.get('status')
    if status not in ['Ready', 'Building', 'QA', 'Review']:
        raise ValueError('card status must be Ready/Building/QA/Review')
    first = 'review' if status == 'Review' else 'qa' if status == 'QA' else 'qa' if 'qa' in labels_of(card) else 'build'
    route = card.get('lane')
    if route is not None and route != first:
        raise ValueError('card lane conflicts with status/qa routing')
    if lane:
        # A launcher can test a later lane while retaining its original card status.
        if LANES.index(lane) < LANES.index(first):
            raise ValueError('lane precedes the selected card entry')
        return [lane]
    return LANES[LANES.index(first):]


def canonical(name):
    if ':' not in name:
        for namespace, names in REGISTRY['aliases'].items():
            if name in names:
                return namespace + ':' + name
    return name


def requirements(card, lane=None, require=()):
    explicit = override(card['body'])
    selected = remaining(card, lane)
    for current in selected:
        source = 'boundary: skills/super-' + current + '/SKILL.md'
        rows = [('super-board', 'required', source), ('super-' + current, 'required', source)]
        if current == 'build':
            if explicit is not None:
                row, origin = explicit, 'override: Skills: + ' + POLICY
            else:
                labels = labels_of(card)
                row = next((names for tags, names in REGISTRY['build_rows'] if set(tags).intersection(labels)), None)
                if row is None:
                    # Untyped Ready cards will be classified bug/feature after this gate.
                    row = list(dict.fromkeys(sum((names for tags, names in REGISTRY['build_rows'][:2]), []))) if card['status'] == 'Ready' else REGISTRY['default']
                origin = 'label: ' + POLICY
            rows += [(name, 'required', origin) for name in row]
        elif explicit is not None and 'build' not in selected:
            rows += [(name, 'required', 'override: Skills: + ' + POLICY) for name in explicit]
        rows += [(name, 'required', source) for name in REGISTRY['boundaries'][current]]
        rows += [(name, 'conditional', source) for name in REGISTRY['conditional'][current]]
        rows += [(name, 'optional', source) for name in REGISTRY['optional'][current]]
        rows += [(worker_name(name), 'required', 'activation: --require + ' + source) for name in require]
        grouped = {}
        for name, requirement, origin in rows:
            name = canonical(name)
            if current == 'review' and name == 'mattpocock-skills:improve-codebase-architecture':
                raise ValueError('prohibited Review worker skill: ' + name)
            if name not in grouped:
                grouped[name] = [requirement, origin]
            else:
                old = grouped[name]
                if requirement == 'required':
                    old[0] = requirement
                if origin not in old[1]:
                    old[1] += '; ' + origin
        for name, (requirement, origin) in grouped.items():
            yield current, name, requirement, origin


def readable(path):
    try:
        resolved = path.resolve(strict=True)
        mode = resolved.stat()
        if not stat.S_ISREG(mode.st_mode) or not mode.st_mode & 0o444 or not os.access(resolved, os.R_OK):
            return None
        if not resolved.read_text(encoding='utf-8').strip():
            return None
        return str(resolved)
    except (OSError, UnicodeError, RuntimeError):
        return None


def codex_disabled(config_path, root, home):
    """Read only native skill activation records, without a Python 3.11 TOML dependency.

    Accept the documented [[skills.config]] path/enabled form, including literal
    strings and comments. Unsupported skill config fails closed for an explicit
    authoritative catalog; unrelated model/provider settings are never returned.
    """
    if not config_path.exists():
        return set(), False
    records, current, section = [], None, ''
    def uncomment(line):
        quote, escaped = None, False
        for index, char in enumerate(line):
            if quote == '"' and escaped:
                escaped = False
                continue
            if quote == '"' and char == '\\':
                escaped = True
            elif quote and char == quote:
                quote = None
            elif not quote and char in ('"', "'"):
                quote = char
            elif not quote and char == '#':
                return line[:index].strip()
        return line.strip()
    for raw in config_path.read_text().splitlines():
        line = uncomment(raw)
        if not line:
            continue
        if line.startswith('['):
            current = None
            if line == '[[skills.config]]':
                current = {}; records.append(current); section = 'skills.config'
            else:
                section = line.strip('[]').strip().replace(chr(34), '').replace(chr(39), '')
                if 'skills' in section and 'config' in section:
                    raise ValueError('unsupported Codex skills configuration; supply an authoritative --catalog')
            continue
        if current is not None:
            match = re.fullmatch(r'(path|enabled)\s*=\s*(.+)', line)
            if not match or match[1] in current:
                raise ValueError('unsupported Codex skill record; supply an authoritative --catalog')
            key, value = match.groups()
            if key == 'enabled':
                if value not in ('true', 'false'):
                    raise ValueError('invalid Codex skill enabled value')
                current[key] = value == 'true'
            else:
                try:
                    if re.fullmatch(r"'[^']*'", value):
                        value = value[1:-1]
                    else:
                        value = json.loads(value)
                except ValueError:
                    raise ValueError('unsupported Codex skill path string; supply an authoritative --catalog')
                if not isinstance(value, str):
                    raise ValueError('Codex skill path must be a string')
                if value.startswith('~/'):
                    value = str(home / value[2:])
                if not Path(value).is_absolute():
                    raise ValueError('Codex skill path must be absolute')
                current[key] = str(Path(value).resolve())
        elif (section == 'skills' and re.match(r'''(?:config|["']config["'])\s*(?:=|\.)''', line)) or re.match(r'''(?:skills|["']skills["'])\s*\.\s*(?:config|["']config["'])\s*(?:=|\.)''', line) or (not section and re.match(r'''(?:skills|["']skills["'])\s*=''', line)):
            raise ValueError('unsupported Codex inline skills configuration; supply an authoritative --catalog')
    disabled = set()
    for record in records:
        if 'path' not in record:
            raise ValueError('Codex skill record needs path')
        if record.get('enabled', True) is False:
            disabled.add(record['path'])
    return disabled, bool(records)


class Inventory:
    def __init__(self, root, host, home=None, catalog=None):
        self.root, self.host = Path(root).resolve(), host
        self.home = Path(home).resolve() if home else Path.home()
        self.roots = []
        self.exact = {}
        self.project_exact = {}
        self.metadata_surfaces = []
        self.disabled = set()
        self.catalog_only = False
        if host == 'claude':
            self.roots = [self.root / '.claude/skills', self.home / '.claude/skills']
            self.claude_plugins()
        else:
            # Codex discovery stops at this independent repository's root.
            process = subprocess.run(['git', '-C', str(self.root), 'rev-parse', '--show-toplevel'],
                                     text=True, capture_output=True)
            boundary = Path(process.stdout.strip()).resolve() if process.returncode == 0 else self.root
            scoped = [self.root]
            if boundary in self.root.parents:
                for parent in self.root.parents:
                    scoped.append(parent)
                    if parent == boundary:
                        break
            self.roots = [parent / '.agents/skills' for parent in scoped]
            codex_home = (self.home / '.codex') if home else Path(os.environ.get('CODEX_HOME', self.home / '.codex'))
            self.roots += [self.home / '.agents/skills', codex_home / 'skills']
            try:
                self.disabled.update(codex_disabled(codex_home / 'config.toml', self.root, self.home)[0])
            except ValueError:
                if not catalog:
                    raise
                # Unknown native activation semantics need a complete active inventory.
                self.roots = []
                self.catalog_only = True
            # Project configuration is trust-sensitive and layered. A displayed
            # active catalog is the authority when any scoped project config
            # affects skill activation; do not invent trust/precedence rules.
            for parent in reversed(scoped):
                try:
                    _, activates = codex_disabled(parent / '.codex/config.toml', self.root, self.home)
                except ValueError:
                    activates = True
                if activates:
                    if not catalog:
                        raise ValueError('project Codex skill activation needs an authoritative --catalog for effective trusted settings')
                    self.roots = []
                    self.disabled.clear()
                    self.catalog_only = True
        if catalog:
            data = json.loads(Path(catalog).read_text())
            if not isinstance(data, dict) or data.get('host') != host or not isinstance(data.get('skills'), list):
                raise ValueError('unsupported active skill catalog: expected host and skills array')
            for entry in data['skills']:
                if (not isinstance(entry, dict) or entry.get('scope') not in ['project', 'user']
                        or type(entry.get('enabled')) is not bool or not isinstance(entry.get('path'), str)
                        or not Path(entry['path']).is_absolute()):
                    raise ValueError('invalid active skill catalog entry')
                name = valid_name(entry.get('name'))
                if entry['scope'] == 'project':
                    if not isinstance(entry.get('project_root'), str) or not Path(entry['project_root']).is_absolute():
                        raise ValueError('project catalog entry needs absolute project_root')
                    if Path(entry['project_root']).resolve() != self.root:
                        continue
                if entry['enabled']:
                    target = self.project_exact if entry['scope'] == 'project' else self.exact
                    target.setdefault(canonical(name), []).append(Path(entry['path']))
                    self.metadata_surfaces.append(entry['path'])
                else:
                    self.disabled.add(str(Path(entry['path']).resolve()))

    def claude_plugins(self):
        settings = {}
        for path in [self.home / '.claude/settings.json', self.root / '.claude/settings.json', self.root / '.claude/settings.local.json']:
            if path.exists():
                data = json.loads(path.read_text())
                if not isinstance(data, dict):
                    raise ValueError('unsupported Claude settings: expected an object')
                enabled = data.get('enabledPlugins', {})
                if not isinstance(enabled, dict) or not all(type(value) is bool for value in enabled.values()):
                    raise ValueError('unsupported Claude enabledPlugins settings: expected boolean values')
                settings.update(enabled)
        manifest = self.home / '.claude/plugins/installed_plugins.json'
        if not manifest.exists():
            return
        data = json.loads(manifest.read_text())
        if not isinstance(data, dict):
            raise ValueError('unsupported Claude installed plugin metadata: expected an object')
        plugins = data.get('plugins')
        if not isinstance(plugins, dict):
            raise ValueError('unsupported Claude installed plugin metadata; provide an authoritative --catalog')
        for key, installs in plugins.items():
            if settings.get(key) is not True:
                continue
            if not isinstance(installs, list):
                raise ValueError('unsupported Claude plugin install records')
            namespace = key.split('@', 1)[0]
            valid_name(namespace)
            if not all(isinstance(item, dict) for item in installs):
                raise ValueError('invalid Claude plugin install record')
            for item in sorted(installs, key=lambda item: ({'local': 0, 'project': 1, 'user': 2}.get(item.get('scope'), 3), str(item.get('installPath', '')))):
                scope = item.get('scope')
                if scope not in ['user', 'project', 'local']:
                    raise ValueError('unsupported Claude plugin scope')
                if scope != 'user' and Path(item.get('projectPath', '')).resolve() != self.root:
                    continue
                path = item.get('installPath')
                if not isinstance(path, str) or not Path(path).is_absolute():
                    raise ValueError('enabled Claude plugin has no authoritative installPath')
                directory = Path(path) / 'skills'
                self.metadata_surfaces.append(str(directory))
                if directory.is_dir():
                    for child in sorted(directory.iterdir()):
                        if NAME.fullmatch(child.name):
                            target = self.exact if scope == 'user' else self.project_exact
                            target.setdefault(namespace + ':' + child.name, []).append(child / 'SKILL.md')

    def resolve(self, name):
        namespace, separator, suffix = name.partition(':')
        known = separator and suffix in REGISTRY['aliases'].get(namespace, [])
        candidates = [directory / (suffix if known else name) / 'SKILL.md' for directory in self.roots] if not separator or known else []
        # Local roots and project plugin records win over enabled user installs.
        if candidates:
            candidates[1:1] = self.project_exact.get(name, [])
        else:
            candidates = list(self.project_exact.get(name, []))
        # Core direct reads are part of the Codex launcher contract, helpers are not.
        if self.host == 'codex' and name in CORE and not self.catalog_only:
            candidates.insert(0, self.root / '.claude/skills' / name / 'SKILL.md')
        candidates += self.exact.get(name, [])
        for path in candidates:
            resolved = readable(path)
            if resolved and resolved not in self.disabled:
                return resolved, str(path.absolute())
        return None, None


def report(root, host, cards=None, profile=None, lane=None, require=(), home=None, catalog=None):
    if not profile and cards == []:
        return dict(ready=True, host=host, entries=[], searched_surfaces=[], remediation='')
    inventory = Inventory(root, host, home, catalog)
    entries = []
    if profile:
        cards = [{'number': None, 'status': 'Ready', 'labels': ['feature'], 'body': ''}]
    for card in cards or []:
        if (not isinstance(card, dict) or (card.get('number') is not None and (type(card['number']) is not int or card['number'] < 1))
                or ('number' in card and card['number'] is None and not profile) or 'number' not in card or 'body' not in card):
            raise ValueError('each card needs number, status and literal body')
        chain = list(requirements(card, lane, require))
        if profile:
            chain += [('setup', name, 'required', 'boundary: setup eight-skill installation') for name in CORE]
            for _, names in REGISTRY['build_rows']:
                chain += [('build', name, 'required', 'label: ' + POLICY) for name in names]
        seen = set()
        for current, name, requirement, source in chain:
            if (current, name) in seen:
                continue
            seen.add((current, name))
            path, visible = inventory.resolve(name) if requirement != 'conditional' else (None, None)
            fallback = REGISTRY['fallbacks'].get(name) if not path and requirement != 'conditional' else None
            status = 'resolved' if path else 'fallback' if fallback else 'skipped' if requirement != 'required' else 'missing'
            entries.append(dict(card=card['number'], lane=current, name=name, requirement=requirement, source=source,
                                status=status, resolved_path=path, visible_path=visible, fallback=fallback))
    return dict(ready=not any(entry['status'] == 'missing' for entry in entries), host=host, entries=entries,
                searched_surfaces=list(dict.fromkeys([str(path) for path in inventory.roots] + inventory.metadata_surfaces)),
                remediation='Install the exact missing skills in a visible host surface or supply an enabled active catalog, then restart explicitly.')


def hydrate(cards, root):
    helper = Path(__file__).with_name('super-board-github-read.py')
    def read_issue(number, kind, fields):
        process = subprocess.run([sys.executable, str(helper), '--kind', kind, '--', 'issue', 'view', str(number),
                                  '--json', fields], cwd=root, text=True, capture_output=True)
        if process.returncode:
            print(process.stderr, file=sys.stderr, end='')
            raise SystemExit(process.returncode)
        return json.loads(process.stdout)
    for card in cards:
        if not isinstance(card, dict) or type(card.get('number')) is not int or card['number'] < 1:
            raise ValueError('card needs a positive number before issue hydration')
        if 'body' not in card:
            data = read_issue(card['number'], 'issue', 'number,title,body')
            if data.get('number') != card['number'] or not isinstance(data.get('body'), str):
                raise ValueError('guarded issue hydration returned the wrong issue/body')
            card['body'] = data['body']
        if 'labels' not in card:
            data = read_issue(card['number'], 'json', 'labels')
            if not isinstance(data, dict) or not isinstance(data.get('labels'), list):
                raise ValueError('guarded issue hydration returned no labels array')
            card['labels'] = data['labels']
            labels_of(card)
    return cards


class UsageParser(argparse.ArgumentParser):
    def error(self, message):
        print('skills-readiness: ' + message, file=sys.stderr)
        raise SystemExit(64)


def main(argv=None):
    parser = UsageParser(description=__doc__)
    parser.add_argument('--root', required=True)
    parser.add_argument('--host', required=True, choices=['claude', 'codex'])
    selection = parser.add_mutually_exclusive_group(required=True)
    selection.add_argument('--cards')
    selection.add_argument('--profile', choices=['setup'])
    parser.add_argument('--lane', choices=LANES)
    parser.add_argument('--require', action='append', default=[])
    parser.add_argument('--home', default=os.environ.get('SUPER_BOARD_SKILLS_HOME'))
    parser.add_argument('--catalog', default=os.environ.get('SUPER_BOARD_SKILLS_CATALOG'))
    parser.add_argument('--hydrate', action='store_true')
    args = parser.parse_args(argv)
    try:
        for name in args.require:
            worker_name(name)
        if args.profile and args.lane:
            raise ValueError('--profile setup checks the full union; --lane requires selected cards')
        cards = json.loads(sys.stdin.read() if args.cards == '-' else Path(args.cards).read_text()) if args.cards else None
        if cards is not None and not isinstance(cards, list):
            raise ValueError('cards must be an array')
        if args.hydrate and cards is not None:
            hydrate(cards, args.root)
        result = report(args.root, args.host, cards, args.profile, args.lane, args.require, args.home, args.catalog)
        print(json.dumps(result))
        for entry in result['entries']:
            if entry['status'] == 'missing':
                print('skills-readiness: missing ' + entry['name'] + ' for ' + args.host + '; ' + result['remediation'], file=sys.stderr)
        return 0 if result['ready'] else 10
    except (OSError, ValueError, TypeError, KeyError) as error:
        print('skills-readiness: ' + str(error), file=sys.stderr)
        return 64

if __name__ == '__main__':
    sys.exit(main())
