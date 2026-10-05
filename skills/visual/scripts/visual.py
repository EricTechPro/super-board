#!/usr/bin/env python3
"""/visual helper: detect what to visualise, collect git facts, render the page.

    visual.py detect [--base REF]           # JSON: git state, plan candidates, suggested mode
    visual.py facts  [--base REF]           # JSON: recap facts (commits, files +/-, areas)
    visual.py render DATA.json [--out PATH] [--no-open] [--no-check]
    visual.py render --map MAP.json [--out PATH] [--no-open] [--no-check]
                     [--source-base URL [--source-root DIR]]   # link sources to e.g. GitHub blob URLs
    visual.py skillmap SKILLS_DIR [--out MAP.json]   # skeleton view model of a skill pack
    visual.py check PAGE.html [--shots DIR]          # headless Chrome: light+dark shots, label overlaps

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


def portable_path(p, root: Path) -> str:
    """A path safe to publish: repo-relative inside `root`, `~/…` under home, else the bare name.
    Never leaks a machine-local absolute path (user name, worktree, tmp dir) into a page."""
    if not p:
        return ""
    p = Path(p)
    if not p.is_absolute():
        return p.as_posix()
    for base, prefix in ((root, ""), (Path.home(), "~/")):
        try:
            return prefix + p.resolve().relative_to(Path(base).resolve()).as_posix()
        except ValueError:
            pass
    return p.name


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
    if a.map:
        data = load_map(Path(a.map))
    elif a.data:
        data = json.loads(Path(a.data).read_text(encoding="utf8"))
    else:
        sys.exit("render needs DATA.json or --map MAP.json")
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
    if kind == "map":
        data["avatarsEmbedded"] = embed_avatars(data)
        problems = validate_map(data)
        if problems:
            sys.exit("map model problems:\n  " + "\n  ".join(problems))
    data.setdefault("meta", {})["generated"] = dt.datetime.now().isoformat(timespec="minutes")
    data["meta"].setdefault("project", root.name)
    abs_root = Path(data.pop("_root", None) or root)
    out = Path(a.out) if a.out else output_path(root, data)
    if getattr(a, "source_base", None):
        link_sources(data, abs_root, Path(a.source_root).resolve() if a.source_root else abs_root, a.source_base)
    # repo root relative to the page, so source links resolve wherever the repo is checked out
    data["meta"].setdefault("root", Path(os.path.relpath(abs_root.resolve(), out.resolve().parent)).as_posix())

    out.parent.mkdir(parents=True, exist_ok=True)
    write_page(out, data)
    baked = 0
    if kind == "map" and not a.no_optimize and find_chrome():
        # bake: let the page search for crossing-free row orders once, then freeze them as view layouts
        layouts = page_layouts(out.resolve())
        for v in data.get("views", []):
            if not v.get("layout") and v.get("id") in layouts:
                v["layout"] = layouts[v["id"]]
                baked += 1
        if baked:
            write_page(out, data)
    missing = [h["file"] for h in data.get("hunks", []) if h.get("missing")]
    result: dict = {"out": str(out.resolve()), "bytes": out.stat().st_size, "missingHunks": missing}
    if kind == "map":
        result["bakedLayouts"] = baked
    if not a.no_check:
        result["check"] = run_check(out.resolve(), Path(a.shots) if a.shots else None, kind == "map")
    print(json.dumps(result, indent=2))
    if not a.no_open:
        opener = "open" if sys.platform == "darwin" else "xdg-open"
        subprocess.run([opener, str(out)], capture_output=True)
    if result.get("check", {}).get("overlaps"):
        sys.exit(2)


def link_sources(data: dict, repo: Path, src_root: Path, base: str) -> int:
    """--source-base: rewrite each node `source` under `src_root` into `base + <path from src_root>`
    (`file:12-20` → `#L12-L20`), so a page published away from the checkout (GitHub Pages) links to
    the hosted file. Sources outside `src_root` keep their text and get no link. Returns the count."""
    from urllib.parse import quote
    base = base.rstrip("/") + "/"
    prefix = (data.get("sourcesBase") or "").strip("/")

    def one(s):
        if not isinstance(s, str) or not s or re.match(r"https?:", s) or s.startswith("~"):
            return s, 0
        m = re.match(r"(.*?)(?::(\d+)(?:-(\d+))?)?$", s)
        path, a, b = m[1], m[2], m[3]
        full = (repo / prefix / path).resolve()
        try:
            rel = full.relative_to(src_root).as_posix()
        except ValueError:
            return s, 0
        anchor = f"#L{a}" + (f"-L{b}" if b else "") if a else ""
        return base + quote(rel) + anchor, 1

    n = 0
    all_nodes = [*data.get("nodes", []), *(n for v in data.get("views", []) for n in v.get("nodes", [])),
                 *(n for v in data.get("views", []) for n in v.get("nodeOverrides", {}).values())]
    for node in all_nodes:
        src = node.get("source")
        if isinstance(src, list):
            pairs = [one(s) for s in src]
            node["source"] = [p for p, _ in pairs]
            n += sum(c for _, c in pairs)
        elif src:
            node["source"], c = one(src)
            n += c
    if isinstance(data.get("source"), str) and not data["source"].startswith("~"):
        try:
            data["source"] = (repo / data["source"]).resolve().relative_to(src_root).as_posix()
        except ValueError:
            pass
    data["sourcesBase"] = ""
    data.setdefault("meta", {})["sourceBase"] = base
    data["meta"]["root"] = ""  # links are absolute now; don't publish the checkout's folder depth
    data["meta"]["project"] = data.get("meta", {}).get("project") if src_root == repo else src_root.name
    return n


def write_page(out: Path, data: dict) -> None:
    blob = json.dumps(data, ensure_ascii=False).replace("</", "<\\/")
    html = TEMPLATE.read_text(encoding="utf8")
    if PLACEHOLDER not in html:
        sys.exit("template placeholder missing")
    html = html.replace(PLACEHOLDER, blob).replace("__VISUAL_TITLE__", escape(data.get("title", "Visual")))
    out.write_text(html, encoding="utf8")


def page_layouts(page: Path) -> dict:
    binary = find_chrome()
    dom = chrome(binary, "--virtual-time-budget=6000", "--window-size=1440,900", "--dump-dom",
                 page.as_uri() + "#check=1&optimize=1", done=lambda t: "</html>" in t, timeout=600)
    m = re.search(r'<pre id="visual-check"[^>]*>(.*?)</pre>', dom, re.S)
    if not m:
        return {}
    import html as _html
    return json.loads(_html.unescape(m[1])).get("layouts") or {}


# ---------- map: view-based skill / architecture model ----------

MAP_KINDS = {"public", "lane", "external", "verb", "script", "hook", "board"}


def load_map(path: Path) -> dict:
    model = json.loads(path.read_text(encoding="utf8"))
    data = dict(model)
    data["kind"] = "map"
    views = model.get("views") or []
    root_view = next((v for v in views if not v.get("parent")), views[0] if views else {})
    data.setdefault("title", model.get("title") or root_view.get("title") or path.stem)
    top = subprocess.run(["git", "rev-parse", "--show-toplevel"], cwd=path.resolve().parent,
                         capture_output=True, text=True).stdout.strip()
    data["_root"] = top or str(path.resolve().parent)
    data.setdefault("source", portable_path(path.resolve(), Path(data["_root"])))
    embed_logos(data, path.resolve().parent)
    return data


def embed_logos(d: dict, base: Path) -> int:
    """Inline each view's intake `logo` (an SVG path relative to the map file), so the page works offline."""
    import base64
    n = 0
    for v in d.get("views", []):
        for src in v.get("intake", []):
            logo = src.get("logo")
            if logo and not str(logo).startswith("data:") and (base / logo).is_file():
                src["logo"] = "data:image/svg+xml;base64," + base64.b64encode((base / logo).read_bytes()).decode()
                n += 1
    return n


