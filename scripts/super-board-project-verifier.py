#!/usr/bin/env python3
"""Read-only project verifier map inspection and affected-feature selection.

Exit 0: structurally valid (no scenarios executed); 9: missing/stale setup;
64: malformed input. Uses project files only, without git, shell or host access.
"""
import argparse
import fnmatch
from functools import lru_cache
import glob
import hashlib
import json
import ntpath
from pathlib import Path
import sys


class InputError(Exception):
    def __init__(self, message, code=64):
        super().__init__(message)
        self.code = code


def relative(value, label, pattern=False):
    if not isinstance(value, str) or not value.strip():
        raise InputError(f'{label}: expected a nonempty repo-relative path')
    if ('\x00' in value or '\\' in value or ntpath.splitdrive(value)[0]
            or value.startswith('/') or any(part in ('', '.', '..') for part in value.split('/'))):
        raise InputError(f'{label}: absolute, traversal or noncanonical path')
    if not pattern and glob.has_magic(value):
        raise InputError(f'{label}: patterns are allowed only in owners')
    return value


def contained(root, path, label):
    try:
        resolved = path.resolve()
        resolved.relative_to(root)
    except (ValueError, OSError, RuntimeError):
        raise InputError(f'{label}: path escapes the project or has a broken symlink', 9)
    return resolved


def read_input(root, name, label):
    relative(name, label)
    path = contained(root, root / name, label)
    try:
        if not path.is_file() or not path.stat().st_mode & 0o444:
            raise OSError('not a readable file')
        data = path.read_bytes()
        if not data.strip():
            raise OSError('empty file')
    except OSError:
        raise InputError(f'{label}: missing, empty or unreadable file: {name}', 9)
    return data, dict(path=path.relative_to(root).as_posix(), sha256=hashlib.sha256(data).hexdigest())


def text(value, label):
    if not isinstance(value, str) or not value.strip():
        raise InputError(f'{label}: expected nonempty text')


def behavior(value, label):
    if isinstance(value, list):
        if not value:
            raise InputError(f'{label}: document behavior or explicit absence')
        for item in value:
            text(item, label)
    else:
        text(value, label)


def owner_matches(root, pattern, label):
    """Expand only within the project; validate intermediate matches before descent."""
    components, visited = pattern.split('/'), set()

    def walk(path, index):
        resolved = contained(root, path, label)
        if index == len(components):
            if path.is_file():
                yield path.relative_to(root).as_posix()
            return
        key = (resolved, index)
        if key in visited or not path.is_dir():
            return
        visited.add(key)
        component = components[index]
        if component == '**':
            yield from walk(path, index + 1)
        for child in sorted(path.iterdir()):
            if component == '**':
                contained(root, child, label)
                if child.is_dir():
                    yield from walk(child, index)
                elif index + 1 == len(components) and child.is_file():
                    yield child.relative_to(root).as_posix()
            elif fnmatch.fnmatchcase(child.name, component):
                # A matching directory symlink is checked even if the remaining
                # pattern would find no files, so another owner cannot hide it.
                yield from walk(child, index + 1)

    yield from walk(root, 0)


