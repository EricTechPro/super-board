#!/usr/bin/env python3
"""Stop hook: a skill changed this session needs an eval run before the turn ends.

For repos that AUTHOR skills — this pack and EricOS. install.sh never copies hooks/dev/
into a target project.

Skills are prompts. Editing one with no eval is shipping a prompt change on vibes, and the
failure is silent: the skill stops firing, or fires on the wrong request, and nothing errors.

What counts as changed: files under a `skills/<name>/` folder (any depth, so `.agents/skills`,
`_skills/vendor/<pack>/skills`, `projects/*/skills` all match) that are uncommitted, untracked,
or committed but not yet pushed (ahead of the branch's upstream; with no upstream, ahead of
origin/HEAD, main or master). That last part covers a session that already committed. Then:

  - a changed SKILL.md always counts;
  - any other file (references/, scripts/, a plugin's workflows/<skill>*.js) counts only
    when the skill has an eval case.

Where eval cases live, and where `claude plugin eval` writes results:
  - per skill:   <skill>/evals/            results in <skill>/evals/results/
  - per plugin:  <plugin>/evals/<case>/case.yaml, next to <plugin>/skills/; a case belongs
                 to a skill when the skill's name is in its `tags` or `name`.
                 Results in <plugin>/evals/results/.
"Ran since" is an mtime comparison: newest result file vs newest changed file. No state file.

Verdicts:
  - covered skill, stale       -> exit 2 (blocks the stop; stderr tells Claude what to run)
  - skill with no eval case    -> warning only (systemMessage), never blocks
  - an eval already running    -> skipped (a run in flight is not a forgotten eval)
  - stop_hook_active (Claude is already continuing because of a stop hook) -> warning only,
    so the gate can never loop.

Escape valves: SKILL_EVAL_GATE=off for a session; `.claude/eval-gate-ignore` in the project
(one glob per line, matched against the skill folder path relative to the repo root, e.g.
`.agents/skills/firecrawl-*`). Fails open on anything unexpected.
"""
import fnmatch
import glob
import json
import os
import re
import subprocess
import sys

ENV = {k: v for k, v in os.environ.items() if not k.startswith("GIT_")}


def git(root, *args):
    try:
        r = subprocess.run(["git", "-C", root] + list(args), capture_output=True, text=True, env=ENV, timeout=20)
        return r.stdout if r.returncode == 0 else ""
    except (OSError, subprocess.TimeoutExpired):
        return ""


def changed_files(root):
    files = set()
    for line in git(root, "status", "--porcelain", "--untracked-files=all").splitlines():
        path = line[3:].split(" -> ")[-1].strip().strip('"')
        if path:
            files.add(path)
    base = "@{u}" if git(root, "rev-parse", "--abbrev-ref", "--symbolic-full-name", "@{u}").strip() else None
    if base is None:  # a local branch with no upstream: everything since it left the default branch
        head = git(root, "symbolic-ref", "--short", "-q", "HEAD").strip()
        for cand in (git(root, "symbolic-ref", "--short", "-q", "refs/remotes/origin/HEAD").strip(), "main", "master"):
            if cand and cand != head and git(root, "rev-parse", "--verify", "-q", cand).strip():
                base = cand
                break
    if base:
        files.update(p for p in git(root, "diff", "--name-only", base + "...HEAD").splitlines() if p)
    return files


SKILL_RE = re.compile(r"^(?P<skill>(?:.*/)?skills/(?P<name>[^/]+))/(?P<rest>.+)$")
WORKFLOW_RE = re.compile(r"^(?P<plugin>(?:.*/)?)workflows/(?P<stem>[^/]+)\.js$")


def plugin_cases(plugin_root, name):
    cases = []
    for case in glob.glob(os.path.join(plugin_root, "evals", "*", "case.yaml")):
        try:
            text = open(case, encoding="utf-8").read()
        except OSError:
            continue
        tags = re.search(r"^tags:\s*\[(.*?)\]", text, re.M)
        names = [t.strip().strip("'\"") for t in tags.group(1).split(",")] if tags else []
        m = re.search(r"^name:\s*(\S+)", text, re.M)
        if name in names or (m and m.group(1).strip("'\"") == name):
            cases.append(case)
    return cases


def newest(paths):
    best = 0.0
    for p in paths:
        try:
            best = max(best, os.path.getmtime(p))
        except OSError:
            pass
    return best


def files_under(d):
    out = []
    for base, _, names in os.walk(d):
        out += [os.path.join(base, n) for n in names]
    return out


