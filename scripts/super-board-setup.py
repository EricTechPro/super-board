#!/usr/bin/env python3
"""super-board-setup.py — the deterministic half of `/super-board onboard`.

Onboard asks the questions; this script finds things out and fixes the must-haves,
so step 1 (Checks) can say "Fixed for you" without asking anything.

    super-board-setup.py check   [--root DIR] [--pack DIR]            what is missing / old (read-only)
    super-board-setup.py fix     [--root DIR] [--pack DIR] [--no-helpers] [--dry-run]
                                                                       apply every must-have, then re-check
    super-board-setup.py migrate-config <config.json> [--dry-run]     old config keys → v3 keys
    super-board-setup.py names   [--root DIR]                          two board-name suggestions
    super-board-setup.py branch  [--root DIR]                          branches, deploy source, recommendation
    super-board-setup.py board-rank    --owner O                       the user's boards, best column match first
    super-board-setup.py board-migrate (--config C | --owner O --number N --repo R) [--qa-all] [--prune-empty] [--dry-run]
                                                                       columns + labels + Skipped → Done

Every command prints one JSON object. `--text` on check/fix prints the short ✓ lists the
onboard screen shows instead.

What `fix` does, with NO question (all of it backed up first to
.claude/super-board/backup/<ts>/):
  - installs or refreshes skills, .claude/bin scripts, workflows, guard hooks and their
    settings.json entries (runs the pack's install.sh) when any is missing or older
  - removes the folders of skills that no longer exist: super-refine, cleanup-wt, arch-loop
  - migrates every .claude/super-board/configs/*.json to the v3 keys (migrate-config)
  - `git init` when the folder is not a repo
  - adds Matt Pocock's helper skills with npx when Node is present and they are missing
It never installs a system tool or signs in: those come back in `needs` with the exact
command for this OS, for onboard to ask about.

`board-migrate` is the board half (needs `gh` with project scope): adds the missing
Status options (--prune-empty also drops unused extras such as a new board's Todo),
creates the three labels, maps old type labels, labels every card `qa`
on a board that was "qa-only" (--qa-all), moves Skipped cards to Done, removes the Skipped
option, and puts back any card status the option rewrite cleared. Cards are never lost.

Exit: 0 ok · 1 check found red items · 2 a gh call failed · 64 usage · 66 pack not found.
Stdlib only.
"""
from __future__ import annotations

import datetime as dt
import glob
import json
import os
import platform
import re
import shutil
import subprocess
import sys

COLUMNS = ["Backlog", "Ready", "Building", "QA", "Review", "Blocked", "Done"]
LABELS = {
    "qa": ("0e8a16", "Test what exists; skips Building (super-board)"),
    "bug": ("d73a4a", "Something is broken; built, tested, reviewed (super-board)"),
    "feature": ("1d76db", "New behaviour; built, tested, reviewed (super-board)"),
}
# Type labels from older packs and common trackers → the three v3 labels.
OLD_LABELS = {
    "build": "feature", "type:feature": "feature", "kind:feature": "feature", "enhancement": "feature",
    "bug-fix": "bug", "bugfix": "bug", "type:bug": "bug", "kind:bug": "bug",
    "qa-only": "qa", "type:qa": "qa", "kind:qa": "qa",
}
SKILLS = ["super-board", "super-build", "super-qa", "super-review", "super-collect", "visual", "git-sync", "ui-refine-loop"]
OLD_SKILL_DIRS = ["super-refine", "cleanup-wt", "arch-loop"]
BIN = ["super-board-run.sh", "super-board-gh-guard.sh", "super-board-status.py", "super-board-wave-plan.sh",
       "super-board-deps.sh", "super-board-preflight.sh", "super-board-merge-gate.sh",
       "super-board-merge-policy.py", "super-board-env-check.sh", "super-board-agents-md.py",
       "super-board-settings.py", "super-board-setup.py", "super-board-usage.sh", "super-board-pr-body.sh",
       "super-review-file-refactor.sh", "super-qa-file-bug.sh", "super-board-stop.sh"]
WORKFLOWS = ["super-board-wave.js", "ui-refine-loop.js"]
HELPERS_CMD = "npx -y skills@latest add mattpocock/skills --skill '*' -a claude-code -y"

