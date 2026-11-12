#!/usr/bin/env python3
"""PreToolUse(Bash) guard: never edit a 🙋 approval request; post a new comment.

super-board-approval.py refuses a request comment whose updated_at differs from its
created_at ("approval request was edited; post a fresh request"): an edit could change
what the human's `done` approved. A lane that edits its own request to add a link or
fix a line loses the human's `done` and costs a review round.

Denied: an edit of an existing comment (`gh issue|pr comment --edit-last`, a PATCH to
`issues/comments/<id>`, a GraphQL `updateIssueComment`) whose new body carries an
`approval-request:` line or a `Reason tag: … 🙋` line. The body is read from the command
itself (inline `--body`, a heredoc) and from any file it names (`--body-file`, `-F`,
`--input`, `body=@file`, `$(cat file)`, `< file`). Posting a new comment is never blocked.

SB_ALLOW_APPROVAL_EDIT=1 in Claude Code's environment turns it off for a session.
Its own errors never block a tool call: anything unexpected exits 0 with no output.
"""
import json
import os
import re
import shlex
import sys

STOP = r"[^;&|\n]*"  # stay inside one simple command
PATCH = r"(?:-X\s*PATCH|--method[ =]PATCH)"
EDIT = re.compile(
    rf"\bgh\s+(?:issue|pr)\s+comment\b{STOP}--edit-last"
    rf"|\bgh\s+api\b{STOP}{PATCH}{STOP}issues/comments/"
    rf"|\bgh\s+api\b{STOP}issues/comments/\d+{STOP}{PATCH}"
    r"|\bupdateIssueComment\b", re.I)
REQUEST = re.compile(r"approval-request:|Reason tag:[^\n]*🙋")
FILE_FLAGS = {"--body-file", "-F", "--field", "-f", "--raw-field", "--input"}

REASON = (
    "Blocked: this edits a 🙋 approval request.\n"
    "The merge gate refuses an edited request (\"approval request was edited\"), so the "
    "human's `done` is lost. Never edit a request after posting: post a NEW comment instead. "
    "A follow-up note carries no `Reason tag: 🙋` and no `approval-request:` line; a changed "
    "request is a fresh full block with the gate's `approval-request:` line copied verbatim "
    "(block-template.md → \"Approval request\"). If this edit really is intended, ask the user "
    "to run it, or start Claude Code with SB_ALLOW_APPROVAL_EDIT=1.")


def named_files(command):
    """Files whose text becomes the new body without appearing in the command."""
    files = re.findall(r"\$\(\s*cat\s+['\"]?([^)'\"\s]+)['\"]?\s*\)", command)
    files += re.findall(r"(?<![<\d])<\s*['\"]?([^\s<'\";&|]+)", command)
    try:
        tokens = shlex.split(command, posix=True)
    except ValueError:
        return files
    for i, tok in enumerate(tokens):
        value = None
        if tok in FILE_FLAGS and i + 1 < len(tokens):
            value = tokens[i + 1]
        elif "=" in tok and tok.split("=", 1)[0] in FILE_FLAGS:
            value = tok.split("=", 1)[1]
        if value is None:
            continue
        if "=@" in value:
            value = value.split("=@", 1)[1]
        elif value.startswith("@"):
            value = value[1:]
        elif "=" in value:
            continue  # an inline key=value: the command text already holds it
        if value and value != "-":
            files.append(value)
    return files


def check(command, cwd):
    """None when allowed, else the deny reason."""
    if not EDIT.search(command):
        return None
    if REQUEST.search(command):
        return REASON
    for name in named_files(command):
        path = os.path.join(cwd, os.path.expanduser(name))
        try:
            with open(path, encoding="utf-8") as stream:
                if REQUEST.search(stream.read()):
                    return REASON
        except (OSError, ValueError):
            continue
    return None


def main():
    try:
        if os.environ.get("SB_ALLOW_APPROVAL_EDIT") == "1":
            return
        payload = json.loads(sys.stdin.read() or "{}")
        command = (payload.get("tool_input") or {}).get("command")
        if not isinstance(command, str):
            return
        reason = check(command, payload.get("cwd") or os.getcwd())
        if reason:
            print(json.dumps({"hookSpecificOutput": {"hookEventName": "PreToolUse",
                                                     "permissionDecision": "deny",
                                                     "permissionDecisionReason": reason}}))
    except Exception:
        pass  # a broken guard must never block unrelated work


if __name__ == "__main__":
    main()
