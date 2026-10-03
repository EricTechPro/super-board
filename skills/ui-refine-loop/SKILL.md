---
name: ui-refine-loop
description: Unattended Impeccable check → fix loop on one page or component. It reads the target's code, grills Eric (at most 10 questions, "you pick" welcome) into a per-project taste and direction file, then runs bounded rounds. Each round a fresh checker runs Impeccable critique and audit (design review and detector in separate sub-agents) and ranks typed problems, and a fresh fixer chains the matching Impeccable commands (polish last), keeps checks green or reverts, and commits. Shots cover before vs now, light and dark, 1440 and 390, plus section crops. A fresh finish reviewer grades every fix, and the loop ends in a draft PR with a Before | After table. Standalone only: started by `/ui-refine-loop <route|component>`, never by the super-board lanes. Use when the user says "ui-refine-loop", "/ui-refine-loop", "refine loop", "iterate on this page", "polish this page with impeccable", or "keep polishing".
argument-hint: "<route | component path | description> [\"<what's wrong / what we want>\"] [--rounds N] [screenshot paths…]"
---

# ui-refine-loop: Impeccable check → fix, bounded

Impeccable's `critique` and `audit` find problems once, and each fix command (`distill`, `layout`, `polish`, and the rest) fixes one kind once. This skill chains them into a short unattended loop. Each round, **fresh checkers** find and rank the problems, then a **fresh fixer** picks the right Impeccable commands and lands one green commit. A short ledger is the only thing carried between rounds, because a checker that watched the last edits grades the intent, not the pixels.

```
/ui-refine-loop /dashboard/reports "the summary strip feels cramped"
/ui-refine-loop src/components/ReceiptViewer.tsx "mobile layout breaks under 400px" --rounds 3
/ui-refine-loop "the billing page plan cards" "too loud, make it calmer" ~/Desktop/billing.png
```

Rounds default to **5**. Impeccable advises bounded passes; asking for more than 8 gets a one-line warning about cost and diminishing returns. In the paths below, `<main>` is this checkout, `<wt>` is the refine worktree, `<run>` is its run dir, and `<skill>` is this skill's folder.

It is **standalone**: only a person starts it, with `/ui-refine-loop <where>`. The super-board lanes never run it. It works on its own `refine/<slug>` branch from `HEAD` and ends with finish grades and a **draft PR** for human review. It never merges.

## 1. Read the target's code first

The prompt names where: a route, a component path or a description. Turn it into a **route** to screenshot and the **scope** paths the fixer may edit:

- **Route**: the page file that serves it (`app/**/page.*`, `pages/**`, `src/routes/**`, or whatever the framework uses), plus the component folders it imports.
- **Component path**: that file's folder. The route is a page that renders it (grep for its import), or its Storybook story.
- **Description**: search for it. Any screenshots the user pasted show which surface they mean.

Then **read that code area** before asking anything: the page, the components it renders, the shared UI it uses, the tokens and theme (including how dark mode works), and `PRODUCT.md` / `DESIGN.md` if they exist. Write a one-paragraph **context** for the sub-agents: what the surface does, its components, its tokens, its dark-mode mechanism. Use a sub-agent for this if it spans many files.