def embed_avatars(d: dict) -> int:
    """Fetch each author's GitHub avatar once (cached, 96 px for the 26 px name-tag headshot on 2x screens)
    and inline it, so the page works offline."""
    import base64
    import urllib.request
    cache = Path.home() / ".cache" / "visual" / "avatars"
    cache.mkdir(parents=True, exist_ok=True)
    n = 0
    for login, a in (d.get("authors") or {}).items():
        if not isinstance(a, dict) or str(a.get("avatar", "")).startswith("data:"):
            continue
        f = cache / f"{re.sub(r'[^A-Za-z0-9_.-]', '_', login)}@96.png"
        if not f.exists() or f.stat().st_size < 100:
            try:
                req = urllib.request.Request(f"https://github.com/{login}.png?size=96", headers={"User-Agent": "visual.py"})
                with urllib.request.urlopen(req, timeout=10) as r:
                    f.write_bytes(r.read())
            except Exception:
                continue  # the page falls back to an initials badge
        data = f.read_bytes()
        mime = "image/jpeg" if data[:3] == b"\xff\xd8\xff" else "image/png"
        a["avatar"] = f"data:{mime};base64," + base64.b64encode(data).decode()
        n += 1
    return n


def validate_map(d: dict) -> list[str]:
    """Hard errors only: dangling ids would render as holes."""
    all_nodes = [*d.get("nodes", []), *(n for v in d.get("views", []) for n in v.get("nodes", []))]
    ids = {n.get("id") for n in all_nodes}
    vids = {v.get("id") for v in d.get("views", [])}
    out = []
    seen = set()
    for n in all_nodes:
        nid = n.get("id")
        if not nid or nid in seen:
            out.append(f"missing or duplicate node id {nid!r}")
        seen.add(nid)
        if n.get("opensView") and n["opensView"] not in vids:
            out.append(f"node {nid!r}: opens unknown view {n['opensView']!r}")
    if not d.get("views"):
        out.append("no views")
    for v in d.get("views", []):
        if v.get("parent") and v["parent"] not in vids and v["parent"] not in ids:
            out.append(f"view {v.get('id')!r}: parent {v['parent']!r} is not a view")
        for nid, override in v.get("nodeOverrides", {}).items():
            if nid not in ids:
                out.append(f"view {v.get('id')!r}: overrides unknown node {nid!r}")
            if override.get("opensView") and override["opensView"] not in vids:
                out.append(f"view {v.get('id')!r}: override opens unknown view {override['opensView']!r}")
        for i in v.get("nodeIds", []):
            if i not in ids:
                out.append(f"view {v.get('id')!r}: unknown node {i!r}")
        members = set(v.get("nodeIds", []))
        for i in v.get("stepIds", []):
            if i not in members:
                out.append(f"view {v.get('id')!r}: main step {i!r} is not in nodeIds")
        for i in v.get("browserOrder", []):
            if i not in vids:
                out.append(f"view {v.get('id')!r}: browser opens unknown view {i!r}")
        families = {f.get("id"): f for f in v.get("containers", [])}
        if None in families or len(families) != len(v.get("containers", [])):
            out.append(f"view {v.get('id')!r}: missing or duplicate container id")
        for fid, family in families.items():
            for i in family.get("nodeIds", []):
                if i not in members:
                    out.append(f"view {v.get('id')!r}: container {fid!r} includes non-visible node {i!r}")
            trail, cursor = set(), fid
            while cursor:
                if cursor in trail:
                    out.append(f"view {v.get('id')!r}: cyclic container {fid!r}")
                    break
                trail.add(cursor)
                if cursor not in families:
                    out.append(f"view {v.get('id')!r}: container {fid!r} has unknown parent {cursor!r}")
                    break
                cursor = families[cursor].get("parent")
        for src in v.get("intake", []):
            if src.get("to") not in members:
                out.append(f"view {v.get('id')!r}: intake {src.get('label')!r} feeds non-visible node {src.get('to')!r}")
        for i in v.get("tour", []):
            if i not in members:
                out.append(f"view {v.get('id')!r}: tour stop {i!r} is not in nodeIds")
        for e in v.get("edges", []) or []:
            if isinstance(e, dict) and (e.get("from") not in ids or e.get("to") not in ids):
                out.append(f"view {v.get('id')!r}: edge {e.get('from')}->{e.get('to')} has an unknown end")
    for e in d.get("edges", []):
        if e.get("from") not in ids or e.get("to") not in ids:
            out.append(f"edge {e.get('from')}->{e.get('to')} has an unknown end")
    return out[:40]