# System tools: why the board needs each, and the install command per OS family.
TOOLS = {
    "git": ("branches, worktrees and merges", {"mac": "brew install git", "apt": "sudo apt-get install -y git",
            "dnf": "sudo dnf install -y git", "win": "winget install --id Git.Git -e"}),
    "gh": ("reads and moves cards on GitHub", {"mac": "brew install gh", "apt": "sudo apt-get install -y gh",
           "dnf": "sudo dnf install -y gh", "win": "winget install --id GitHub.cli -e"}),
    "jq": ("the board scripts read JSON with it", {"mac": "brew install jq", "apt": "sudo apt-get install -y jq",
           "dnf": "sudo dnf install -y jq", "win": "winget install --id jqlang.jq -e"}),
    "node": ("Matt Pocock's coding skills (tests, code review, debugging) the board uses",
             {"mac": "brew install node", "apt": "sudo apt-get install -y nodejs npm",
              "dnf": "sudo dnf install -y nodejs npm", "win": "winget install --id OpenJS.NodeJS.LTS -e"}),
}


# ── small helpers ──────────────────────────────────────────────────────────────

def out(obj, code=0):
    print(json.dumps(obj, indent=1))
    return code


def run(cmd, cwd=None, check=False, input=None):
    r = subprocess.run(cmd, cwd=cwd, capture_output=True, text=True, input=input)
    if check and r.returncode != 0:
        raise RuntimeError(f"{' '.join(cmd[:3])} failed: {(r.stderr or r.stdout).strip()[:300]}")
    return r


def have(tool):
    return shutil.which(tool) is not None


def os_family():
    sysname = platform.system()
    if sysname == "Darwin":
        return "mac"
    if sysname == "Windows" or os.environ.get("OS") == "Windows_NT" or re.match(r"(MINGW|MSYS|CYGWIN)", sysname):
        return "win"
    if have("apt-get"):
        return "apt"
    if have("dnf"):
        return "dnf"
    return "apt"


def vtuple(v):
    try:
        return tuple(int(x) for x in re.findall(r"\d+", v or "")[:3]) or (0,)
    except ValueError:
        return (0,)


def read(path, default=""):
    try:
        with open(path) as f:
            return f.read().strip()
    except OSError:
        return default


def load_json(path):
    try:
        with open(path) as f:
            return json.load(f)
    except (OSError, ValueError):
        return None


def write_json(path, data):
    tmp = path + ".tmp"
    with open(tmp, "w") as f:
        json.dump(data, f, indent=2)
        f.write("\n")
    os.replace(tmp, path)


def find_pack(explicit=None):
    """The pack checkout whose install.sh can (re)install pieces. None when not found."""
    cands = [explicit, os.environ.get("SUPER_BOARD_PACK"),
             os.path.dirname(os.path.dirname(os.path.abspath(__file__)))]
    home = os.path.expanduser("~/.claude/plugins")
    if os.path.isdir(home):
        cands += sorted(os.path.dirname(p) for p in glob.glob(os.path.join(home, "**", "install.sh"), recursive=True)
                        if "super-board" in p and "node_modules" not in p)
    for c in cands:
        if c and os.path.isfile(os.path.join(c, "install.sh")) and os.path.isdir(os.path.join(c, "skills", "super-board")):
            return os.path.abspath(c)
    return None


def helper_skills_present(root):
    lock = os.path.join(root, "skills-lock.json")
    if "mattpocock/skills" in read(lock):
        return True
    for d in (os.path.join(root, ".claude", "skills"), os.path.expanduser("~/.claude/skills")):
        if os.path.isfile(os.path.join(d, "grilling", "SKILL.md")) and os.path.isfile(os.path.join(d, "tdd", "SKILL.md")):
            return True
    return False


def is_git_repo(root):
    return have("git") and run(["git", "rev-parse", "--is-inside-work-tree"], cwd=root).returncode == 0


def snippet_commands(pack):
    snip = load_json(os.path.join(pack, "hooks", "settings-snippet.json")) if pack else None
    if not snip:
        return []
    return [h["command"] for entries in snip["hooks"].values() for e in entries for h in e.get("hooks", [])]


