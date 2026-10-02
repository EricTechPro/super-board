---
name: visual
description: Turn the current work into one polished, self-contained HTML visual page — a recap of a branch's changes, a plan, or a map of a folder, endpoint set, or architecture — with key changes, a file map, diagrams, and annotated code. Use when the user runs /visual or asks to visualise, picture, or visually recap a branch, PR, diff, plan, or part of a codebase.
---

# /visual

One command, one page. You write a `data.json`; `scripts/visual.py render` injects it into `assets/template.html`, which draws everything inline (SVG diagrams, file map, diffs) with no build step and no runtime CDN. Paths below are relative to this skill's folder; run the script from inside the project being visualised.

## Pick the mode

An argument wins: `/visual recap [base]`, `/visual plan [file]`, `/visual <path or thing>` (explore).

With no argument, run `python3 scripts/visual.py detect` and take the first that holds:

1. A plan was drafted in this conversation and not yet built → **plan**, from that text.
2. `suggested` is `recap` (branch ahead of base, or uncommitted changes) → **recap**.
3. `planCandidates` is non-empty → **plan**, from the newest one.
4. Otherwise → **explore** the current folder.

Say the chosen mode and its source in one line, then keep going.

## Run it

1. **Gather.** Recap: `python3 scripts/visual.py facts [--base REF]`, then read `git diff <mergeBase>` once, in order, taking notes; scope is the whole work unit of this conversation. Plan: read the plan and the real files it names. Explore: read the target; hand wide sweeps to a sub-agent.
2. **Write `data.json`** in the scratchpad, following `references/schema.md` and the section bar in `references/sections.md`.
3. **Render:** `python3 scripts/visual.py render data.json`. It prints `{"out", "missingHunks"}` and opens the page. Fix each missing hunk (wrong path or `contains`) and re-render.
4. **Look at it.** Screenshot headless — `"/Applications/Google Chrome.app/Contents/MacOS/Google Chrome" --headless --screenshot=<png> --window-size=1400,2600 file://<out>` — and read the PNG. A broken diagram or empty section means fix and re-render.
5. **Reply** with the path, the mode, and a 1–3 line gist. Offer to publish it as an Artifact (the page is fully inline); publish only on a yes.

## Rules

- **Grounded:** in recap mode, files, `+/-`, and hunks come from git through `render` (`hunks[].file` + `contains`); hand-typed diff lines are for plan sketches only. Prose is the one free-text surface; label anything inferred as inferred.
- **Diagram first:** every page carries at least one diagram of the real mechanism — new endpoints, modules, data flow — with `change` flags on what moved. Columns follow the flow, rows hold peers.
- **Lean, not thin:** no boilerplate intro or "review the diff anyway" prose; every block says something specific about this change.
- **Secrets:** redact keys, tokens, and `.env` values in every block (`sk-•••`).
- **Plan is read-only:** make no source edits while planning.
- **Output** lands in a gitignored place: `_tmp/<date>-visual/` when the repo ignores `_tmp/`, else `.visual/` (self-ignoring). `--out` overrides.

## References

- `references/schema.md` — the `data.json` contract and diagram layout; open before writing data.
- `references/sections.md` — per-mode section list and quality bar; open before writing data.
- `THIRD_PARTY_NOTICES.md` — Adapted from BuilderIO/skills (MIT); diagram style from tt-a1i/archify (MIT).
