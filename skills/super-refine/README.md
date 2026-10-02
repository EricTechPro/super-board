# /super-refine

An unattended critique → refine loop for one page or component. A fresh critic scores the surface each round, a fresh refiner fixes what it found, and you come back to a branch of small green commits with before/after screenshots.

Adapted from BookKeepingApp refine-loop.

## What It Does

- **Isolates the work.** The loop gets its own worktree and branch, node_modules as an APFS clone (with a reflink-copy or install fallback), and a dev server on a free port.
- **Shoots BEFORE screenshots** at desktop 1440 and mobile 390, once per data state you configure, signed in through your own auth script, or not signed in at all if you have none.
- **Each round runs a fresh critic**: Impeccable critique and detect, plus the audit every third round. Without Impeccable it uses a built-in rubric. The critic returns DONE or CONTINUE with up to eight P0–P3 findings, each pinned to a `file:line`.
- **Then a fresh refiner** applies the fixes, keeps your typecheck/lint/test commands green or reverts, makes one commit, and takes AFTER shots.
- **Carries a two-line ledger between rounds.** No agent sees another agent's transcript.
- **Stops** after N rounds, two clean DONEs, a score plateau over three rounds, or two reverts in a row. It ends with a score line, offers a before/after page, and squash-merges only when you say yes. It never pushes.

## When To Use It

- A page works but looks off, and you want it polished without watching every edit.
- A redesign landed and you want it tightened at both desktop and mobile widths.
- On a super-board run, the QA lane can call it on UI cards (qa-hook mode) so the surface is polished before Review.

It is not for redesigns or new pages. The loop preserves the existing visual world, so anything needing a redesign comes back as an open question.

## Modes

| Command | Does |
|---|---|
| `/super-refine <route>` | loop on that page, 10 rounds |
| `/super-refine <component path> "<brief>"` | loop on a component, judged against your brief |
| `... --rounds N` | change the round cap |
| qa-hook | the super-board Tester calls it on a UI card's branch, 3 rounds by default; see `references/qa-hook.md` |

## Install

Ships in the super-board pack. Copy `skills/super-refine/` to `.claude/skills/super-refine/` and `workflows/super-refine.js` to `.claude/workflows/`. You need `git`, `node`, and Playwright resolvable from your repo (`npx playwright install chromium`). Impeccable is optional. If your app needs a sign-in, data states or an unusual dev command, add a `refine` block to your super-board config (`references/config.md`). Everything else is auto-detected from `package.json`.

Test: `bash tests/test-refine-workflow.sh && bash tests/test-refine-setup.sh`