def settings_commands(root):
    s = load_json(os.path.join(root, ".claude", "settings.json")) or {}
    return {h.get("command") for entries in (s.get("hooks") or {}).values() for e in entries
            for h in e.get("hooks", [])}


# ── config migration ───────────────────────────────────────────────────────────

def machine_tz():
    if os.environ.get("TZ"):
        return os.environ["TZ"]
    try:
        link = os.readlink("/etc/localtime")
        if "zoneinfo/" in link:
            return link.split("zoneinfo/", 1)[1]
    except OSError:
        pass
    return "UTC"


def migrate_config(cfg):
    """Return (new config, [human-readable change lines]). Pure; never drops a project setting
    that still means something."""
    c = json.loads(json.dumps(cfg))
    changes = []
    variant = c.pop("variant", None)
    if variant is not None:
        changes.append(f"variant \"{variant}\" removed — labels route cards now"
                       + (" (cards get the qa label)" if variant == "qa-only" else ""))
        if variant == "qa-only":
            c["_qa_all"] = True  # read by board-migrate --qa-all, then dropped
    cols = c.get("columns")
    if cols != COLUMNS:
        extra = [x for x in (cols or []) if x not in COLUMNS and x != "Skipped"]
        c["columns"] = COLUMNS + extra
        if cols and "Skipped" in cols:
            changes.append("Skipped column removed from config")
        missing = [x for x in COLUMNS if x not in (cols or [])]
        if missing:
            changes.append("columns added: " + ", ".join(missing))
    tgt = c.get("target") or {}
    if tgt.get("type") == "url":
        c["target"] = {"type": "repo+url" if c.get("repo") else "repo", "url": tgt.get("url")}
        changes.append("URL-only target → repo board (a live site alone: /super-qa <url>)")
    col = c.get("collect")
    if isinstance(col, dict) and any(k in col for k in ("errors", "feedback_paths", "lookback_runs")):
        errors = col.pop("errors", None)
        col.pop("feedback_paths", None)
        col.pop("lookback_runs", None)
        if "sources" not in col:
            col["sources"] = (["sentry"] if errors in ("auto", "sentry") else []) + ["github", "prs", "architecture"]
        changes.append("collect: intake/lookback keys → sources " + ", ".join(col["sources"]))
    ref = c.get("refine")
    if isinstance(ref, dict) and "qa_hook_rounds" in ref:
        ref.pop("qa_hook_rounds")
        changes.append("refine.qa_hook_rounds removed (the board no longer runs ui-refine-loop)")
    if "merge_policy" not in c:
        c["merge_policy"] = {"default": "human" if c.get("human_approves_merge") else "auto"}
        changes.append(f"merge rule: merge_policy.default \"{c['merge_policy']['default']}\" (from human_approves_merge)")
    if "migrations" not in c:
        c["migrations"] = {"allowed_envs": ["test", "staging"],
                           "target_env": "live" if c.get("base_branch", "main") in ("main", "master") else "staging"}
        changes.append("migrations: test + staging allowed (defaults)")
    n = c.get("notifications")
    if isinstance(n, dict) and n.get("channel") not in (None, "session"):
        changes.append(f"notifications: \"{n.get('channel')}\" → session (super-board sends no messages)")
        n["channel"], n["chat_id"] = "session", None
    if not c.get("timezone"):
        c["timezone"] = machine_tz()
        changes.append(f"timezone {c['timezone']} added")
    if not c.get("worker_backend"):
        c["worker_backend"] = "workflow"
        changes.append("worker_backend \"workflow\" added")
    return c, changes


# ── check / fix ────────────────────────────────────────────────────────────────

def installed_version(root):
    return read(os.path.join(root, ".claude", "skills", "super-board", "VERSION")) or None


