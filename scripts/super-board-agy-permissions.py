#!/usr/bin/env python3
"""Write the Antigravity permission rules a headless super-board lane needs.

Headless `agy -p` cannot ask: a shell command or a file access that no rule in
~/.gemini/antigravity-cli/settings.json -> permissions.allow covers is auto-denied (the run
still exits 0, with `denied_actions` in its JSON and a notice on stderr). Without rules a
lane "succeeds" having run nothing. Rules are `action(target)`: `command(git status)`,
`command(regex:...)`, `read_file(<path>)`, `write_file(<path>)`; deny beats ask beats allow.

What a lane needs, measured on agy 1.4.6 (2026-10-23, Windows 11, nine waves on one card):
a per-program allowlist does not hold. On Windows the rules match the whole command
exactly (`command(python)` does not allow `python --version`), and once written as regexes
the lane still improvised a `;`-chain, a multi-line `python -c`, a PowerShell here-string,
then a write to a `mktemp` file outside the workspace, each denied in turn. What worked:

  allow  command(*)  read_file(*)  write_file(*)
  deny   the dangerous forms (force pushes, repo deletion, `gh auth`, `rm -rf /`, ...)
         and the secret paths (.env, ~/.ssh, ~/.gemini, ~/.gitconfig*)

with the guard hooks in .agents/hooks.json as the real safety net: they run BEFORE the
permission check, fail closed, and already refuse secret reads, deletions outside the
project, worktrees outside .claude/worktrees/ and key literals. `--dangerously-skip-permissions`
is not the same thing: it also skips the ask/deny evaluation the deny rules need.

That is the default profile. `--from-allowlist` instead converts the board's Claude allowlist
(<repo>/.claude/settings.json -> permissions.allow, written by onboard) rule by rule into
`command(regex:(?s)<prefix>(\\s.*)?)`, which matches on every OS: tighter, and a lane will
sooner or later hit a form it does not cover. `--add RULE` appends any rule as written
(platform tools: `command(./gradlew)`). Default is a dry run; `--apply` merges into the
settings file (other keys untouched, no duplicates) after copying it to <file>.bak-<ts>.
An invalid settings file is left untouched (exit 2).

Usage:
  super-board-agy-permissions.py [--repo .] [--settings ~/.gemini/antigravity-cli/settings.json]
                                 [--from-allowlist] [--add RULE ...] [--apply] [--verbose]
Exit: 0 ok · 2 settings file is not valid JSON · 64 usage.
"""
import argparse
import json
import re
import shutil
import sys
import time
from pathlib import Path

BASH_RULE = re.compile(r"^Bash\((?P<body>.+)\)$")
LANE_ALLOW = ["command(*)", "read_file(*)", "write_file(*)"]
# Regex rules are matched against the whole command; (?s) lets them span a multi-line command.
DENY_COMMANDS = [
    r"command(regex:(?s).*\brm\s+-[a-zA-Z]*r[a-zA-Z]*\s+/\s*$.*)",
    r"command(regex:(?s).*\brm\s+-[a-zA-Z]*r[a-zA-Z]*\s+/(\s|$).*)",
    r"command(regex:(?s).*\bgit\s+push\b.*(\s--force\b|\s-f\b).*)",
    r"command(regex:(?s).*\bgit\s+reset\s+--hard\s+origin.*)",
    r"command(regex:(?s).*\bgh\s+repo\s+delete\b.*)",
    r"command(regex:(?s).*\bgh\s+auth\b.*)",
    r"command(regex:(?s).*--dangerously-skip-permissions.*)",
]
SECRET_PATHS = [".env", ".ssh", ".gemini", ".gitconfig", ".gitconfig-personal", ".aws", ".config/gh"]


def deny_paths(home):
    rules = ["read_file(.env)", "write_file(.env)"]
    for name in SECRET_PATHS:
        for action in ("read_file", "write_file"):
            rule = f"{action}({home / name})"
            if rule not in rules:
                rules.append(rule)
    return rules


