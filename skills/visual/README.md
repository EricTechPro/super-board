# /visual

Turns the work in front of you into one self-contained HTML page: a branch recap, a plan, a map of part of the codebase, or an interactive drill-down map of a skill pack, with diagrams.

Adapted from BuilderIO/skills (MIT, visual-recap and visual-plan); diagram style and viewer UX from tt-a1i/archify (MIT). See `THIRD_PARTY_NOTICES.md`.

## What It Does

- **Picks a mode** from the argument, or from `scripts/visual.py detect` when there is none: recap if the branch is ahead of base or has uncommitted changes, plan if a plan file is around, explore otherwise.
- **Gathers facts from git**, not from memory: commits, files with `+/-`, and diff hunks are pulled by `render`, so a recap cannot invent a change.
- **Draws the page** from a `data.json` into `assets/template.html`: key changes, a file map, at least one diagram of the real mechanism, and annotated code. Everything is inline; no build step, no CDN.
- **Routes like a diagram tool.** Each edge has its own port and orthogonal route; render bakes a crossing-free layout per view and the check fails on crossings, shared lines, or labels on lines.
- **Zooms and drills.** Every diagram pans and zooms. Map mode adds a minimap, a node panel (what, when, how, source, upstream and downstream), double-click drill-down into child views, breadcrumbs, `#view=` deep links, search, author avatars on external skills, animated flow, and SVG/PNG export.
- **Checks its own output** with headless-Chrome screenshots (light and dark) and a label-overlap audit, redacts secrets, and writes to a gitignored folder (`_tmp/<date>-visual/` or `.visual/`).

## When To Use It

- Before a review or handoff, to show what a branch changed at a glance.
- To turn a plan into a picture before anyone builds it.
- To learn a folder, an endpoint set, or an architecture you did not write.

## Modes

| Command | Does |
|---|---|
| `/visual` | detect the mode |
| `/visual recap [base]` | what this branch changed against `base` |
| `/visual plan [file]` | a plan as a page; makes no source edits |
| `/visual map [skills-dir or map.json]` | drill-down map of a skill pack or system |
| `/visual <path or thing>` | explore and map it |

## Install

Ships in the super-board pack as a secondary skill. `install.sh` copies `skills/visual/` to `.claude/skills/visual/`. Needs `git` and Python 3 (stdlib only); the self-check screenshot uses headless Chrome when present.