def check(root, pack):
    claude = os.path.join(root, ".claude")
    pack_version = read(os.path.join(pack, "VERSION")) if pack else None
    have_v = installed_version(root)
    upgrade_rec = load_json(os.path.join(claude, "super-board", "upgrade.json")) or {}
    missing = []
    missing += [f"skill {s}" for s in SKILLS if not os.path.isfile(os.path.join(claude, "skills", s, "SKILL.md"))]
    missing += [f"script {b}" for b in BIN if not os.path.isfile(os.path.join(claude, "bin", b))]
    missing += [f"workflow {w}" for w in WORKFLOWS if not os.path.isfile(os.path.join(claude, "workflows", w))]
    hook_files = sorted(os.path.basename(p) for p in glob.glob(os.path.join(pack, "hooks", "*.py"))) if pack else []
    missing += [f"hook {h}" for h in hook_files if not os.path.isfile(os.path.join(claude, "hooks", h))]
    wired = settings_commands(root)
    unwired = [c for c in snippet_commands(pack) if c not in wired]
    if unwired:
        missing.append(f"settings.json: {len(unwired)} guard entr{'y' if len(unwired) == 1 else 'ies'}")
    old_dirs = [d for d in OLD_SKILL_DIRS if os.path.isdir(os.path.join(claude, "skills", d))]
    configs = {}
    for p in sorted(glob.glob(os.path.join(claude, "super-board", "configs", "*.json"))):
        cfg = load_json(p)
        if isinstance(cfg, dict):
            _, ch = migrate_config(cfg)
            if ch:
                configs[os.path.relpath(p, root)] = ch
    older = bool(upgrade_rec.get("from")) or bool(old_dirs) or any(
        "variant" in " ".join(ch) or "Skipped" in " ".join(ch) or "collect:" in " ".join(ch) for ch in configs.values())
    if have_v and pack_version and vtuple(have_v) < vtuple(pack_version):
        older = True
    from_v = upgrade_rec.get("from") or (have_v if have_v and pack_version and vtuple(have_v) < vtuple(pack_version) else None)
    fam = os_family()
    needs = []
    for t in ("git", "gh", "jq", "node"):
        if not have(t if t != "node" else "npx"):
            why, cmds = TOOLS[t]
            cmd = cmds[fam]
            if t == "node":
                cmd += " && " + HELPERS_CMD
            needs.append({"kind": "tool", "name": t, "why": why, "command": cmd})
    helpers = helper_skills_present(root)
    git = is_git_repo(root)
    ok = []
    if not missing:
        ok.append("super-board skills, scripts and board engine present")
        if hook_files:
            ok.append(f"{len(hook_files)} safety guards on")
    if git:
        ok.append("git repo found")
    if helpers:
        ok.append("Matt Pocock's coding skills (tests, code review, debugging) present")
    red = bool(missing or old_dirs or configs or not git or needs or (not helpers and have("npx")))
    return {
        "root": root, "pack": pack, "pack_version": pack_version, "installed_version": have_v,
        "upgrade": older, "from": from_v or ("older" if older else None),
        "added_skills": upgrade_rec.get("added_skills", []),
        "missing": missing, "old_dirs": old_dirs, "configs": configs, "git": git,
        "helper_skills": helpers, "needs": needs, "os": fam, "ok": ok, "green": not red,
    }


def backup(root, paths, stamp):
    dest = os.path.join(root, ".claude", "super-board", "backup", stamp)
    for p in paths:
        if not os.path.exists(p):
            continue
        rel = os.path.relpath(p, root)
        target = os.path.join(dest, rel)
        os.makedirs(os.path.dirname(target), exist_ok=True)
        (shutil.copytree if os.path.isdir(p) else shutil.copy2)(p, target)
    return os.path.relpath(dest, root) + "/"


