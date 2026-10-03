# /ui-refine-loop

An unattended Impeccable check → fix loop for one page or component. You name the surface and answer a few questions. It runs a handful of bounded rounds, and you come back to a draft PR of small green commits with a Before | After table.

Adapted from BookKeepingApp refine-loop.

## What It Does

- **Reads the code first.** It reads the page, its components, its tokens and its dark-mode setup before asking anything.
- **Grills you briefly.** At most 10 questions, asked in waves (usually 3, then a few more if needed), each with a recommended answer, so "you pick" works. The answers become the project's taste and direction file (`docs/design/taste.md` by default). It starts from a neutral default, not another project's taste.
- **Isolates the work.** It gets its own worktree and branch, node_modules as an APFS clone, and a dev server on a free port.
- **Shoots everything a reviewer needs**: light and dark, desktop 1440 and mobile 390, section crops, and before | after sheets against round-0.
- **Checks with fresh eyes each round.** Impeccable's design review and its detector plus audit run as two isolated sub-agents, as Impeccable requires. A third merges them into a ranked list of typed problems.
- **Fixes with the right Impeccable command.** A fresh fixer routes each problem type (cluttered → `distill`, too loud → `quieter`, spacing → `layout`, mobile → `adapt`, and so on), chains the commands, and runs `polish` last. It keeps typecheck, lint and tests green or reverts, and makes one commit per round.
- **Scores visual quality, not Nielsen.** The score is design /20 plus audit /20 (out of 40), with a better/same/worse call against round-0.
- **Stops early.** The default is 5 rounds. It stops as soon as two checks in a row find no P0 or P1, or after two reverts in a row.
- **Grades its own work.** A fresh finish reviewer grades each fix fixed, partial or not-fixed from the pixels.
- **Opens a draft PR.** The PR has a Before | After table whose images are committed to the branch and linked by raw GitHub URLs, plus the score line and the grades, in plain words (via `humanizer`). It never merges and never pushes to your base branch.

## When To Use It

- A page works but looks off, and you want it polished without watching every edit.
- A redesign landed and you want it tightened in both themes and at both widths.

It isn't for new pages or full redesigns. The loop refines the existing visual world, and anything that needs a redesign comes back as an open question.

## Usage

Standalone only: you start it. The super-board lanes never run it.

| Command | Does |
|---|---|
| `/ui-refine-loop <route>` | reads, grills, loops 5 rounds, opens a draft PR |
| `/ui-refine-loop <component path> "<brief>"` | the same for a component, judged against your brief |
| `... --rounds N` | change the round cap |

## Install

Ships in the super-board pack. Copy `skills/ui-refine-loop/` to `.claude/skills/ui-refine-loop/` and `workflows/ui-refine-loop.js` to `.claude/workflows/`. You need `git`, `node`, `gh`, and Playwright resolvable from your repo (`npx playwright install chromium`).

**Impeccable** is strongly recommended. Both layouts are detected: v4.4+ (`scripts/impeccable` launcher) and v4.0.x (`node scripts/detect.mjs`). Detection looks in `.claude/skills` and `.agents/skills` of the repo and its parents, then `~`. Without Impeccable the loop warns loudly and falls back to a built-in rubric. If your app needs a sign-in, data states or an unusual dev command, add a `refine` block to your super-board config (`references/config.md`).

Test: `bash tests/test-ui-refine-loop-workflow.sh && bash tests/test-ui-refine-loop-setup.sh`
