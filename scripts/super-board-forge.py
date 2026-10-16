#!/usr/bin/env python3
"""Forge resolution: which host the board talks to, and where.

One source of truth for `github` vs `gitea`. Precedence, highest first:
environment (SB_FORGE / SB_FORGE_HOST / SB_FORGE_LOGIN) → config keys
(forge / forge_host / forge_login) → the git remote's host (advisory: it
fills owner/repo and a gitea host, but never flips the forge kind on its
own) → default `github`.

`project.owner` stays the account that owns the board; owner/repo fall back
to parsing `repo.remote` (any host, https/http/ssh/scp forms) and then to
`git remote get-url origin`. A gitea config without a resolvable host exits
66 — scripts must never guess which server to write to.

Usage:
  super-board-forge.py get [--config PATH] [--root DIR] [--json|--shell]
  super-board-forge.py forge|host|owner|repo [--config PATH] [--root DIR]

Exit codes: 0 ok · 64 usage/unknown forge · 66 config missing required value.
"""
from __future__ import annotations

import argparse
import json
import os
import re
import shlex
import subprocess
import sys

FORGES = ("github", "gitea")
GITHUB_HOST = "https://github.com"

# https://host[:port]/owner/repo(.git) · http://… · ssh://git@host[:port]/owner/repo
_URL_RE = re.compile(r'^(https?)://(?:[^@/]+@)?([^/:]+)(?::(\d+))?/(.+?)(?:\.git)?/?$')
_SSH_RE = re.compile(r'^ssh://(?:[^@/]+@)?([^/:]+)(?::(\d+))?/(.+?)(?:\.git)?/?$')
# scp form: git@host:owner/repo(.git)
_SCP_RE = re.compile(r'^(?:[^@/\s]+@)?([^/:@\s]+):(.+?)(?:\.git)?/?$')


def parse_remote(url):
    """Remote URL → {host, owner, repo} for any forge, or None when unparseable.

    `host` keeps the URL's own scheme and port (a local Gitea is often plain
    http on :3000); scp-form remotes are assumed https.
    """
    url = (url or "").strip()
    if not url:
        return None
    scheme, netloc, path = None, None, None
    m = _URL_RE.match(url)
    if m:
        scheme, netloc, path = m.group(1), m.group(2), m.group(4)
        if m.group(3):
            netloc = f"{netloc}:{m.group(3)}"
    else:
        m = _SSH_RE.match(url)
        if m:
            scheme, netloc, path = "https", m.group(1), m.group(3)
            if m.group(2):
                netloc = f"{netloc}:{m.group(2)}"
        else:
            m = _SCP_RE.match(url)
            if m and "/" in m.group(2):
                scheme, netloc, path = "https", m.group(1), m.group(2)
    if not (scheme and netloc and path):
        return None
    parts = [p for p in path.strip("/").split("/") if p]
    if len(parts) < 2:
        return None
    owner, repo = parts[-2], parts[-1]
    if not re.match(r'^[\w.\-]+$', owner) or not re.match(r'^[\w.\-]+$', repo):
        return None
    return {"host": f"{scheme}://{netloc}", "owner": owner, "repo": repo}


def _git_remote_url(root):
    try:
        r = subprocess.run(["git", "remote", "get-url", "origin"], cwd=root,
                           capture_output=True, text=True, timeout=5)
    except (OSError, subprocess.TimeoutExpired):
        return None
    return r.stdout.strip() if r.returncode == 0 else None


def resolve(config_path=None, root=None):
    """Precedence env → config → remote → default. Returns the forge dict."""
    root = root or os.environ.get("SB_REPO_PATH") or os.getcwd()
    cfg = {}
    if config_path:
        try:
            with open(config_path) as f:
                cfg = json.load(f)
        except (OSError, ValueError):
            cfg = {}
    if not isinstance(cfg, dict):
        cfg = {}

    forge = (os.environ.get("SB_FORGE") or cfg.get("forge") or "").strip().lower()
    remote = parse_remote((cfg.get("repo") or {}).get("remote")) or parse_remote(_git_remote_url(root))

    if not forge:
        # The remote's host never flips the kind by itself: an unrecognized
        # host stays "github" (today's behavior) until the config says otherwise.
        forge = "github"
    if forge not in FORGES:
        raise ValueError(f"unknown forge \"{forge}\" (expected one of: {', '.join(FORGES)})")

    host = os.environ.get("SB_FORGE_HOST") or cfg.get("forge_host") or ""
    if not host:
        if forge == "gitea" and remote and "github.com" not in remote["host"]:
            host = remote["host"]
        elif forge == "github":
            host = GITHUB_HOST
    host = host.rstrip("/")

    owner = (os.environ.get("SB_FORGE_OWNER") or (cfg.get("project") or {}).get("owner")
             or (remote or {}).get("owner") or "")
    repo = os.environ.get("SB_FORGE_REPO") or (remote or {}).get("repo") or ""
    login = os.environ.get("SB_FORGE_LOGIN") or cfg.get("forge_login") or ""

    return {"forge": forge, "host": host, "login": login, "owner": owner, "repo": repo,
            "config": os.path.abspath(config_path) if config_path else None}


def check(res):
    """Post-conditions callers rely on; raises with exit-66 wording."""
    if res["forge"] == "gitea" and not res["host"]:
        raise LookupError("forge is gitea but no host resolved — set forge_host in the config, "
                          "SB_FORGE_HOST, or a git remote pointing at the instance")


def main(argv):
    ap = argparse.ArgumentParser(add_help=True, description=__doc__.splitlines()[0])
    ap.add_argument("cmd", choices=("get", "forge", "host", "owner", "repo"))
    ap.add_argument("--config")
    ap.add_argument("--root")
    ap.add_argument("--json", action="store_true")
    ap.add_argument("--shell", action="store_true",
                    help="print SB_FORGE_* assignments safe for eval (get only)")
    a = ap.parse_args(argv)

    try:
        res = resolve(a.config, a.root)
    except ValueError as e:  # unknown forge → usage
        print(str(e), file=sys.stderr)
        return 64
    try:
        check(res)
    except LookupError as e:
        print(str(e), file=sys.stderr)
        return 66

    if a.cmd != "get":
        print(res[a.cmd])
        return 0
    if a.shell:
        print(f"SB_FORGE_KIND={shlex.quote(res['forge'])}")
        print(f"SB_FORGE_HOST={shlex.quote(res['host'])}")
        print(f"SB_FORGE_LOGIN={shlex.quote(res['login'])}")
        print(f"SB_FORGE_OWNER={shlex.quote(res['owner'])}")
        print(f"SB_FORGE_REPO={shlex.quote(res['repo'])}")
        return 0
    print(json.dumps(res if a.json else {k: v for k, v in res.items() if k != "config"}, indent=1))
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