FM = re.compile(r"^---\n(.*?)\n---\n", re.S)


def frontmatter(text: str) -> dict:
    """Tiny YAML subset: `key: value`, `key: >-` folded blocks, quoted scalars."""
    m = FM.match(text)
    out: dict = {}
    if not m:
        return out
    key = None
    for line in m[1].splitlines():
        kv = re.match(r"^([A-Za-z][\w-]*):\s*(.*)$", line)
        if kv:
            key, val = kv[1], kv[2].strip()
            out[key] = "" if val in (">-", ">", "|", "|-") else val.strip("\"'")
        elif key and line.startswith((" ", "\t")):
            out[key] = (out[key] + " " + line.strip()).strip()
    return out


def first_sentence(s: str) -> str:
    s = re.split(r"(?<=[.!?])\s+(?=[A-Z])", s.strip(), maxsplit=1)[0]
    return s.strip()


def cmd_skillmap(a) -> None:
    sk = Path(a.skills_dir).resolve()
    top = subprocess.run(["git", "rev-parse", "--show-toplevel"], cwd=sk, capture_output=True,
                         text=True).stdout.strip()
    top_p = Path(top) if top else sk.parent
    pack = sk.parent
    rel = lambda p: os.path.relpath(p, top_p)
    fam = {}
    fpath = sk / "families.json"
    if fpath.is_file():
        for group in json.loads(fpath.read_text()).values():
            for name, blurb in (group.get("skills") or {}).items():
                fam[name] = blurb
    skills = {}
    for md in sorted(sk.glob("*/SKILL.md")):
        text = md.read_text(encoding="utf8")
        fm = frontmatter(text)
        name = fm.get("name") or md.parent.name
        skills[name] = {"dir": md.parent, "md": md, "text": text, "fm": fm}
    # skills installed beside the pack's host repo count as known dependencies
    ext_md: dict[str, Path] = {}  # name -> SKILL.md of skills installed beside the pack
    for d in (top_p / ".agents" / "skills", top_p / ".claude" / "skills", Path.home() / ".claude" / "skills"):
        if d.is_dir():
            for p in sorted(d.glob("*/SKILL.md")):
                ext_md.setdefault(p.parent.name, p.resolve())
    plugins = Path.home() / ".claude" / "plugins"
    if plugins.is_dir():  # plugin skills: <plugins>/**/skills/<name>/SKILL.md
        for p in sorted(plugins.glob("**/skills/*/SKILL.md")):
            ext_md.setdefault(p.parent.name, p.resolve())
    known_ext = set(ext_md)

    def origin(name: str) -> str:
        p = str(ext_md.get(name, ""))
        m = re.search(r"/plugins/(?:cache/)?([^/]+)/", p)
        if m:
            return m[1] + " plugin"
        m = re.search(r"/vendor/([^/]+)/", p)
        return m[1] if m else ("~/.claude/skills" if p.startswith(str(Path.home() / ".claude")) else "repo skills")

    def ext_mentions(text: str, own: str) -> set[str]:
        found = {d.split(":", 1)[1] for d in re.findall(r"`([a-z][\w-]*:[a-z][\w-]*)`", text)}
        found |= set(re.findall(r"`/?([a-z][a-z0-9-]+)`", text)) | set(re.findall(r"(?<![\w/])/([a-z][a-z0-9-]+)\b", text))
        return {w for w in found if w in known_ext and w != own and w not in skills}
    nodes, edges, views = {}, [], []

    def add_node(n):
        nodes.setdefault(n["id"], n)
        return n["id"]

    def edge(f, t, label, when=""):
        if f != t and not any(e["from"] == f and e["to"] == t for e in edges):
            edges.append({"from": f, "to": t, "label": label, "when": when})

    def add_ext(n: str) -> str:
        did = "dep:" + n
        if did not in nodes:
            md = ext_md.get(n)
            fm = frontmatter(md.read_text(encoding="utf8")) if md else {}
            desc = fm.get("description", "")
            when = re.search(r"\bUse (?:it )?when (.*)$", desc, re.S)
            add_node({"id": did, "label": n, "kind": "external", "external": True, "origin": origin(n), "verbs": [],
                      "what": first_sentence(desc), "when": ("Use when " + when[1].strip()) if when else "",
                      "how": "", "source": portable_path(md, top_p)})
        return did

    script_re = re.compile(r"(?<![\w/.-])((?:scripts|workflows|bin)/[\w.-]+\.(?:sh|py|js|mjs))")
    for name, s in skills.items():
        desc = s["fm"].get("description", "")
        when = re.search(r"\bUse (?:it )?when (.*)$", desc, re.S)
        blurb = fam.get(name, "")
        kind = "lane" if re.search(r"\blane\b", blurb, re.I) else "public"
        verbs = []
        for m in re.finditer(r"`/?%s ([a-z][a-z-]+)" % re.escape(name), s["text"]):
            if m[1] not in verbs:
                verbs.append(m[1])
        body = FM.sub("", s["text"])
        para = next((p.strip() for p in re.split(r"\n\s*\n", body)
                     if p.strip() and not p.lstrip().startswith(("#", "|", "-", "```", ">"))), "")
        add_node({"id": name, "label": name if kind == "lane" else "/" + name, "kind": kind,
                  "verbs": verbs, "what": blurb or first_sentence(desc),
                  "when": ("Use when " + when[1].strip()) if when else "",
                  "how": re.sub(r"\s+", " ", para)[:400], "source": rel(s["md"])})
        for v in verbs:
            vid = f"{name}:{v}"
            lines = [l for l in s["text"].splitlines() if re.search(r"`/?%s %s\b" % (re.escape(name), v), l)]
            row = next((l for l in lines if l.lstrip().startswith("|")), lines[0] if lines else "")
            cells = [c.strip() for c in row.strip().strip("|").split("|")] if row.lstrip().startswith("|") else []
            what = cells[-1] if cells else ""
            add_node({"id": vid, "label": f"/{name} {v}", "kind": "public", "verbs": [],
                      "what": re.sub(r"`", "", what)[:300], "when": f"User runs `/{name} {v}`",
                      "how": "", "source": rel(s["md"])})
            edge(name, vid, "verb")
    # mentions: skills, scripts, external skill deps
    for name, s in skills.items():
        text = FM.sub("", s["text"])
        for other in skills:
            if other != name and re.search(r"(?:`/?%s`|/%s\b)" % (re.escape(other), re.escape(other)), text):
                edge(name, other, "invokes")
        for m in sorted(set(script_re.findall(text))):
            base = m.split("/", 1)[1]
            cand = [s["dir"] / m, pack / m, *(pack / "skills").glob(f"*/scripts/{base}")]
            hit = next((c for c in cand if c.is_file()), None)
            sid = "script:" + base
            add_node({"id": sid, "label": base, "kind": "script", "verbs": [],
                      "what": "", "when": f"Run by {name}", "how": "",
                      "source": rel(hit) if hit else m})
            edge(name, sid, "runs")
        deps = {d for d in re.findall(r"`([a-z][\w-]*:[a-z][\w-]*)`", text)
                if d.split(":", 1)[1] in known_ext and d.split(":", 1)[1] not in skills}
        deps |= {w for w in re.findall(r"`/?([a-z][a-z0-9-]+)`", text) if w in known_ext and w not in skills}
        for d in sorted(deps):
            did = "dep:" + d.split(":", 1)[-1]
            add_ext(d.split(":", 1)[-1])
            edge(name, did, "uses")
    # board
    board_users = [n for n, s in skills.items() if re.search(r"GitHub Project", s["text"])]
    if board_users:
        add_node({"id": "board", "label": "GitHub Project", "kind": "board", "verbs": [],
                  "what": "The Project board: cards move Backlog → Ready → Build → QA → Review → Done.",
                  "when": "Read and written by every lane", "how": "", "source": ""})
        for n in board_users:
            edge(n, "board", "moves cards")
    # verb mentions of lanes → verb view edges
    for name, s in skills.items():
        for v in nodes[name]["verbs"]:
            vid = f"{name}:{v}"
            chunk = "\n".join(l for l in s["text"].splitlines() if re.search(r"\b%s %s\b" % (re.escape(name), v), l))
            for ref in sorted(set(re.findall(r"references/[\w.-]+\.md", chunk))):  # follow the verb's routed reference
                rp = s["dir"] / ref
                if rp.is_file():
                    chunk += "\n" + rp.read_text(encoding="utf8")
            for other in skills:
                if other != name and re.search(r"\b%s\b" % re.escape(other), chunk):
                    edge(vid, other, "dispatches")
            for m in sorted(set(script_re.findall(chunk))):
                if "script:" + m.split("/", 1)[1] in nodes:
                    edge(vid, "script:" + m.split("/", 1)[1], "runs")
    # hooks
    snip = pack / "hooks" / "settings-snippet.json"
    hook_ids = []
    if snip.is_file():
        cfg = json.loads(snip.read_text()).get("hooks", {})
        for event, groups in cfg.items():
            eid = "event:" + event
            add_node({"id": eid, "label": event, "kind": "hook", "verbs": [],
                      "what": f"Claude Code {event} event", "when": "Every matching tool call",
                      "how": "", "source": rel(snip)})
            hook_ids.append(eid)
            for g in groups:
                for h in g.get("hooks", []):
                    script = re.search(r"([\w.-]+\.py)", h.get("command", ""))
                    if not script:
                        continue
                    hid = "hook:" + script[1]
                    hp = pack / "hooks" / script[1]
                    add_node({"id": hid, "label": script[1], "kind": "hook", "verbs": [],
                              "what": "", "when": "", "how": "", "source": rel(hp) if hp.is_file() else ""})
                    w = nodes[hid]["when"]
                    tag = f"{event}: {g.get('matcher', '*')}"
                    nodes[hid]["when"] = f"{w}; {tag}" if w else tag
                    if hid not in hook_ids:
                        hook_ids.append(hid)
                    edge(eid, hid, g.get("matcher", "*")[:18], tag)
    # views: overview → per-skill → per-verb; hooks view
    top_ids = [n for n in skills] + (["board"] if "board" in nodes else [])
    pack_name = pack.name
    views.append({"id": "overview", "parent": None, "title": pack_name,
                  "nodeIds": top_ids + (["hooks"] if hook_ids else [])})
    if hook_ids:
        add_node({"id": "hooks", "label": "Guard hooks", "kind": "hook", "verbs": [],
                  "what": f"{len([h for h in hook_ids if h.startswith('hook:')])} guard scripts wired into settings.json",
                  "when": "Installed by install.sh unless --no-hooks", "how": "", "source": rel(snip)})
        views.append({"id": "hooks", "parent": "overview", "title": "Guard hooks", "nodeIds": hook_ids})
    for name in skills:
        out_ids = [e["to"] for e in edges if e["from"] == name]
        if not out_ids:
            continue
        views.append({"id": name, "parent": "overview", "title": nodes[name]["label"],
                      "nodeIds": [name] + out_ids, "star": name})
        for v in nodes[name]["verbs"]:
            vid = f"{name}:{v}"
            kids = [e["to"] for e in edges if e["from"] == vid]
            if kids:
                views.append({"id": vid, "parent": name, "title": f"/{name} {v}", "nodeIds": [vid] + kids, "star": vid})
    vid_set = {v["id"] for v in views}
    for v in views:  # view edges: every model edge whose ends are both on the view
        ids = set(v["nodeIds"])
        v["edges"] = [e for e in edges if e["from"] in ids and e["to"] in ids
                      and (not v.get("star") or e["from"] == v["star"])]  # a skill's view shows what it triggers
        v.pop("star", None)
    if getattr(a, "deep", False):  # external skills open onto the skills they trigger, as deep as the files go
        queue = [i[4:] for i in nodes if i.startswith("dep:")]
        seen = set()
        while queue:
            n = queue.pop(0)
            if n in seen or n not in ext_md:
                continue
            seen.add(n)
            kids = sorted(ext_mentions(FM.sub("", ext_md[n].read_text(encoding="utf8")), n))
            if not kids:
                continue
            for k in kids:
                add_ext(k)
                edge("dep:" + n, "dep:" + k, "triggers")
                queue.append(k)
            parent = next((v["id"] for v in views if "dep:" + n in v["nodeIds"]), "overview")
            ids = ["dep:" + n] + ["dep:" + k for k in kids]
            views.append({"id": "dep:" + n, "parent": parent, "title": n, "nodeIds": ids,
                          "edges": [e for e in edges if e["from"] == "dep:" + n and e["to"] in ids]})
    model = {"title": f"{pack_name} skill map", "subtitle": "Skeleton generated by visual.py skillmap — enrich what/when/how",
             "nodes": list(nodes.values()), "edges": edges, "views": views}
    text = json.dumps(model, indent=2, ensure_ascii=False)
    if a.out:
        Path(a.out).parent.mkdir(parents=True, exist_ok=True)
        Path(a.out).write_text(text + "\n", encoding="utf8")
        print(json.dumps({"out": str(Path(a.out).resolve()), "nodes": len(nodes), "edges": len(edges),
                          "views": len(views)}))
    else:
        print(text)