def load_map(root, name):
    raw, map_input = read_input(root, name, 'map')
    try:
        data = json.loads(raw)
    except (ValueError, UnicodeError):
        raise InputError('map: expected valid UTF-8 JSON')
    if not isinstance(data, dict) or type(data.get('version')) is not int or data['version'] != 1:
        raise InputError('map: expected object with version 1')
    text(data.get('app'), 'app')
    _, skill_input = read_input(root, data.get('skill'), 'skill')
    features = data.get('features')
    if not isinstance(features, list) or not features:
        raise InputError('features: expected a nonempty array')
    ids, scenarios, owners = [], [], {}
    for feature in features:
        if not isinstance(feature, dict):
            raise InputError('feature: expected object')
        name = feature.get('id')
        text(name, 'feature id')
        if name in ids:
            raise InputError(f'duplicate feature id: {name}')
        ids.append(name)
        for key in ['description', 'route', 'witness']:
            text(feature.get(key), f'{name}.{key}')
        for key in ['expected', 'side_effects']:
            behavior(feature.get(key), f'{name}.{key}')
        _, scenario = read_input(root, feature.get('scenario'), f'{name}.scenario')
        if scenario not in scenarios:
            scenarios.append(scenario)
        patterns = feature.get('owners')
        if not isinstance(patterns, list) or not patterns:
            raise InputError(f'{name}.owners: expected nonempty path/glob array')
        matches = set()
        for pattern in patterns:
            relative(pattern, f'{name}.owners', pattern=True)
            matches.update(owner_matches(root, pattern, f'{name}.owners'))
        if not matches:
            raise InputError(f'{name}.owners: no existing file match', 9)
        owners[name] = (patterns, matches)
    return dict(valid=True, app=data['app'], features=ids,
                inputs=dict(map=map_input, skill=skill_input, scenarios=scenarios)), owners


def matches_owner(path, pattern):
    """Root-anchored glob matching, including deleted paths and ** zero directories."""
    parts, patterns = path.split('/'), pattern.split('/')

    @lru_cache(None)
    def match(i, j):
        if j == len(patterns):
            return i == len(parts)
        if patterns[j] == '**':
            return match(i, j + 1) or (i < len(parts) and match(i + 1, j))
        return i < len(parts) and fnmatch.fnmatchcase(parts[i], patterns[j]) and match(i + 1, j + 1)

    return match(0, 0)


class Parser(argparse.ArgumentParser):
    def error(self, message):
        raise InputError(message)


def main():
    parser = Parser(description=__doc__)
    parser.add_argument('command', choices=['inspect', 'select'])
    parser.add_argument('--root', required=True)
    parser.add_argument('--map', required=True)
    parser.add_argument('--changed', help='JSON changed-path array file, or - for stdin')
    parser.add_argument('--feature', action='append', default=[])
    try:
        args = parser.parse_args()
        try:
            root = Path(args.root).resolve()
        except (OSError, RuntimeError):
            raise InputError('root: project path is inaccessible or has a symlink loop', 9)
        if not root.is_dir():
            raise InputError('root: project directory is missing', 9)
        result, owners = load_map(root, args.map)
        if args.command == 'inspect' and (args.changed is not None or args.feature):
            raise InputError('inspect does not accept --changed or --feature')
        if args.command == 'select':
            if args.changed is None:
                raise InputError('select requires --changed (use [] for explicit-only selection)')
            try:
                raw = sys.stdin.read() if args.changed == '-' else read_input(root, args.changed, 'changed')[0]
                changed = json.loads(raw)
            except (ValueError, UnicodeError):
                raise InputError('changed: expected a JSON path array')
            if not isinstance(changed, list):
                raise InputError('changed: expected a JSON path array')
            for path in changed:
                relative(path, 'changed path')
                contained(root, root / path, 'changed path')
            unknown = set(args.feature) - set(result['features'])
            if unknown:
                raise InputError('unknown feature id: ' + ', '.join(sorted(unknown)))
            selected, covered = set(args.feature), set()
            for feature, (patterns, matches) in owners.items():
                hits = {path for path in changed if path in matches or
                        any(matches_owner(path, pattern) for pattern in patterns)}
                if hits:
                    selected.add(feature)
                    covered.update(hits)
            result['selected'] = [name for name in result['features'] if name in selected]
            result['uncovered_paths'] = list(dict.fromkeys(path for path in changed if path not in covered))
        print(json.dumps(result, indent=2))
        return 0
    except InputError as error:
        print(json.dumps(dict(valid=False, error=str(error))))
        return error.code
    except OSError:
        print(json.dumps(dict(valid=False, error='unreadable project input')))
        return 9


if __name__ == '__main__':
    sys.exit(main())