def fix(root, pack, helpers=True, dry=False):
    before = check(root, pack)
    fixed, notes = [], []
    claude = os.path.join(root, ".claude")
    stamp = dt.datetime.now().strftime("%Y%m%d-%H%M")
    to_backup = [os.path.join(claude, "settings.json"), os.path.join(claude, "super-board", "configs")]
    to_backup += [os.path.join(claude, "skills", d) for d in before["old_dirs"]]
    bdir = None
    if not dry and (before["missing"] or before["old_dirs"] or before["configs"] or before["upgrade"]):
        bdir = backup(root, to_backup, stamp)

    if before["missing"]:
        if not pack:
            return {**before, "fixed": [], "error": "pack-not-found"}
        if not dry:
            r = run(["bash", os.path.join(pack, "install.sh"), root],
                    input="", cwd=root)
            if r.returncode != 0:
                return {**before, "fixed": fixed, "error": "install.sh failed: " + (r.stderr or r.stdout)[-300:]}
            rec = load_json(os.path.join(claude, "super-board", "upgrade.json")) or {}
            before["added_skills"] = rec.get("added_skills", before["added_skills"])
        if before["upgrade"]:
            fixed.append("scripts, board engine and safety guards updated")
        else:
            fixed.append("super-board skills, scripts and board engine installed")
            if any(m.startswith("hook") or m.startswith("settings") for m in before["missing"]):
                n = len(glob.glob(os.path.join(pack, "hooks", "*.py")))
                fixed.append(f"{n} safety guards switched on")
                fixed.append("settings.json entries added (backup kept)")
    elif before["upgrade"]:
        fixed.append("scripts, board engine and safety guards updated")
    if before["upgrade"]:
        added = before["added_skills"]
        fixed.insert(0, "skills updated" + (f"; added {', '.join(added)}" if added else ""))

    if before["old_dirs"]:
        if not dry:
            for d in before["old_dirs"]:
                shutil.rmtree(os.path.join(claude, "skills", d), ignore_errors=True)
        fixed.append("removed old folders: " + ", ".join(before["old_dirs"]))

    for rel, ch in before["configs"].items():
        p = os.path.join(root, rel)
        new, _ = migrate_config(load_json(p))
        if not dry:
            write_json(p, new)
        if before["upgrade"]:
            fixed.append(f"config moved to the new keys ({len(ch)} change{'s' if len(ch) != 1 else ''})")
        else:
            fixed.append(f"config repaired: {rel}")
        notes += ch

    if not before["git"] and have("git"):
        if not dry:
            run(["git", "init", "-q"], cwd=root)
        fixed.append("git repo created (git init)")

    if helpers and not before["helper_skills"] and have("npx"):
        if not dry:
            r = run(["bash", "-c", HELPERS_CMD], cwd=root, input="")
            (fixed if r.returncode == 0 else notes).append(
                "Matt Pocock's coding skills added" if r.returncode == 0
                else "couldn't add Matt Pocock's skills — re-run later: " + HELPERS_CMD)
        else:
            fixed.append("Matt Pocock's coding skills added")

    if not dry:
        up = os.path.join(claude, "super-board", "upgrade.json")
        if os.path.exists(up):
            os.remove(up)
    after = check(root, pack) if not dry else before
    return {**after, "upgraded": before["upgrade"], "from": before["from"], "fixed": fixed,
            "notes": notes, "backup": bdir}


def text_report(res):
    lines = []
    if res.get("upgraded"):
        lines.append(f"Upgraded for you (backup: {res.get('backup') or '—'})")
    else:
        lines.append("Fixed for you:" if res.get("fixed") else "Checks:")
    done = res.get("fixed", []) + [o for o in res.get("ok", []) if not res.get("upgraded")
                                    and not any(o.split()[0] in f for f in res.get("fixed", []))]
    for f in done:
        lines.append(f"  ✓ {f}")
    if res.get("green"):
        lines.append("  ✓ re-checked: all green")
    elif "fixed" not in res:
        red = res.get("missing", [])[:3] + [f"old folder {d}" for d in res.get("old_dirs", [])] + \
            [f"config {c} uses old keys" for c in res.get("configs", {})] + ([] if res.get("git") else ["not a git repo"])
        lines += [f"  ✗ {r}" for r in red]
        if red:
            lines.append("  → fix: super-board-setup.py fix")
    for n in res.get("needs", []):
        lines.append(f"  Needs your machine: {n['name']} isn't installed. It's needed for {n['why']}.")
        lines.append(f"    {n['command']}")
    return "\n".join(lines)


# ── board names and branches ──────────────────────────────────────────────────

