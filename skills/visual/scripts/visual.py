#!/usr/bin/env python3
"""/visual helper: detect what to visualise, collect git facts, render the page.

    visual.py detect [--base REF]           # JSON: git state, plan candidates, suggested mode
    visual.py facts  [--base REF]           # JSON: recap facts (commits, files +/-, areas)
    visual.py render DATA.json [--out PATH] [--no-open]

Stdlib only. Run from anywhere inside the project being visualised.
"""

from __future__ import annotations

import argparse
import datetime as dt
import json
import os
import re
import subprocess
import sys
import time
from pathlib import Path

SKILL = Path(__file__).resolve().parents[1]
TEMPLATE = SKILL / "assets" / "template.html"
PLACEHOLDER = "/*__VISUAL_DATA__*/null"
PLAN_NAME = re.compile(r"(plan|prd|spec|design|rfc|proposal)", re.I)
MAX_HUNK_LINES = 80


def git(*args: str, cwd: Path | None = None, check: bool = True) -> str:
    r = subprocess.run(["git", *args], cwd=cwd, capture_output=True, text=True)
    if check and r.returncode != 0:
        raise RuntimeError(f"git {' '.join(args)}: {r.stderr.strip()}")
    return r.stdout if r.returncode == 0 else ""


def repo_root() -> Path | None:
    out = git("rev-parse", "--show-toplevel", check=False).strip()
    return Path(out) if out else None


def ref_exists(ref: str, root: Path) -> bool:
    return subprocess.run(["git", "rev-parse", "--verify", "--quiet", ref + "^{commit}"],
                          cwd=root, capture_output=True).returncode == 0


def default_base(root: Path) -> str | None:
    for ref in ("main", "master", "trunk", "develop"):
        if ref_exists(ref, root):
            return ref
    head = git("symbolic-ref", "--quiet", "refs/remotes/origin/HEAD", cwd=root, check=False).strip()
    return head.removeprefix("refs/remotes/") or None


def git_state(root: Path, base: str | None) -> dict:
    branch = git("rev-parse", "--abbrev-ref", "HEAD", cwd=root).strip()
    base = base or default_base(root)
    mb = git("merge-base", base, "HEAD", cwd=root, check=False).strip() if base else ""
    commits = []
    if mb:
        log = git("log", "--format=%h%x09%s", f"{mb}..HEAD", cwd=root, check=False)
        commits = [dict(zip(("sha", "subject"), l.split("\t", 1))) for l in log.splitlines() if l]
    dirty = [l for l in git("status", "--porcelain", cwd=root).splitlines() if l]
    changed = git("diff", "--name-only", mb, cwd=root, check=False).splitlines() if mb else []
    untracked = git("ls-files", "--others", "--exclude-standard", cwd=root).splitlines()
    return {"root": str(root), "branch": branch, "base": base, "mergeBase": mb[:12],
            "commitsAhead": len(commits), "commits": commits, "dirty": len(dirty),
            "changedFiles": len(set(changed) | set(untracked)) if mb else len(dirty),
            "onBase": branch == base}


def plan_candidates(root: Path | None) -> list[dict]:
    now = time.time()
    found: list[tuple[float, Path]] = []
    dirs = [Path.home() / ".claude" / "plans"]
    if root:
        dirs += [root, root / "docs", root / "plans", root / ".claude" / "plans", root / "specs"]
    for d in dirs:
        if not d.is_dir():
            continue
        for p in d.glob("*.md"):
            age = now - p.stat().st_mtime
            in_plans_dir = d.name == "plans"
            if (in_plans_dir and age < 86400) or (PLAN_NAME.search(p.stem) and age < 14 * 86400):
                found.append((p.stat().st_mtime, p))
    found.sort(reverse=True)
    return [{"path": str(p), "modified": dt.datetime.fromtimestamp(m).isoformat(timespec="minutes")}
            for m, p in found[:5]]


def cmd_detect(a) -> None:
    root = repo_root()
    out: dict = {"cwd": os.getcwd(), "git": git_state(root, a.base) if root else None,
                 "planCandidates": plan_candidates(root)}
    g = out["git"]
    if g and (g["commitsAhead"] or g["dirty"]) and g["changedFiles"]:
        out["suggested"] = "recap"
    elif out["planCandidates"]:
        out["suggested"] = "plan"
    else:
        out["suggested"] = "explore"
    print(json.dumps(out, indent=2))


