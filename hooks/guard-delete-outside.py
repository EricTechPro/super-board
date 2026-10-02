#!/usr/bin/env python3
"""PreToolUse(Bash) guard: never delete files outside the project.

Denies `rm`, `rmdir`, `unlink`, `find ... -delete` / `find ... -exec rm`, and `git clean`
when a target resolves outside $CLAUDE_PROJECT_DIR, and always when it is `/` or the home
directory itself. Paths are resolved against the hook's `cwd`, honouring `cd X &&`; `~`,
`$HOME` and other set variables are expanded the way the shell would. A word whose value
cannot be known before it runs (a `$(...)`, or a variable assigned earlier in the same
command) is allowed: the guard catches the literal mistakes, not every possible one.

Temp roots stay deletable inside (not the roots themselves): /tmp, /private/tmp,
/var/folders and $TMPDIR. `git clean` is denied only when it would run in a directory
outside the project.

Its own errors never block a tool call: anything unexpected exits 0 with no output.
"""
import json
import os
import re
import sys

RM_CMDS = {"rm", "rmdir", "unlink", "trash"}
TEMP_ROOTS = ["/tmp", "/private/tmp", "/var/folders", "/private/var/folders"]


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
                if c == "$" and quote == "'":
                    cur += "\0"  # single-quoted $ is literal; mark it so expand() leaves it
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


def expand(word, env, local):
    """Expand ~ and $VAR like the shell. None when the value cannot be known before it runs."""
    if "$(" in word or "`" in word:
        return None
    s = re.sub(r"^~(?=/|$)", lambda m: env.get("HOME", "~"), word)
    unknowable = []

    def var(m):
        name = m.group(1) or m.group(2)
        if name in local:
            unknowable.append(name)
        return env.get(name, "")

    s = re.sub(r"\$\{([A-Za-z_][A-Za-z0-9_]*)\}|\$([A-Za-z_][A-Za-z0-9_]*)", var, s)
    if unknowable:
        return None
    return s.replace("\0", "$")


def under(path, root):
    return path == root or path.startswith(root.rstrip(os.sep) + os.sep)


def verdict(path, project, env):
    """None when the deletion target is fine, else why it is not."""
    home = os.path.normpath(env.get("HOME", "")) if env.get("HOME") else None
    forms = {path, os.path.join(os.path.realpath(os.path.dirname(path)), os.path.basename(path))}
    if any(p == os.sep for p in forms) or (home and any(p == home for p in forms)):
        return "is the filesystem root or your home directory"
    roots = {project, os.path.realpath(project)}
    if any(under(p, r) for p in forms for r in roots):
        return None
    temps = TEMP_ROOTS + ([os.path.normpath(env["TMPDIR"])] if env.get("TMPDIR") else [])
    if any(under(p, t) and p.rstrip(os.sep) != t.rstrip(os.sep) for p in forms for t in temps):
        return None
    return "is outside the project (%s)" % project


def targets(command, cwd, env):
    """[(command_name, raw_word, resolved_or_None)] for every deletion target."""
    found, d, local = [], cwd, set()
    for tokens in segments(command):
        while tokens and re.match(r"^[A-Za-z_][A-Za-z0-9_]*=", tokens[0]):
            local.add(tokens[0].split("=", 1)[0])
            tokens = tokens[1:]
        while tokens and tokens[0] in ("sudo", "command", "nice", "time", "xargs"):
            tokens = tokens[1:]
        if tokens and tokens[0] in ("export", "local", "read", "for"):
            local.update(re.sub(r"=.*", "", t) for t in tokens[1:] if re.match(r"^[A-Za-z_]", t))
            continue
        if not tokens:
            continue
        cmd, args = os.path.basename(tokens[0]), tokens[1:]
        if cmd == "cd":
            target = expand(args[0], env, local) if args else env.get("HOME")
            d = os.path.normpath(os.path.join(d, target)) if target else d
            continue

        def resolve(word, base=None):
            ex = expand(word, env, local)
            if ex is None or ex == "":
                return None
            return os.path.normpath(os.path.join(base or d, ex))

        if cmd in RM_CMDS:
            words, end = [], False
            for a in args:
                if not end and a == "--":
                    end = True
                elif end or not a.startswith("-") or a == "-":
                    words.append(a)
            for w in words:
                found.append((cmd, w, resolve(w)))
        elif cmd == "find":
            if "-delete" in args or any(a == "-exec" and i + 1 < len(args) and os.path.basename(args[i + 1]) in RM_CMDS
                                        for i, a in enumerate(args)):
                for w in args:
                    if w.startswith("-") or w in ("!", "(", ")"):
                        break
                    found.append(("find", w, resolve(w)))
        elif cmd == "git":
            git_dir, i = d, 0
            while i < len(args) and args[i].startswith("-"):
                if args[i] == "-C" and i + 1 < len(args):
                    git_dir = resolve(args[i + 1]) or git_dir
                    i += 2
                elif args[i] in ("-c", "--git-dir", "--work-tree"):
                    i += 2
                else:
                    i += 1
            if i < len(args) and args[i] == "clean":
                found.append(("git clean", git_dir, git_dir))
    return found


def check(command, cwd, project, env):
    """None when allowed, else the deny reason."""
    if not re.search(r"\b(rm|rmdir|unlink|trash|find|clean)\b", command):
        return None
    for cmd, raw, resolved in targets(command, cwd, env):
        if resolved is None:
            continue
        why = verdict(resolved, project, env)
        if why:
            return (
                'Blocked: %s target "%s" resolves to %s, which %s.\n'
                "Deleting outside the project is never part of a task here. Delete inside the repo "
                "(or a temp dir under /tmp or $TMPDIR), or ask the user to run it themselves."
                % (cmd, raw, resolved, why)
            )
    return None


def main():
    try:
        payload = json.loads(sys.stdin.read() or "{}")
        command = (payload.get("tool_input") or {}).get("command")
        if not isinstance(command, str):
            return
        cwd = payload.get("cwd") or os.getcwd()
        project = os.path.normpath(os.environ.get("CLAUDE_PROJECT_DIR") or cwd)
        reason = check(command, cwd, project, dict(os.environ))
        if reason:
            print(json.dumps({"hookSpecificOutput": {"hookEventName": "PreToolUse",
                                                     "permissionDecision": "deny",
                                                     "permissionDecisionReason": reason}}))
    except Exception:
        pass  # a broken guard must never block unrelated work


if __name__ == "__main__":
    main()