def eval_in_flight(name):
    try:
        return subprocess.run(["pgrep", "-f", "plugin eval.*%s" % re.escape(name)],
                              capture_output=True, timeout=5).returncode == 0
    except (OSError, subprocess.TimeoutExpired):
        return False


def ignored(rel_skill, root):
    path = os.path.join(root, ".claude", "eval-gate-ignore")
    try:
        lines = open(path, encoding="utf-8").read().splitlines()
    except OSError:
        return False
    return any(fnmatch.fnmatch(rel_skill, g.strip()) for g in lines if g.strip() and not g.startswith("#"))


def assess(root):
    """(stale, uncovered): stale = [(rel_skill, run_hint)], uncovered = [rel_skill]."""
    skills = {}  # rel skill dir -> {"name", "skill_md": bool, "files": set}
    plugin_workflows = []
    for f in changed_files(root):
        m = SKILL_RE.match(f)
        if m and os.path.isfile(os.path.join(root, m.group("skill"), "SKILL.md")):
            if "/evals/" in "/" + m.group("rest"):
                continue  # authoring a case is eval work, not a skill change
            s = skills.setdefault(m.group("skill"), {"name": m.group("name"), "skill_md": False, "files": set()})
            s["skill_md"] |= m.group("rest") == "SKILL.md"
            s["files"].add(f)
            continue
        w = WORKFLOW_RE.match(f)
        if w and os.path.isdir(os.path.join(root, w.group("plugin"), "skills")):
            plugin_workflows.append((w.group("plugin"), w.group("stem"), f))
    for plugin, stem, f in plugin_workflows:
        names = [os.path.basename(os.path.dirname(p)) for p in glob.glob(os.path.join(root, plugin, "skills", "*", "SKILL.md"))]
        owner = max((n for n in names if stem == n or stem.startswith(n + "-")), key=len, default=None)
        if owner:
            rel = os.path.join(plugin, "skills", owner) if plugin else os.path.join("skills", owner)
            skills.setdefault(rel.rstrip("/"), {"name": owner, "skill_md": False, "files": set()})["files"].add(f)

    stale, uncovered = [], []
    for rel, s in sorted(skills.items()):
        if ignored(rel, root) or eval_in_flight(s["name"]):
            continue
        skill_dir = os.path.join(root, rel)
        plugin_root = os.path.dirname(os.path.dirname(skill_dir))
        own = os.path.isdir(os.path.join(skill_dir, "evals"))
        cases = plugin_cases(plugin_root, s["name"])
        if not own and not cases:
            if s["skill_md"]:
                uncovered.append(rel)
            continue
        results = files_under(os.path.join(skill_dir, "evals", "results")) if own else []
        if cases:
            results += files_under(os.path.join(plugin_root, "evals", "results"))
        if newest(results) > newest(os.path.join(root, f) for f in s["files"]):
            continue
        if own:
            hint = "claude plugin eval %s --threshold 0.8" % rel
        else:
            prel = os.path.relpath(plugin_root, root)
            hint = "cd %s && claude plugin eval . (see evals/README.md; cases: %s)" % (
                prel, ", ".join(os.path.basename(os.path.dirname(c)) for c in cases))
        stale.append((rel, hint))
    return stale, uncovered


def main():
    try:
        if os.environ.get("SKILL_EVAL_GATE", "on") == "off":
            return 0
        try:
            payload = json.loads(sys.stdin.read() or "{}")
        except ValueError:
            payload = {}
        start = os.environ.get("CLAUDE_PROJECT_DIR") or payload.get("cwd") or os.getcwd()
        root = git(start, "rev-parse", "--show-toplevel").strip()
        if not root:
            return 0
        stale, uncovered = assess(root)
        if not stale and not uncovered:
            return 0
        lines = []
        if stale:
            lines.append("Skill changes are not covered by a current eval run. Run before stopping:")
            lines += ["  %s  ->  %s" % (rel, hint) for rel, hint in stale]
            lines.append("Report pass rate and cost. SKILL_EVAL_GATE=off skips this gate for a session.")
        if uncovered:
            lines.append("SKILL.md changed with no eval case (warning only): " + ", ".join(uncovered))
        msg = "\n".join(lines)
        if stale and not payload.get("stop_hook_active"):
            print(msg, file=sys.stderr)
            return 2
        print(json.dumps({"systemMessage": msg}))
        return 0
    except Exception:
        return 0  # a broken gate must never brick the session


if __name__ == "__main__":
    sys.exit(main())