def names(root):
    pkg = load_json(os.path.join(root, "package.json")) or {}
    base = (pkg.get("name") or "").split("/")[-1]
    if not base:
        m = re.search(r'^name\s*=\s*"([^"]+)"', read(os.path.join(root, "pyproject.toml")), re.M)
        base = m.group(1) if m else ""
    readme_title = ""
    for f in ("README.md", "readme.md", "README"):
        m = re.search(r"^#\s+(.+)$", read(os.path.join(root, f)), re.M)
        if m:
            readme_title = re.split(r"\s+[—–-]\s+|:\s", m.group(1).strip())[0].strip()
            break
    folder = os.path.basename(os.path.abspath(root))
    cap = lambda s: s[:1].upper() + s[1:]
    first = cap(base or readme_title or folder)
    second = cap(readme_title or base or folder)
    empty = not base and not readme_title and not os.listdir(root) if os.path.isdir(root) else True
    if empty:
        return {"names": [f"{folder} board", "My first board"], "from": "folder"}
    n1, n2 = f"{first} board", f"{second} build board"
    return {"names": [n1, n2], "from": "package.json" if base else ("README" if readme_title else "folder")}


def branch(root):
    git = lambda *a: run(["git", *a], cwd=root)
    if not is_git_repo(root):
        return {"git": False, "branches": [], "staging": False, "deploy": None,
                "recommend": "main", "create_staging": False}
    local = [b for b in git("branch", "--format=%(refname:short)").stdout.split() if b]
    remote = [b.split("/", 1)[1] for b in git("branch", "-r", "--format=%(refname:short)").stdout.split()
              if "/" in b and not b.endswith("/HEAD")]
    allb = sorted(set(local + remote))
    head = git("symbolic-ref", "--short", "refs/remotes/origin/HEAD").stdout.strip().split("/", 1)[-1]
    default = head or ("main" if "main" in allb else ("master" if "master" in allb else (local[0] if local else "main")))
    staging = next((b for b in ("staging", "develop", "dev") if b in allb), None)
    deploy = None
    if os.path.exists(os.path.join(root, "vercel.json")) or os.path.isdir(os.path.join(root, ".vercel")):
        deploy = f"Vercel deploys {default}"
    elif os.path.exists(os.path.join(root, "netlify.toml")):
        deploy = f"Netlify deploys {default}"
    else:
        for wf in glob.glob(os.path.join(root, ".github", "workflows", "*.y*ml")):
            body = read(wf)
            if re.search(r"deploy|vercel|netlify|fly|render|heroku|pages", body, re.I) and re.search(
                    rf"branches:\s*\[?\s*['\"]?{re.escape(default)}\b", body):
                deploy = f"{os.path.basename(wf)} deploys {default}"
                break
    return {"git": True, "branches": [b for b in allb if not b.startswith(("issue-", "feat/", "fix/"))][:8],
            "default": default, "staging": staging, "deploy": deploy,
            "recommend": staging or "staging", "create_staging": staging is None,
            "create_command": None if staging else f"git push origin {default}:staging"}


# ── GitHub board: rank and migrate ────────────────────────────────────────────

def gh_json(*args, input=None):
    r = run(["gh", *args], input=input)
    if r.returncode != 0:
        raise RuntimeError(f"gh {' '.join(args[:3])}: {(r.stderr or r.stdout).strip()[:300]}")
    return json.loads(r.stdout or "{}")


def status_field(owner, number):
    fields = gh_json("project", "field-list", str(number), "--owner", owner, "--format", "json").get("fields", [])
    return next((f for f in fields if f.get("name") == "Status"), None)


def board_rank(owner):
    projects = gh_json("project", "list", "--owner", owner, "--format", "json", "--limit", "50").get("projects", [])
    ranked = []
    for p in projects:
        if p.get("closed"):
            continue
        f = status_field(owner, p["number"]) or {}
        have = [o["name"] for o in f.get("options", [])]
        low = {h.lower() for h in have}
        match = [c for c in COLUMNS if c.lower() in low]
        ranked.append({"number": p["number"], "title": p.get("title"), "url": p.get("url"),
                       "cards": (p.get("items") or {}).get("totalCount", 0),
                       "matches": len(match), "missing": [c for c in COLUMNS if c not in match],
                       "extra": [h for h in have if h.lower() not in {c.lower() for c in COLUMNS}]})
    ranked.sort(key=lambda r: (-r["matches"], -r["cards"], -r["number"]))
    best = ranked[0] if ranked and ranked[0]["matches"] >= 4 else None
    return {"owner": owner, "boards": ranked, "recommend": best and best["number"]}


