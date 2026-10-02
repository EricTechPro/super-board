#!/usr/bin/env python3
"""Guard against live credentials entering the codebase.

guard-secrets stops secrets getting OUT (reading dotenv files). This stops them
getting IN: a key pasted into source, a config file, or a script. Wired on two events:
  PreToolUse  (Edit|MultiEdit|Write|NotebookEdit|Bash) -> deny before the key hits disk
  PostToolUse (Edit|MultiEdit|Write|NotebookEdit)      -> catch what got through another
                                                          path and tell the agent to fix it

It never prints the matched value -- that would put the key in the transcript, the
thing both guards exist to prevent. Line numbers only. Its own errors never block.

Adapted from ai-builder-starter-kit's .agents/hooks/guard-key-literals.sh (Eric Tech).
"""
import json
import re
import sys

Q = "[\"']"
KEY_RE = re.compile("|".join([
    r"sk-ant-[A-Za-z0-9_-]{20,}",
    r"sk-proj-[A-Za-z0-9_-]{20,}",
    r"sk-[A-Za-z0-9]{24,}",
    r"AKIA[0-9A-Z]{16}",
    r"ASIA[0-9A-Z]{16}",
    r"gh[pousr]_[A-Za-z0-9]{30,}",
    r"github_pat_[A-Za-z0-9_]{30,}",
    r"xox[baprs]-[A-Za-z0-9-]{12,}",
    r"AIza[A-Za-z0-9_-]{35}",
    r"sbp_[a-f0-9]{40}",
    r"r8_[A-Za-z0-9]{35,}",
    r"hf_[A-Za-z0-9]{30,}",
    r"-----BEGIN [A-Z ]*PRIVATE KEY-----",
    r"(?:api[_-]?key|secret|token|password|passwd|bearer)[A-Za-z_]*" + Q + r"?\s*[:=]\s*" + Q
    + r"[A-Za-z0-9_/+=.-]{24,}" + Q,
]), re.IGNORECASE)

# A line that reads from the environment is the correct pattern, not a finding.
SAFE_RE = re.compile(r"process\.env|import\.meta\.env|Deno\.env|os\.environ|getenv|ENV\[|System\.getenv"
                     r"|secrets\.|vars\.|\$\{?[A-Z][A-Z0-9_]*\}?|%[A-Z][A-Z0-9_]*%")
# Obvious stand-ins: templates and docs are full of these on purpose.
FAKE_RE = re.compile(r"your[-_]|my[-_]key|xxxx|<[A-Za-z_]|\.\.\.|placeholder|example|sample|template"
                     r"|changeme|change[-_]me|dummy|fake|redacted|REPLACE|TODO|\*\*\*\*", re.IGNORECASE)
TEMPLATE_FILES = (".env.example", ".env.sample", ".env.template")


def visible_text(payload):
    event = payload.get("hook_event_name") or ""
    tool = payload.get("tool_name") or ""
    ti = payload.get("tool_input") or {}
    if event == "PreToolUse":
        if tool == "Write":
            return ti.get("content") or ""
        if tool in ("Edit", "MultiEdit"):
            parts = [ti.get("new_string") or ""] + [e.get("new_string") or "" for e in ti.get("edits") or []]
            return "\n".join(parts)
        if tool == "NotebookEdit":
            return ti.get("new_source") or ""
        if tool == "Bash":  # heredocs, echo >> file, sed -i: the other tools never see these
            return ti.get("command") or ""
        return ""
    if event == "PostToolUse":
        path = ti.get("file_path") or ""
        if not path or path.endswith(TEMPLATE_FILES):
            return ""
        try:
            with open(path, errors="replace") as fh:
                return fh.read()
        except OSError:
            return ""
    return ""


def hit_lines(text):
    hits = []
    for n, line in enumerate(text.splitlines(), 1):
        if KEY_RE.search(line) and not SAFE_RE.search(line) and not FAKE_RE.search(line):
            hits.append(n)
            if len(hits) == 5:
                break
    return hits


def main():
    try:
        payload = json.loads(sys.stdin.read() or "{}")
        hits = hit_lines(visible_text(payload))
        if not hits:
            return
        reason = ("Possible live credential in this change, at line(s) %s. Do not print or repeat the value. "
                  "Move it to the local dotenv file, read it from the environment at the call site, and add only "
                  "the key NAME to the checked-in example env file. If this is a placeholder or test fixture, make "
                  "it obviously fake (prefix it with YOUR_ or example_) and retry. Checked by guard-key-literals."
                  % ",".join(map(str, hits)))
        if payload.get("hook_event_name") == "PreToolUse":
            out = {"hookEventName": "PreToolUse", "permissionDecision": "deny", "permissionDecisionReason": reason}
        else:
            out = {"hookEventName": "PostToolUse", "additionalContext": reason}
        print(json.dumps({"hookSpecificOutput": out}))
    except Exception:
        pass


if __name__ == "__main__":
    main()