If two readings of the target are plausible, or target files are dirty in `<main>` (the worktree branches from `HEAD`, so uncommitted edits won't be in it), make that the grill's first question.

## 2. Grill (at most 10 questions)

Follow [`references/grill.md`](references/grill.md), which uses the `grilling` skill's pattern: numbered questions with your recommended answer under each, asked in waves. Wave 1 is 3 questions; later waves come only if needed, and the total is 10 at most. "You pick" accepts your recommendation. Don't ask what the code or an existing taste file already answers. Keep the answers for step 3.4.

## 3. Setup (once)

1. **Settings.** Run `bash <skill>/scripts/refine-setup.sh detect`. It resolves the dev command, checks, env files, auth script, data states, taste file and Impeccable install from the super-board config's `refine` block, then `package.json`, then defaults ([`references/config.md`](references/config.md)). If `devCommand` is null, ask once (and suggest saving it as `refine.dev_command`).
2. **Impeccable detection.** Detect's `impeccable` field is `{layout, skillDir, version, detect, context}` or null. It handles both installs: v4.4+ ships a launcher (`scripts/impeccable detect --json`, `scripts/impeccable context`), and v4.0.x ships Node scripts (`node scripts/detect.mjs --json`, `node scripts/context.mjs`). It searches `.claude/skills/impeccable` and `.agents/skills/impeccable` in this directory and every parent, then `~`. **If `warnings` is non-empty, show them to the user now, verbatim.** With no Impeccable, the loop runs on [`references/rubric.md`](references/rubric.md), the result carries `degraded`, and the PR says so. It is never silent.
3. **Worktree, deps, server.** `slug` is the route or file in kebab-case.
   ```bash
   bash <skill>/scripts/refine-setup.sh up --slug <slug>
   ```
   This creates `<wt>` = `.claude/worktrees/refine-<slug>` on branch `refine/<slug>`, with `<run>` = `<wt>.run` beside it, so shots, auth state and logs never reach a commit. It records the base sha and base branch. It gives the worktree a node_modules: an APFS clone, else a reflink copy, else a frozen-lockfile install. It copies the env files, starts the dev server on a free port, and waits for `ready_path`. Exit 69 means the server never came up: read `<run>/dev.log`, fix it once, or tell the user. If the app can't run but the target has a story, set `refine.dev_command` to Storybook with `--port $PORT --ci --no-open`; the route becomes `/iframe.html?id=<story-id>&viewMode=story`.
4. **Taste and direction file.** Write the grill's answers to `<wt>/<tasteFile>` as [`references/grill.md`](references/grill.md) § Output describes (from the neutral [`references/taste.md`](references/taste.md) if the project has none), and commit it: `💄 [ui] <slug>: taste and direction`.
5. **Impeccable context.** With Impeccable, run `cd <wt> && <impeccable.context> --target <page or component file>` once and fold its directives into the context paragraph.
6. **Round-0 shots, for every data state** (from `refine.states`, default `main`; never invent a dense dataset):
   ```bash
   cd <wt> && node <skill>/scripts/shoot.mjs --base <baseUrl> --route <route> --out <run>/shots --label round-0 \
     --states '<states JSON from detect>' [--auth <authScript>] [--env <first env file>]
   ```
   [`scripts/shoot.mjs`](scripts/shoot.mjs) writes `<label>-<state>-<desktop|mobile>-<light|dark>.png` at 1440 and 390, grown to the inner scroll height, plus light-theme **section crops** (`…-s<i>.png`, from `[data-refine-section]` or `main`'s sections). With `--compare round-0`, later rounds also get **before | after sheets** (`cmp-…png`). Read every image. A sign-in page or an error overlay means setup isn't done. Playwright must resolve from `<wt>`; if it doesn't, run `npx playwright install chromium` there.

## 4. The loop: a saved Workflow

Call the **Workflow** tool with `scriptPath: .claude/workflows/ui-refine-loop.js` and the `args` its header documents: slug, target, scope, the brief verbatim, rounds, the absolute worktree/run/skill paths, `critic` and `impeccable` (detect's object, as-is), `tasteFile` (`<wt>/<tasteFile>`), checks, `shootCmd` (the step 3.6 command without `--label`), baseUrl, route, the context paragraph, the round-0 shots (every path printed), the user's screenshots, and detect's `warnings`. Invoking this skill is the user's opt-in to that workflow.

Each round:

1. **Check.** Two isolated sub-agents run in parallel: the **design reviewer** (Impeccable critique's Assessment A, scoring visual quality /20 across specificity, hierarchy, typography, color and composition) and the **detector** (Impeccable's detector plus the audit, /20). Neither sees the other. A fresh **checker** merges them into at most 8 **ranked, typed** problems and judges before vs now from the sheets. See [`references/checker-brief.md`](references/checker-brief.md).
2. **Fix.** A fresh **fixer** reads Impeccable's command table, the playbook for each command it runs, and craft-floor. It routes each problem by type ([`references/routing.md`](references/routing.md): cluttered → `distill`, bland → `bolder`, too loud → `quieter`, dull color → `colorize`, spacing/hierarchy → `layout`, type → `typeset`, mobile → `adapt`, slow → `optimize`, empty/first-run → `onboard`, confusing copy → `clarify`, edge cases and a11y → `harden`, motion → `animate`, personality → `delight`, drift or 3+ copies → `extract`), chains them, and always runs **`polish` last**. It keeps the checks green or reverts, makes one commit, and takes AFTER shots with `--compare round-0`. See [`references/fixer-brief.md`](references/fixer-brief.md).

The workflow appends a [ledger](references/ledger.md) line per check. The **score** is visual quality /40 (design /20 + audit /20) plus before/after (`better`/`same`/`worse`); Nielsen heuristics are not used. After the last fix round, a closing check scores the final state.

**Stop rules**, whichever comes first:

- N fix rounds have run (default 5), followed by the closing check.
- Two consecutive checks found no P0 or P1.
- Two fix rounds in a row were reverted.
- A sub-agent died.

**Finish review.** A fresh **finish reviewer** grades every claimed fix `fixed`, `partial` or `not-fixed` against round-0 vs final shots, and names up to three regressions ([`references/finish-reviewer-brief.md`](references/finish-reviewer-brief.md)).

**Workflow tool not exposed?** Run the same loop by hand with the Agent tool: one fresh `general-purpose` agent per role (design reviewer and detector in parallel, then checker, then fixer, then finish reviewer). Give each its brief and the inputs the script's prompts carry, never another agent's transcript. You keep the ledger and apply the same stop rules.

**Budget.** A round is four sub-agents, with at most two at once (design reviewer and detector; only the reviewer may open a browser). Expect about 350–500k tokens and 15–25 minutes per round, so the default 5 rounds come to roughly 2–2.5M.

## 5. Finish: draft PR

1. Write the returned ledger to `<run>/ledger.md`, then `bash <skill>/scripts/refine-setup.sh down --run <run>`.
2. **Shots onto the branch.** Run
   ```bash
   bash <skill>/scripts/pr-shots.sh --worktree <wt> --run <run> --slug <slug> --final <finalLabel>
   ```
   It copies round-0 and the final round's `main` shots (1440 and 390, light and dark) to `<wt>/docs/ui-refine/<slug>/`, commits them, and prints a **Before | After** markdown table whose images are `https://github.com/<owner>/<repo>/raw/<sha>/…` links. Never upload shots to a public image host.
3. **Push the refine branch only:** `git -C <wt> push -u origin refine/<slug>`. Never push to the base branch.
4. **PR body** — the marker blocks of `.claude/skills/super-board/references/writing-standard.md` § 2 (`super-board-pr-body.sh --skeleton` prints them): **status** `> [!NOTE]` draft · check count · head sha (`> [!WARNING]` when `degraded`); **problem** the target and the brief, one line each, plus any `warnings`; **solution** the score line (`C1 22/40 → C2 27/40 (better) → …`) and one plain bullet per fixed problem; **ac** the finish grades as a checklist, one proof line each (`id · severity · grade · evidence`; unchecked = still open, with why — including any problem open after three checks and each open question); **history** one row per check from the ledger (Lane `🎨 refine`, Done, local time, the commit); **visual** the Before | After table; **risk** 🟢/🟡/🔴 + one line from the regressions and the disposition, and that the shots live in `docs/ui-refine/<slug>/` (drop that commit before merging if unwanted; the links are pinned to a sha and keep working). Title in commit-subject format: `💄 [ui] <slug>: <what got better>`.
5. **Humanize the prose.** Run the PR title and body through the `humanizer` skill. Without it: short sentences, plain words, no hype, no em-dash chains, no "this PR aims to", and say what changed and why.
6. Open it as a draft against `$(cat <run>/base-branch)`: `gh pr create --draft --base <base-branch> --head refine/<slug> --title "…" --body-file <run>/pr.md`. Report the PR URL, the stop reason, the score line and the grade counts. Leave the worktree in place for follow-ups and tell the user where it is.

## Guardrails

- **Never merge. Never push to the base branch.** The only push is `refine/<slug>`, for the draft PR. Never touch `<main>`'s working tree during the loop.
- The fixer edits outside scope only with a stated reason, and changes a shared component only behind a new prop that defaults to today's behaviour.
- A fix round that can't get every check command green is reverted, never committed red.
- No auth script means no sign-in. No dense fixture means no dense shots. Never fabricate either.
- Impeccable missing means a loud warning and the rubric, never a silent fallback.
