#!/usr/bin/env python3
"""PreToolUse(Bash) guard: a git worktree may only live under <repo>/.claude/worktrees/.

A worktree created next to the repo (`git worktree add ../proj-feature`) sits outside
every sweep -- cleanup-wt, Claude Code's own -- long after its PR merges. Claude
Code's docs show that very pattern, so it keeps coming back.

Reads the Bash command, finds every `git worktree add` / `git worktree move`,
resolves its target (honouring `cd X &&` and `git -C X`) and denies the call when the
target is outside `.claude/worktrees/` of the repo git will run in. Its own errors
never block a tool call: anything unexpected exits 0 with no output.

Adapted from BookKeepingApp's .claude/hooks/guard-worktree-path.js (Eric Tech).
"""
import json
import os
import re
import subprocess
import sys

ALLOWED_DIR = os.path.join(".claude", "worktrees")
ADD_VALUE_OPTS = {"-b", "-B", "--reason"}
GIT_VALUE_OPTS = {"-c", "--git-dir", "--work-tree", "--namespace", "--exec-path", "--config-env"}


def segments(command):
    """Split a shell command into simple-command token lists. Quotes are honoured; nothing runs."""
    out, tokens, cur, has, quote = [], [], "", False, None
    i = 0

    def push_token():
        nonlocal cur, has
        if has:
            tokens.append(cur)
        cur, has = "", False

    while i < len(command):
        c = command[i]
        if quote:
            if c == quote:
                quote = None
            elif c == "\\" and quote == '"' and i + 1 < len(command):
                i += 1
                cur += command[i]
            else:
                cur += c
        elif c in "'\"":
            quote, has = c, True
        elif c == "\\" and i + 1 < len(command):
            i += 1
            cur += command[i]
            has = True
        elif c in " \t":
            push_token()
        elif c in ";\n|&()":
            push_token()
            if tokens:
                out.append(tokens)
            tokens = []
        else:
            cur += c
            has = True
        i += 1
    push_token()
    if tokens:
        out.append(tokens)
    return out


def expand(word, env):
    """Expand ~, $VAR, ${VAR}. None when a variable is unknown or a substitution is present."""
    s = re.sub(r"^~(?=/|$)", lambda m: env.get("HOME", "~"), word)
    unknown = []

    def var(m):
        name = m.group(1) or m.group(2)
        if name not in env:
            unknown.append(name)
        return env.get(name, "")

    s = re.sub(r"\$\{([A-Za-z_][A-Za-z0-9_]*)\}|\$([A-Za-z_][A-Za-z0-9_]*)", var, s)
    if unknown or "$(" in s or "`" in s:
        return None
    return s


def worktree_targets(command, cwd, env):
    """[(raw, git_dir, resolved_or_None)] for every worktree add/move target."""
    found, d = [], cwd
    for tokens in segments(command):
        while tokens and re.match(r"^[A-Za-z_][A-Za-z0-9_]*=", tokens[0]):
            tokens = tokens[1:]
        if not tokens:
            continue
        cmd, args = tokens[0], tokens[1:]
        if cmd == "cd":
            target = expand(args[0], env) if args else env.get("HOME")
            if target:
                d = os.path.normpath(os.path.join(d, target))
            continue
        if os.path.basename(cmd) != "git":
            continue
        git_dir, i = d, 0
        while i < len(args) and args[i].startswith("-"):
            if args[i] == "-C":
                target = expand(args[i + 1] if i + 1 < len(args) else "", env)
                if target:
                    git_dir = os.path.normpath(os.path.join(git_dir, target))
                i += 2
            elif args[i] in GIT_VALUE_OPTS:
                i += 2
            else:
                i += 1
        if i >= len(args) or args[i] != "worktree" or i + 1 >= len(args):
            continue
        sub = args[i + 1]
        if sub not in ("add", "move"):
            continue
        positional, j = [], i + 2
        while j < len(args):
            a = args[j]
            if a == "--":
                positional += args[j + 1:]
                break
            if a in ADD_VALUE_OPTS:
                j += 1
            elif not a.startswith("-") and not re.match(r"^\d*[<>]", a):
                positional.append(a)
            j += 1
        idx = 0 if sub == "add" else 1
        if len(positional) <= idx:
            continue
        raw = positional[idx]
        ex = expand(raw, env)
        found.append((raw, git_dir, None if ex is None else os.path.normpath(os.path.join(git_dir, ex))))
    return found


def repo_root(toplevel):
    """The main checkout's root, from it or any worktree under .claude/worktrees/."""
    marker = os.sep + ALLOWED_DIR + os.sep
    at = toplevel.find(marker)
    return toplevel if at == -1 else toplevel[:at]


def check(command, cwd, root_of, env):
    """None when allowed, else the deny reason. root_of(dir) -> repo root or None."""
    if not re.search(r"\bworktree\b", command):
        return None
    for raw, git_dir, resolved in worktree_targets(command, cwd, env):
        repo = root_of(git_dir) or root_of(cwd)
        if not repo:
            continue  # not a repository: git itself will refuse
        allowed = os.path.join(repo, ALLOWED_DIR)
        if resolved and resolved.startswith(allowed + os.sep):
            continue
        where = ("resolves to " + resolved) if resolved else "cannot be resolved before it runs"
        return (
            'Blocked: worktree path "%s" %s, outside %s/.\n'
            "Worktrees live only under .claude/worktrees/ so cleanup-wt and Claude Code's sweep can see them.\n"
            'Prefer the Agent tool\'s isolation: "worktree" or `claude --worktree <name>`. If you need git directly:\n'
            "  git worktree add .claude/worktrees/<name> -b <branch> <base>\n"
            "(from the repo root, with a literal path)." % (raw, where, allowed)
        )
    return None


def toplevel_of(d):
    env = {k: v for k, v in os.environ.items() if not k.startswith("GIT_")}
    try:
        r = subprocess.run(["git", "-C", d, "rev-parse", "--show-toplevel"], capture_output=True,
                           text=True, env=env, timeout=10)
        return r.stdout.strip() if r.returncode == 0 else None
    except (OSError, subprocess.TimeoutExpired):
        return None


def main():
    try:
        payload = json.loads(sys.stdin.read() or "{}")
        command = (payload.get("tool_input") or {}).get("command")
        if not isinstance(command, str):
            return
        cwd = payload.get("cwd") or os.getcwd()

        def root_of(d):
            top = toplevel_of(d) or (os.environ.get("CLAUDE_PROJECT_DIR") if d == cwd else None)
            return repo_root(top) if top else None

        reason = check(command, cwd, root_of, dict(os.environ))
        if reason:
            print(json.dumps({"hookSpecificOutput": {"hookEventName": "PreToolUse",
                                                     "permissionDecision": "deny",
                                                     "permissionDecisionReason": reason}}))
    except Exception:
        pass  # a broken guard must never block unrelated work


if __name__ == "__main__":
    main()