OPTIONS_Q = "query($id:ID!){node(id:$id){... on ProjectV2SingleSelectField{options{id name color description}}}}"
UPDATE_M = ("mutation($id:ID!,$opts:[ProjectV2SingleSelectFieldOptionInput!]!){updateProjectV2Field(input:"
            "{fieldId:$id,singleSelectOptions:$opts}){projectV2Field{... on ProjectV2SingleSelectField{options{id name}}}}}")
COLORS = {"Backlog": "GRAY", "Ready": "BLUE", "Building": "YELLOW", "QA": "ORANGE", "Review": "PURPLE",
          "Blocked": "RED", "Done": "GREEN"}


def gql(query, variables):
    return gh_json("api", "graphql", "--input", "-", input=json.dumps({"query": query, "variables": variables}))


def item_labels(it):
    raw = (it.get("labels") or []) + ((it.get("content") or {}).get("labels") or [])
    return {(x.get("name") if isinstance(x, dict) else str(x)).lower() for x in raw}


def board_migrate(owner, number, repo, qa_all=False, dry=False, prune_empty=False):
    """Bring one GitHub Project to the v3 shape. Never removes a card."""
    res = {"added_columns": [], "labels_created": [], "labels_mapped": 0, "qa_labelled": 0,
           "skipped_moved": 0, "skipped_removed": False, "restored": 0}
    proj = gh_json("project", "view", str(number), "--owner", owner, "--format", "json")
    pid, res["url"] = proj.get("id"), proj.get("url")
    field = status_field(owner, number)
    if not field:
        raise RuntimeError("project has no Status field")
    fid = field["id"]
    opts = gql(OPTIONS_Q, {"id": fid})["data"]["node"]["options"]
    items = gh_json("project", "item-list", str(number), "--owner", owner, "--format", "json", "--limit", "500").get("items", [])
    snapshot = {it["id"]: it.get("status") for it in items}

    names_low = {o["name"].lower(): o for o in opts}
    in_use = {it.get("status") for it in items}
    res["added_columns"] = [c for c in COLUMNS if c.lower() not in names_low]

    def option_inputs(keep_skipped):
        out_ = []
        for c in COLUMNS:
            o = names_low.get(c.lower())
            out_.append({"name": o["name"] if o else c, "color": (o or {}).get("color") or COLORS[c],
                         "description": (o or {}).get("description") or ""})
        for o in opts:
            if o["name"].lower() in {c.lower() for c in COLUMNS}:
                continue
            if o["name"].lower() == "skipped" and not keep_skipped:
                continue
            if prune_empty and o["name"] not in in_use:
                continue  # a brand-new board's default Todo / In Progress, holding nothing
            out_.append({"name": o["name"], "color": o.get("color") or "GRAY", "description": o.get("description") or ""})
        return out_

    has_skipped = "skipped" in names_low
    if (res["added_columns"] or prune_empty) and not dry:
        opts_now = gql(UPDATE_M, {"id": fid, "opts": option_inputs(keep_skipped=True)})
        opts_now = opts_now["data"]["updateProjectV2Field"]["projectV2Field"]["options"]
    else:
        opts_now = opts
    ids = {o["name"].lower(): o["id"] for o in opts_now}

    # Labels on the repo: create the three, then map old type labels on every card.
    existing = {l["name"].lower() for l in gh_json("label", "list", "--repo", repo, "--json", "name", "--limit", "300")}
    for name, (color, desc) in LABELS.items():
        if name not in existing:
            res["labels_created"].append(name)
            if not dry:
                run(["gh", "label", "create", name, "--repo", repo, "--color", color, "--description", desc], check=True)
    for it in items:
        content = it.get("content") or {}
        if content.get("type") != "Issue":
            continue
        n, labels = content.get("number"), item_labels(it)
        for old, new in OLD_LABELS.items():
            if old in labels:
                res["labels_mapped"] += 1
                if not dry:
                    run(["gh", "issue", "edit", str(n), "--repo", repo, "--add-label", new, "--remove-label", old])
                labels.add(new)
        if qa_all and it.get("status") not in ("Done", "Skipped") and not labels & set(LABELS):
            res["qa_labelled"] += 1
            if not dry:
                run(["gh", "issue", "edit", str(n), "--repo", repo, "--add-label", "qa"])

    def set_status(item_id, name):
        if dry:
            return
        run(["gh", "project", "item-edit", "--id", item_id, "--project-id", pid, "--field-id", fid,
             "--single-select-option-id", ids[name.lower()]], check=True)

    if has_skipped:
        for it in items:
            if it.get("status") == "Skipped":
                set_status(it["id"], "Done")
                snapshot[it["id"]] = "Done"
                res["skipped_moved"] += 1
        if not dry:
            opts_now = gql(UPDATE_M, {"id": fid, "opts": option_inputs(keep_skipped=False)})
            opts_now = opts_now["data"]["updateProjectV2Field"]["projectV2Field"]["options"]
            ids = {o["name"].lower(): o["id"] for o in opts_now}
        res["skipped_removed"] = True

    # Rewriting options can clear a card's status. Put every one back.
    if not dry and (res["added_columns"] or has_skipped):
        now = gh_json("project", "item-list", str(number), "--owner", owner, "--format", "json", "--limit", "500").get("items", [])
        for it in now:
            want = snapshot.get(it["id"])
            if want and it.get("status") != want and want.lower() in ids:
                set_status(it["id"], want)
                res["restored"] += 1
    return res