# ---------- check: headless Chrome screenshots + label overlap ----------

CHROME_CANDIDATES = [
    "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome",
    "/Applications/Chromium.app/Contents/MacOS/Chromium",
    "google-chrome", "chromium", "chromium-browser",
]


def find_chrome() -> str | None:
    import shutil
    for c in CHROME_CANDIDATES:
        if os.path.isfile(c) or shutil.which(c):
            return c
    return None


def chrome(binary: str, *args: str, done=None, timeout: int = 45) -> str:
    """Run headless Chrome and return stdout. Headless Chrome on macOS can linger after it has
    written its output, so poll for `done(stdout_text)` and stop it ourselves."""
    import shutil
    import tempfile
    # Chrome subprocesses can still write to the profile after the parent exits.
    prof = tempfile.mkdtemp()
    try:
        with tempfile.TemporaryFile("w+") as out:
            proc = subprocess.Popen([binary, "--headless", "--disable-gpu", "--hide-scrollbars",
                                     "--no-first-run", "--no-default-browser-check", "--mute-audio",
                                     f"--user-data-dir={prof}", *args],
                                    stdout=out, stderr=subprocess.DEVNULL, text=True)
            t0, text = time.time(), ""
            while time.time() - t0 < timeout:
                if proc.poll() is not None:
                    break
                out.seek(0)
                text = out.read()
                if done and done(text):
                    time.sleep(0.3)
                    break
                time.sleep(0.25)
            if proc.poll() is None:
                proc.kill()
                proc.wait()
            out.seek(0)
            return out.read()
    finally:
        # Python 3.9 has no TemporaryDirectory(ignore_cleanup_errors=...).
        # Retry late profile writes briefly; cleanup must never hide Chrome's result/error.
        for attempt in range(3):
            shutil.rmtree(prof, onerror=lambda *_: None)
            if not os.path.exists(prof):
                break
            if attempt < 2:
                time.sleep(0.1)



