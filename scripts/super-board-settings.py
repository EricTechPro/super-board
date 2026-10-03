#!/usr/bin/env python3
"""super-board-settings.py — merge into .claude/settings.json without losing anything.

    super-board-settings.py hooks <settings.json> <snippet.json> [...] [--dry-run]
    super-board-settings.py allow <settings.json> <rule> [<rule> ...]  [--dry-run]

`hooks` adds each hook command from the snippets once per event + matcher
(install.sh and onboard's protect-main step). `allow` adds permission rules to
`permissions.allow` once each (onboard's Permissions step, after the user
approved the printed diff). Both keep every existing key, back the file up
(`settings.json.bak-<ts>`) before writing, write atomically, and leave an
invalid settings.json untouched. `--dry-run` prints what would be added
(`+ <line>`) and writes nothing.

Exit: 0 ok (including "already present"), 2 settings.json invalid, 64 usage.
"""
from __future__ import annotations

import json
import os
import shutil
import sys
import time


def load(path: str):
    if not os.path.exists(path):
        return {}
    try:
        data = json.load(open(path))
    except ValueError as e:
        print(f"    ✗ {path} is not valid JSON ({e}); left untouched — merge by hand", file=sys.stderr)
        sys.exit(2)
    if not isinstance(data, dict):
        print(f"    ✗ {path} is not a JSON object; left untouched", file=sys.stderr)
        sys.exit(2)
    return data


def save(path: str, data: dict) -> None:
    if os.path.exists(path):
        backup = f"{path}.bak-{time.strftime('%Y%m%d%H%M%S')}"
        shutil.copy2(path, backup)
        print(f"    ✓ backup: {backup}")
    os.makedirs(os.path.dirname(path) or ".", exist_ok=True)
    tmp = path + ".tmp"
    with open(tmp, "w") as f:
        json.dump(data, f, indent=2)
        f.write("\n")
        f.flush()
        os.fsync(f.fileno())
    os.replace(tmp, path)


def merge_hooks(settings: dict, snippets: list[dict]) -> list[str]:
    hooks = settings.setdefault("hooks", {})
    added = []
    for event, entries in [kv for s in snippets for kv in s["hooks"].items()]:
        current = hooks.setdefault(event, [])
        for entry in entries:
            matcher = entry.get("matcher")
            target = next((e for e in current if e.get("matcher") == matcher), None)
            if target is None:
                target = {"matcher": matcher} if matcher is not None else {}
                target["hooks"] = []
                current.append(target)
            have = {h.get("command") for e in current if e.get("matcher") == matcher
                    for h in e.get("hooks", [])}
            for h in entry["hooks"]:
                if h["command"] not in have:
                    target.setdefault("hooks", []).append(h)
                    have.add(h["command"])
                    added.append(f"{event} {matcher or '*'}: {h['command']}")
    return added


def merge_allow(settings: dict, rules: list[str]) -> list[str]:
    allow = settings.setdefault("permissions", {}).setdefault("allow", [])
    added = []
    for r in rules:
        if r not in allow:
            allow.append(r)
            added.append(r)
    return added


def main(argv: list[str]) -> int:
    dry = "--dry-run" in argv
    args = [a for a in argv if a != "--dry-run"]
    if len(args) < 3 or args[0] not in ("hooks", "allow"):
        print(__doc__, file=sys.stderr)
        return 64
    verb, path, rest = args[0], args[1], args[2:]
    settings = load(path)
    if verb == "hooks":
        added = merge_hooks(settings, [json.load(open(p)) for p in rest])
        noun = "hook command(s)"
    else:
        added = merge_allow(settings, rest)
        noun = "permission rule(s)"
    if not added:
        print("    ✓ already present — nothing to change")
        return 0
    if dry:
        for a in added:
            print(f"+ {a}")
        return 0
    save(path, settings)
    print(f"    ✓ {len(added)} {noun} added")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
