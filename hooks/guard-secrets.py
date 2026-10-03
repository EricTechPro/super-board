#!/usr/bin/env python3
"""PreToolUse(Bash|Read|Grep) guard: refuse to read or pipe secret files.

Stops secrets getting OUT -- `cat .env`, `source .env.local`, `grep KEY .env | curl`,
or the Read tool opening a dotenv file -- so a key never lands in the transcript.
`.env.example` and friends are deliberately allowed: that file is how an agent
learns which keys exist. Its own errors never block a tool call.

Adapted from ai-builder-starter-kit's .agents/hooks/guard-secrets.sh (Eric Tech).
"""
import json
import re
import sys

B = r"(?:^|[^A-Za-z0-9._-])"   # boundary before a name
E = r"(?:[^A-Za-z0-9._-]|$)"   # boundary after a name
SECRET_RE = re.compile("|".join([
    B + r"\.env" + E,
    r"\.env\.(?:local|production|prod|staging|development|dev|test)" + E,
    B + r"id_(?:rsa|ed25519|ecdsa)" + E,
    B + r"\.npmrc" + E,
    B + r"credentials(?:\.json)?" + E,
    r"service-account[A-Za-z0-9._-]*\.json",
    r"\.pem" + E,
]))

# The one sanctioned way to ask "is KEY set?": super-board-env-check.sh prints
# present / empty / missing per key and never a value. Allowed only as a single
# plain call -- no pipe, redirect, chain or substitution can ride along.
ENV_CHECK = re.compile(
    r"^\s*(?:bash\s+|sh\s+)?(?:\S*/)?super-board-env-check\.sh"
    r"(?:\s+[A-Za-z0-9_./=-]+)*\s*$")

REASON = ("Blocked by guard-secrets: this touches a secret file. Read the checked-in example env "
          "file (.env.example) for the key names, or ask the user to run the command themselves "
          "with the ! prefix.")


def subject(payload):
    """The text this tool call can expose: a shell command or a file path."""
    tool = payload.get("tool_name") or ""
    ti = payload.get("tool_input") or {}
    if tool == "Bash":
        return ti.get("command") or ""
    if tool == "Read":
        return ti.get("file_path") or ""
    if tool == "Grep":
        return " ".join(str(ti.get(k) or "") for k in ("path", "glob"))
    return ""


def main():
    try:
        payload = json.loads(sys.stdin.read() or "{}")
        text = subject(payload)
        if payload.get("tool_name") == "Bash" and ENV_CHECK.match(text):
            return
        if text and SECRET_RE.search(text):
            print(json.dumps({"hookSpecificOutput": {"hookEventName": "PreToolUse",
                                                     "permissionDecision": "deny",
                                                     "permissionDecisionReason": REASON}}))
    except Exception:
        pass  # fail open rather than block every call in the project


if __name__ == "__main__":
    main()