def run_check(page: Path, shots: Path | None, is_map: bool) -> dict:
    binary = find_chrome()
    if not binary:
        return {"skipped": "no Chrome/Chromium found"}
    url = page.as_uri()
    dom = chrome(binary, "--virtual-time-budget=6000", "--window-size=1440,900", "--dump-dom",
                 url + "#check=1&theme=dark", done=lambda t: "</html>" in t)
    m = re.search(r'<pre id="visual-check"[^>]*>(.*?)</pre>', dom, re.S)
    report = {}
    if m:
        import html as _html
        report = json.loads(_html.unescape(m[1]))
    else:
        report = {"error": "page did not report (JS error or no diagrams?)"}
    shots = shots or page.parent / f".{page.stem}-check"
    shots.mkdir(parents=True, exist_ok=True)
    size = "1440,900" if is_map else "1400,2600"
    taken = []
    plan = [("light", "theme=light"), ("dark", "theme=dark")]
    if is_map and report.get("childView"):
        plan.append(("drill-dark", f"theme=dark&view={report['childView']}"))
    if is_map and report.get("laneView"):
        plan.append(("lanes-light", f"theme=light&view={report['laneView']}"))
    for name, frag in plan:
        png = shots / f"{name}.png"
        if png.exists():
            png.unlink()
        chrome(binary, "--virtual-time-budget=4000", f"--window-size={size}",
               f"--screenshot={png}", f"{url}#shot=1&{frag}", done=lambda _t, p=png: p.exists() and p.stat().st_size > 0)
        if png.exists():
            taken.append(str(png))
    ov = report.get("overlaps", [])
    lane = lambda o: 'lane "' in o or 'lanes "' in o
    out = {"screenshots": taken, "overlaps": ov,
           "counts": {"crossings": sum(" cross" in o and not lane(o) for o in ov), "sharedLines": sum("share a line" in o for o in ov),
                      "labelOnLine": sum(" lies on edge " in o for o in ov),
                      "labelOnNode": sum(not lane(o) and (("covers node" in o) or ("overlaps node" in o)) for o in ov),
                      "lanes": sum(lane(o) for o in ov),
                      "other": sum(not lane(o) and not any(k in o for k in (" cross", "share a line", " lies on edge ", "covers node", "overlaps node")) for o in ov)},
           "routes": report.get("routes"), "lanes": report.get("lanes"),
           "checked": report.get("checked"), "errors": report.get("errors", [])}
    if "error" in report:
        out["errors"].append(report["error"])
    return out


