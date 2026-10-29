#!/usr/bin/env python3
"""super-collect's hand-off to Matt Pocock's planning chain. Stdlib only.

    collect_handoff.py route --root .         # planning (/to-spec, /to-tickets) or backlog + why
    collect_handoff.py doc --findings v.json [--since 14d] [--date YYYY-MM-DD] [--out P] [--yes]
    collect_handoff.py fork --tickets N [--no-implement-spec]

route  Resolves to-spec, to-tickets and implement-spec with the pack's skills-ready
       resolver (actual host-visible SKILL.md files). Either of the first two missing →
       route "backlog" with a printable reason: file straight into Backlog as before.
doc    Writes ONE findings doc from the verifier's results: `file` and `needs-triage`
       findings grouped by `group` (else by source), everything else listed under
       "Not in this doc". Default path docs/super-board/findings/collect-<date>.md;
       an existing file is never overwritten (-2, -3, …). Without --yes it prints the
       doc and writes nothing.
fork   1–5 tickets → implement-spec (one session, no QA lane); 6+ → super-board Backlog.

Exits: 0 ok · 2 resolver not found · 3 nothing verified to hand off · 64 bad args
"""
from __future__ import annotations

import argparse
import datetime as dt
import importlib.util
import json
import os
import sys
from pathlib import Path

CHAIN = ("to-spec", "to-tickets")
SMALL = 5            # 1..SMALL tickets → /implement-spec
KEEP = ("file", "needs-triage")
DOC_DIR = "docs/super-board/findings"


def resolver():
    """Load super-board-skills-ready.py: installed .claude/bin, else the pack's scripts/."""
    here = Path(__file__).resolve().parent
    bin_env = os.environ.get("SUPER_BOARD_BIN")
    dirs = ([Path(bin_env)] if bin_env else []) + [Path(".claude/bin"), here.parents[2] / "bin",
                                                   here.parents[2] / "scripts"]
    for d in dirs:
        path = d / "super-board-skills-ready.py"
        if path.is_file():
            spec = importlib.util.spec_from_file_location("sb_skills_ready", path)
            mod = importlib.util.module_from_spec(spec)
            spec.loader.exec_module(mod)
            return mod
    print("collect-handoff: cannot find super-board-skills-ready.py — set SUPER_BOARD_BIN or run install.sh",
          file=sys.stderr)
    sys.exit(2)


def route(args):
    mod = resolver()
    inv = mod.Inventory(args.root, args.host, args.home or os.environ.get("SUPER_BOARD_SKILLS_HOME"))
    found = {n: inv.resolve("mattpocock-skills:" + n)[0] for n in CHAIN + ("implement-spec",)}
    missing = [n for n in CHAIN if not found[n]]
    out = {"route": "backlog" if missing else "planning", "missing": missing,
           "to_spec": found["to-spec"], "to_tickets": found["to-tickets"],
           "implement_spec": found["implement-spec"]}
    if missing:
        out["reason"] = (" and ".join("/" + n for n in missing) + " not installed in " + str(Path(args.root).resolve())
                         + " — filing each finding straight into Backlog instead. "
                         + "Install Matt Pocock's skills (get.sh, or npx skills@latest add mattpocock/skills) to use the planning chain.")
    print(json.dumps(out))
    return 0


def render(findings, since, date):
    kept = [f for f in findings if f.get("verdict") in KEEP]
    other = [f for f in findings if f.get("verdict") not in KEEP]
    groups = {}
    for f in kept:
        groups.setdefault(f.get("group") or f.get("source") or "other", []).append(f)
    lines = [f"# Findings · {date}", "",
             f"super-collect found these problems{' since ' + since if since else ''}. A fresh verifier checked each one.",
             f"{len(kept)} findings in {len(groups)} groups. Next: `/to-spec` on this doc, then `/to-tickets`.", ""]
    for name, items in groups.items():
        lines += [f"## {name}", ""]
        for f in items:
            tag = " `needs-triage`" if f.get("verdict") == "needs-triage" else ""
            lines.append(f"- **{f.get('title', '(untitled)')}** · {f.get('type', 'bug')} · {f.get('source', '?')}{tag}")
            if f.get("note"):
                lines.append(f"  - {f['note']}")
            if f.get("evidence"):
                lines.append("  - Evidence: " + ", ".join(str(e) for e in f["evidence"]))
            if f.get("fingerprint"):
                lines.append(f"  - Fingerprint: `{f['fingerprint']}`")
        lines.append("")
    if other:
        lines += ["## Not in this doc", ""]
        for f in other:
            why = f" — {f['note']}" if f.get("note") else ""
            lines.append(f"- {f.get('title', '(untitled)')} · {f.get('verdict', '?')}{why}")
        lines.append("")
    return "\n".join(lines), len(kept)


def doc(args):
    findings = json.loads(Path(args.findings).read_text())
    if not isinstance(findings, list):
        print("collect-handoff: --findings must be a JSON array", file=sys.stderr)
        return 64
    date = args.date or dt.date.today().isoformat()
    text, kept = render(findings, args.since, date)
    if not kept:
        print("collect-handoff: nothing to hand off — no finding has verdict file or needs-triage", file=sys.stderr)
        return 3
    out = Path(args.out) if args.out else Path(DOC_DIR) / f"collect-{date}.md"
    n = 2
    base = out
    while out.exists():
        out = base.with_name(f"{base.stem}-{n}{base.suffix}")
        n += 1
    if not args.yes:
        sys.stdout.write(text)
        print(f"collect-handoff: dry run — would write {out}", file=sys.stderr)
        return 0
    out.parent.mkdir(parents=True, exist_ok=True)
    out.write_text(text)
    print(out)
    return 0


def fork(args):
    if args.tickets < 1:
        print("collect-handoff: --tickets must be 1 or more", file=sys.stderr)
        return 64
    if args.tickets > SMALL:
        out = {"build": "super-board", "why": f"{args.tickets} tickets (6+): add each to Backlog, then /super-board lint and run"}
    elif args.no_implement_spec:
        out = {"build": "super-board", "why": "implement-spec not installed: add the tickets to Backlog instead"}
    else:
        out = {"build": "implement-spec", "why": f"{args.tickets} tickets (1–5): one /implement-spec session, no QA lane"}
    print(json.dumps(out))
    return 0


class Parser(argparse.ArgumentParser):
    def error(self, message):
        print("collect-handoff: " + message, file=sys.stderr)
        sys.exit(64)


def main(argv=None):
    p = Parser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = p.add_subparsers(dest="cmd", required=True, parser_class=Parser)
    r = sub.add_parser("route")
    r.add_argument("--root", default=".")
    r.add_argument("--host", default="claude", choices=["claude", "codex"])
    r.add_argument("--home")
    d = sub.add_parser("doc")
    d.add_argument("--findings", required=True)
    d.add_argument("--since", default="")
    d.add_argument("--date")
    d.add_argument("--out")
    d.add_argument("--yes", action="store_true")
    f = sub.add_parser("fork")
    f.add_argument("--tickets", type=int, required=True)
    f.add_argument("--no-implement-spec", action="store_true")
    args = p.parse_args(argv)
    return {"route": route, "doc": doc, "fork": fork}[args.cmd](args)


if __name__ == "__main__":
    sys.exit(main())