def area_of(path: str, areas: dict[str, str]) -> tuple[str, str]:
    """(group label, path prefix the row may drop) for one file."""
    for prefix in sorted(areas, key=len, reverse=True):
        if path.startswith(prefix):
            return areas[prefix], prefix
    parts = path.split("/")[:-1]
    prefix = "/".join(parts[:3])
    return prefix or "(root)", prefix + "/" if prefix else ""


def collect_files(root: Path, mb: str, areas: dict[str, str]) -> list[dict]:
    status = {}
    for line in git("diff", "--name-status", "-M", mb, cwd=root).splitlines():
        bits = line.split("\t")
        status[bits[-1]] = {"status": bits[0][0], "from": bits[1] if bits[0][0] == "R" else None}
    files = []
    for line in git("diff", "--numstat", "-M", mb, cwd=root).splitlines():
        add, dele, path = line.split("\t", 2)
        if " => " in path:  # rename: a/{x => y}/b or x => y
            path = re.sub(r"\{([^{}]*) => ([^{}]*)\}", r"\2", path)
            path = path.split(" => ")[-1].replace("//", "/")
        st = status.get(path, {"status": "M", "from": None})
        files.append({"path": path, "add": int(add) if add != "-" else 0,
                      "del": int(dele) if dele != "-" else 0, "status": st["status"],
                      "from": st["from"], "binary": add == "-"})
    for path in git("ls-files", "--others", "--exclude-standard", cwd=root).splitlines():
        p = root / path
        try:
            n = len(p.read_text(encoding="utf8").splitlines())
        except (UnicodeDecodeError, OSError):
            n = 0
        files.append({"path": path, "add": n, "del": 0, "status": "A", "from": None,
                      "untracked": True})
    for f in files:
        f["area"], f["prefix"] = area_of(f["path"], areas)
    return sorted(files, key=lambda f: (f["area"], f["path"]))


def cmd_facts(a) -> None:
    root = repo_root()
    if not root:
        sys.exit("not inside a git repository")
    print(json.dumps(recap_facts(root, a.base, {}), indent=2))


def recap_facts(root: Path, base: str | None, areas: dict[str, str]) -> dict:
    g = git_state(root, base)
    if not g["mergeBase"]:
        raise SystemExit(f"no merge-base between HEAD and {g['base']!r}; pass --base")
    mb = git("merge-base", g["base"], "HEAD", cwd=root).strip()
    files = collect_files(root, mb, areas)
    g["files"] = files
    g["stats"] = {"files": len(files), "add": sum(f["add"] for f in files),
                  "del": sum(f["del"] for f in files), "commits": g["commitsAhead"]}
    return g


# ---------- hunks ----------

def parse_hunks(diff: str) -> list[dict]:
    hunks, cur, old, new = [], None, 0, 0
    for line in diff.splitlines():
        m = re.match(r"@@ -(\d+)(?:,\d+)? \+(\d+)(?:,\d+)? @@(.*)", line)
        if m:
            old, new = int(m[1]), int(m[2])
            cur = {"header": line, "context": m[3].strip(), "lines": []}
            hunks.append(cur)
            continue
        if cur is None or line.startswith("\\"):
            continue
        sign = line[:1] or " "
        if sign == "+":
            cur["lines"].append({"t": "+", "n": new, "s": line[1:]}); new += 1
        elif sign == "-":
            cur["lines"].append({"t": "-", "o": old, "s": line[1:]}); old += 1
        else:
            cur["lines"].append({"t": " ", "o": old, "n": new, "s": line[1:]}); old += 1; new += 1
    return hunks


def file_diff(root: Path, mb: str, path: str) -> str:
    out = git("diff", "-U3", mb, "--", path, cwd=root, check=False)
    if out.strip():
        return out
    p = root / path  # untracked: whole file is the hunk
    if p.is_file():
        return git("diff", "--no-index", "-U3", "/dev/null", str(p), cwd=root, check=False)
    return ""