def cmd_check(a) -> None:
    page = Path(a.page).resolve()
    html = page.read_text(encoding="utf8")
    res = run_check(page, Path(a.shots) if a.shots else None, '"kind": "map"' in html or '"kind":"map"' in html)
    print(json.dumps(res, indent=2))
    if res.get("overlaps") or res.get("errors"):
        sys.exit(2)


def escape(s: str) -> str:
    return s.replace("&", "&amp;").replace("<", "&lt;").replace(">", "&gt;")


def main() -> None:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = ap.add_subparsers(dest="cmd", required=True)
    for name in ("detect", "facts"):
        p = sub.add_parser(name)
        p.add_argument("--base")
    r = sub.add_parser("render")
    r.add_argument("data", nargs="?")
    r.add_argument("--map", help="view-based map model (nodes/edges/views) to render as a drill-down map")
    r.add_argument("--out")
    r.add_argument("--shots", help="directory for check screenshots")
    r.add_argument("--no-open", action="store_true")
    r.add_argument("--no-check", action="store_true", help="skip the headless Chrome check")
    r.add_argument("--no-optimize", action="store_true", help="map: skip baking crossing-minimised layouts")
    r.add_argument("--source-base", help="URL prefix for node sources (e.g. https://github.com/OWNER/REPO/blob/main/)")
    r.add_argument("--source-root", help="with --source-base: folder the URL prefix maps to (default: the repo root)")
    m = sub.add_parser("skillmap")
    m.add_argument("skills_dir")
    m.add_argument("--out")
    m.add_argument("--deep", action="store_true", help="give external skills inner views of the skills they trigger")
    c = sub.add_parser("check")
    c.add_argument("page")
    c.add_argument("--shots")
    a = ap.parse_args()
    {"detect": cmd_detect, "facts": cmd_facts, "render": cmd_render, "skillmap": cmd_skillmap,
     "check": cmd_check}[a.cmd](a)


if __name__ == "__main__":
    main()