# ── CLI ────────────────────────────────────────────────────────────────────────

def flag(argv, name, default=None):
    if name in argv:
        i = argv.index(name)
        if i + 1 < len(argv):
            return argv[i + 1]
    return default


def main(argv):
    if not argv or argv[0] in ("-h", "--help"):
        print(__doc__)
        return 0 if argv else 64
    cmd, rest = argv[0], argv[1:]
    root = os.path.abspath(flag(rest, "--root", os.getcwd()))
    dry = "--dry-run" in rest
    try:
        if cmd in ("check", "fix"):
            pack = find_pack(flag(rest, "--pack"))
            res = check(root, pack) if cmd == "check" else fix(root, pack, "--no-helpers" not in rest, dry)
            if res.get("error") == "pack-not-found":
                print(json.dumps(res, indent=1))
                return 66
            if "--text" in rest:
                print(text_report(res))
                return 0 if res["green"] or res.get("needs") else 1
            return out(res, 0 if res["green"] else 1)
        if cmd == "migrate-config":
            path = rest[0] if rest and not rest[0].startswith("-") else None
            if not path:
                return 64
            new, changes = migrate_config(load_json(path) or {})
            if not dry and changes:
                write_json(path, new)
            return out({"config": path, "changes": changes, "written": bool(changes and not dry)})
        if cmd == "names":
            return out(names(root))
        if cmd == "branch":
            return out(branch(root))
        if cmd == "board-rank":
            owner = flag(rest, "--owner")
            if not owner:
                return 64
            return out(board_rank(owner))
        if cmd == "board-migrate":
            # --config fills owner / number / repo and the qa-all flag an upgraded
            # "qa-only" config left behind (`_qa_all`, removed once applied).
            cfg_path = flag(rest, "--config")
            cfg = load_json(cfg_path) if cfg_path else {}
            cfg = cfg if isinstance(cfg, dict) else {}
            proj = cfg.get("project") or {}
            m = re.search(r"github\.com[:/]([^/]+/[^/.]+)", ((cfg.get("repo") or {}).get("remote") or ""))
            owner = flag(rest, "--owner") or proj.get("owner")
            number = flag(rest, "--number") or proj.get("number")
            repo = flag(rest, "--repo") or (m.group(1) if m else None)
            if not (owner and number and repo):
                return 64
            qa_all = "--qa-all" in rest or bool(cfg.get("_qa_all"))
            res = board_migrate(owner, int(number), repo, qa_all, dry, "--prune-empty" in rest)
            if cfg_path and cfg.pop("_qa_all", None) is not None and not dry:
                write_json(cfg_path, cfg)
            return out(res)
    except RuntimeError as e:
        return out({"error": str(e)}, 2)
    print(__doc__, file=sys.stderr)
    return 64


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
