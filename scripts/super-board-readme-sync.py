#!/usr/bin/env python3
"""Rewrite README.md's skill tables from skills/*/SKILL.md + skills/families.json.

    super-board-readme-sync.py           # rewrite README.md in place if stale
    super-board-readme-sync.py --check   # exit 1 if README.md is stale, write nothing
    super-board-readme-sync.py --hook    # Claude Code PostToolUse: sync only when the
                                         # edited file is under skills/; always exit 0

Reads each skill's `name` and `description` frontmatter, groups skills by
skills/families.json (primary / secondary, one brief each, under 15 words; an
empty brief falls back to the description's first sentence), and
replaces everything between <!-- skills:start --> and <!-- skills:end -->. Also
updates the skill counts in the pitch line and the skills badge.

Exit codes: 0 ok / rewritten, 1 stale (--check), 2 bad input (a skill missing
from families.json or vice versa, a brief of 15+ words, missing markers).
Stdlib only. Runs from any cwd; paths are relative to the pack root.
"""
from __future__ import annotations

import json
import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
README = ROOT / "README.md"
SKILLS = ROOT / "skills"
FAMILIES = SKILLS / "families.json"
START, END = "<!-- skills:start -->", "<!-- skills:end -->"


def die(msg: str) -> None:
    print(f"readme-sync: {msg}", file=sys.stderr)
    sys.exit(2)


def frontmatter(path: Path) -> dict[str, str]:
    """Minimal YAML frontmatter reader: `key: value` plus `>-` / `|` blocks."""
    text = path.read_text(encoding="utf-8")
    m = re.match(r"---\n(.*?)\n---", text, re.S)
    if not m:
        return {}
    out: dict[str, str] = {}
    key = None
    block: list[str] = []
    for line in m.group(1).splitlines():
        kv = re.match(r"([A-Za-z_][\w-]*):\s*(.*)$", line)
        if kv and not line.startswith((" ", "\t")):
            if key and block:
                out[key] = " ".join(s.strip() for s in block).strip()
            key, val = kv.group(1), kv.group(2).strip()
            block = []
            if val in (">", ">-", "|", "|-"):
                continue
            out[key] = val.strip("\"'")
            key = None
        elif key is not None:
            block.append(line)
    if key and block:
        out[key] = " ".join(s.strip() for s in block).strip()
    return out


def render() -> tuple[str, dict[str, int]]:
    try:
        families = json.loads(FAMILIES.read_text(encoding="utf-8"))
    except (OSError, ValueError) as e:
        die(f"cannot read {FAMILIES.relative_to(ROOT)}: {e}")
    on_disk = {p.parent.name: p for p in SKILLS.glob("*/SKILL.md")}
    listed = [s for fam in families.values() for s in fam["skills"]]
    missing = sorted(set(on_disk) - set(listed))
    extra = sorted(set(listed) - set(on_disk))
    if missing:
        die(f"skills not in skills/families.json: {', '.join(missing)}")
    if extra:
        die(f"skills/families.json lists skills with no SKILL.md: {', '.join(extra)}")

    counts: dict[str, int] = {}
    parts: list[str] = []
    for fam_key, fam in families.items():
        counts[fam_key] = len(fam["skills"])
        parts += [f"**{fam['title']}**", "", "| Skill | What it does |", "|---|---|"]
        for skill, brief in fam["skills"].items():
            fm = frontmatter(on_disk[skill])
            name = fm.get("name") or skill
            if not fm.get("description"):
                die(f"skills/{skill}/SKILL.md has no description frontmatter")
            if not brief:  # no brief: first sentence of the description, cut to 14 words
                words = re.split(r"(?<=[.!?])\s", fm["description"], 1)[0].split()
                brief = " ".join(words[:14]) + ("…" if len(words) > 14 else "")
            if len(brief.split()) >= 15:
                die(f"brief for {skill} is {len(brief.split())} words; keep it under 15")
            doc = "README.md" if (SKILLS / skill / "README.md").exists() else "SKILL.md"
            parts.append(f"| [`/{name}`](skills/{skill}/{doc}) | {brief} |")
        parts.append("")
    return "\n".join(parts).rstrip() + "\n", counts


def sync(text: str) -> str:
    if START not in text or END not in text:
        die(f"README.md needs {START} and {END} markers")
    table, counts = render()
    total = sum(counts.values())
    head, rest = text.split(START, 1)
    _, tail = rest.split(END, 1)
    text = f"{head}{START}\n{table}{END}{tail}"
    text = re.sub(r"\*\*\d+ skills\*\*", f"**{total} skills**", text)
    text = re.sub(r"\d+ primary, \d+ secondary",
                  f"{counts.get('primary', 0)} primary, {counts.get('secondary', 0)} secondary", text)
    text = re.sub(r"badge/skills-\d+-", f"badge/skills-{total}-", text)
    return text


def edited_skill_file() -> bool:
    """PostToolUse payload on stdin → was the edited path inside this pack's skills/?"""
    try:
        payload = json.load(sys.stdin)
        tool_input = payload.get("tool_input") or {}
        path = tool_input.get("file_path") or tool_input.get("notebook_path") or ""
        if not path:
            return False
        p = Path(path)
        if not p.is_absolute():
            p = Path(payload.get("cwd") or ".") / p
        p.resolve().relative_to(SKILLS.resolve())
        return True
    except Exception:
        return False


def main() -> int:
    if "--hook" in sys.argv[1:]:
        if edited_skill_file():
            try:
                fresh = sync(README.read_text(encoding="utf-8"))
                if fresh != README.read_text(encoding="utf-8"):
                    README.write_text(fresh, encoding="utf-8")
            except BaseException:  # a hook never fails the edit it follows
                pass
        return 0
    check = "--check" in sys.argv[1:]
    current = README.read_text(encoding="utf-8")
    fresh = sync(current)
    if fresh == current:
        return 0
    if check:
        print("readme-sync: README.md skill tables are stale — run scripts/super-board-readme-sync.py", file=sys.stderr)
        return 1
    README.write_text(fresh, encoding="utf-8")
    print("readme-sync: README.md updated")
    return 0


if __name__ == "__main__":
    sys.exit(main())