def resolve_hunk(root: Path, mb: str, h: dict) -> dict:
    if h.get("lines"):
        return h
    hunks = parse_hunks(file_diff(root, mb, h["file"]))
    if not hunks:
        return {**h, "lines": [], "missing": True}
    want = h.get("contains")
    picked = [x for x in hunks if want and any(want in l["s"] for l in x["lines"])] if want else []
    chosen = picked[0] if picked else hunks[int(h.get("hunk", 0)) % len(hunks)]
    lines = chosen["lines"]
    if want and picked:  # centre the window on the first match
        idx = next(i for i, l in enumerate(lines) if want in l["s"])
        start = max(0, idx - 3)
        lines = lines[start:start + int(h.get("maxLines", MAX_HUNK_LINES))]
    else:
        lines = lines[: int(h.get("maxLines", MAX_HUNK_LINES))]
    for note in h.get("notes", []):
        m = note.get("match")
        note["at"] = next((i for i, l in enumerate(lines) if m and m in l["s"]), None)
    return {**h, "header": chosen["header"], "lines": lines,
            "truncated": len(lines) < len(chosen["lines"]), "hunkCount": len(hunks)}


# ---------- render ----------

def slug(s: str) -> str:
    return re.sub(r"[^a-z0-9]+", "-", s.lower()).strip("-")[:60] or "visual"


def output_path(root: Path, data: dict) -> Path:
    name = f"{slug(data.get('slug') or data.get('title', 'visual'))}-{data.get('kind', 'explore')}.html"
    tmp = root / "_tmp"
    # A repo with a gitignored _tmp/ (EricOS convention) keeps disposable output there.
    if subprocess.run(["git", "check-ignore", "-q", "_tmp/visual.html"], cwd=root,
                      capture_output=True).returncode == 0:
        d = tmp / f"{dt.date.today().isoformat()}-visual"
    else:
        d = root / ".visual"
        d.mkdir(exist_ok=True)
        gi = d / ".gitignore"
        if not gi.exists():
            gi.write_text("*\n")
    d.mkdir(parents=True, exist_ok=True)
    return d / name


def cmd_render(a) -> None:
    data = json.loads(Path(a.data).read_text(encoding="utf8"))
    root = repo_root() or Path.cwd()
    kind = data.setdefault("kind", "explore")
    if kind == "recap" and repo_root():
        facts = recap_facts(root, data.get("base"), data.get("areas", {}))
        notes = data.get("fileNotes", {})
        if not data.get("files"):
            data["files"] = facts["files"]
        for f in data["files"]:
            f.setdefault("note", notes.get(f["path"]))
        data.setdefault("stats", facts["stats"])
        data.setdefault("meta", {}).update({k: facts[k] for k in ("branch", "base", "commits")})
        mb = git("merge-base", facts["base"], "HEAD", cwd=root).strip()
        data["hunks"] = [resolve_hunk(root, mb, h) for h in data.get("hunks", [])]
    for f in data.get("files", []):
        if "area" not in f:
            f["area"], f["prefix"] = area_of(f["path"], data.get("areas", {}))
    data.setdefault("meta", {})["generated"] = dt.datetime.now().isoformat(timespec="minutes")
    data["meta"].setdefault("project", root.name)

    blob = json.dumps(data, ensure_ascii=False).replace("</", "<\\/")
    html = TEMPLATE.read_text(encoding="utf8")
    if PLACEHOLDER not in html:
        sys.exit("template placeholder missing")
    html = html.replace(PLACEHOLDER, blob).replace("__VISUAL_TITLE__", escape(data.get("title", "Visual")))
    out = Path(a.out) if a.out else output_path(root, data)
    out.parent.mkdir(parents=True, exist_ok=True)
    out.write_text(html, encoding="utf8")
    missing = [h["file"] for h in data.get("hunks", []) if h.get("missing")]
    print(json.dumps({"out": str(out.resolve()), "missingHunks": missing}))
    if not a.no_open:
        opener = "open" if sys.platform == "darwin" else "xdg-open"
        subprocess.run([opener, str(out)], capture_output=True)


def escape(s: str) -> str:
    return s.replace("&", "&amp;").replace("<", "&lt;").replace(">", "&gt;")


def main() -> None:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = ap.add_subparsers(dest="cmd", required=True)
    for name in ("detect", "facts"):
        p = sub.add_parser(name)
        p.add_argument("--base")
    r = sub.add_parser("render")
    r.add_argument("data")
    r.add_argument("--out")
    r.add_argument("--no-open", action="store_true")
    a = ap.parse_args()
    {"detect": cmd_detect, "facts": cmd_facts, "render": cmd_render}[a.cmd](a)


if __name__ == "__main__":
    main()