def convert(rule):
    """`Bash(gh pr view:*)` -> `command(regex:(?s)gh pr view(\\s.*)?)`; None for rules with no twin."""
    match = BASH_RULE.match(rule.strip())
    if not match:
        return None
    body = re.sub(r"(:\*|\s\*|\*)$", "", match.group("body").strip()).strip()
    return f"command(regex:(?s){re.escape(body)}(\\s.*)?)" if body else None


def main():
    parser = argparse.ArgumentParser(description="Write the Antigravity permission rules a headless lane needs.")
    parser.add_argument("--repo", default=".")
    parser.add_argument("--settings", default=str(Path.home() / ".gemini/antigravity-cli/settings.json"))
    parser.add_argument("--from-allowlist", action="store_true",
                        help="convert the Claude allowlist to regex command rules instead of command(*)")
    parser.add_argument("--add", action="append", default=[], help="extra rule as written, e.g. command(./gradlew)")
    parser.add_argument("--apply", action="store_true")
    parser.add_argument("--verbose", action="store_true")
    args = parser.parse_args()

    wanted_allow, skipped = [], []
    if args.from_allowlist:
        claude = Path(args.repo) / ".claude/settings.json"
        try:
            allow = (json.loads(claude.read_text()).get("permissions") or {}).get("allow") or [] if claude.exists() else []
        except ValueError:
            print(f"✋ {claude} is not valid JSON; fix it first", file=sys.stderr)
            return 2
        for rule in allow:
            converted = convert(rule) if isinstance(rule, str) else None
            (wanted_allow if converted else skipped).append(converted or rule)
        wanted_allow += ["read_file(*)", "write_file(*)"]
    else:
        wanted_allow += LANE_ALLOW
    for rule in args.add:
        if not re.match(r"^[a-z_]+\(.+\)$", rule):
            print(f"--add takes an Antigravity rule like command(./gradlew), got {rule!r}", file=sys.stderr)
            return 64
        wanted_allow.append(rule)
    wanted_deny = DENY_COMMANDS + deny_paths(Path.home())

    target = Path(args.settings).expanduser()
    try:
        current = json.loads(target.read_text()) if target.exists() else {}
        if not isinstance(current, dict):
            raise ValueError
    except ValueError:
        print(f"✋ {target} is not valid JSON; left untouched", file=sys.stderr)
        return 2
    permissions = current.get("permissions") if isinstance(current.get("permissions"), dict) else {}
    existing_allow = list(permissions.get("allow") or [])
    existing_deny = list(permissions.get("deny") or [])
    new_allow = [r for i, r in enumerate(wanted_allow) if r not in existing_allow and r not in wanted_allow[:i]]
    new_deny = [r for i, r in enumerate(wanted_deny) if r not in existing_deny and r not in wanted_deny[:i]]

    for rule in new_allow:
        print(f"+ allow {rule}")
    for rule in new_deny:
        print(f"+ deny  {rule}")
    if args.verbose:
        for rule in skipped:
            print(f"  skipped (no Antigravity twin): {rule}")
    if not new_allow and not new_deny:
        print(f"✓ {target}: every board rule already present")
        return 0
    if not args.apply:
        print(f"dry run: {len(new_allow)} allow and {len(new_deny)} deny rule(s) for {target} — re-run with --apply to write them")
        return 0
    target.parent.mkdir(parents=True, exist_ok=True)
    if target.exists():
        shutil.copy2(target, target.with_name(target.name + time.strftime(".bak-%Y%m%d%H%M%S")))
    current["permissions"] = dict(permissions, allow=existing_allow + new_allow, deny=existing_deny + new_deny)
    temporary = target.with_name(target.name + ".tmp")
    temporary.write_text(json.dumps(current, indent=2) + "\n")
    temporary.replace(target)
    print(f"✓ {len(new_allow)} allow and {len(new_deny)} deny rule(s) added to {target}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
