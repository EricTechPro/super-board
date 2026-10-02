---
name: ui-refine-loop
description: Unattended critique → refine loop on one page or component. Each round a fresh critic (Impeccable critique/detect/audit, or a built-in rubric) scores it DONE/CONTINUE with P0–P3 findings, then a fresh refiner fixes them, keeps checks green or reverts, and commits, all in its own worktree with before/after screenshots at desktop 1440 and mobile 390. Two entry points — manual `/ui-refine-loop <route|component>` and a qa-hook the super-board QA lane calls on UI cards. Use when the user says "ui-refine-loop", "/ui-refine-loop", "refine loop", "iterate on this page", "critique and refine N times", or "keep polishing".
argument-hint: "<route | component path | description> [\"<what's wrong / what we want>\"] [--rounds N] [screenshot paths…]"
---

# ui-refine-loop: critique → refine, on a loop

`impeccable critique` scores a surface once and stops, and a refine pass fixes it once and stops. This skill runs the two as a loop. Each round a **fresh critic** judges the latest screenshots, a **fresh refiner** fixes what it found and commits, and a two-line ledger is the only thing carried between rounds. Fresh contexts matter: a critic that watched the last three edits grades the intent, not the pixels.

Adapted from BookKeepingApp refine-loop.

```
/ui-refine-loop /dashboard/reports "the summary strip feels cramped" --rounds 6
/ui-refine-loop src/components/ReceiptViewer.tsx "mobile layout breaks under 400px"
/ui-refine-loop "the billing page plan cards" "too loud, make it calmer" ~/Desktop/billing.png
```

Rounds default to **10** in manual mode and **3** in qa-hook mode. In the paths below, `<main>` is this checkout, `<wt>` is the refine worktree, `<run>` is its run dir, and `<skill>` is this skill's folder.

## Modes

| Mode | Started by | Worktree | Ends with |
|---|---|---|---|
| `manual` | the user: `/ui-refine-loop …` | new `refine/<slug>` branch from `HEAD` | score line, optional before/after page, squash-merge only on the user's yes |
| `qa-hook` | the super-board Tester lane, on a UI card whose tests passed | the QA lane's issue-branch checkout | commits on the issue branch; the Tester reports and pushes. See [`references/qa-hook.md`](references/qa-hook.md) |

The rest of this file covers manual mode. qa-hook uses the same setup script, screenshot script and workflow.

## 0. Resolve the target (ask once)

Turn the argument into a **route** to screenshot and the **scope** paths the refiner may edit:

- **Route**: the page file that serves it (`app/**/page.*`, `pages/**`, `src/routes/**`, or whatever the framework uses), plus the component folders it imports.
- **Component path**: that file's folder. The route is a page that renders it (grep for its import), or its Storybook story.
- **Description**: search for it. Any screenshots the user pasted show which surface they mean.

If there are two plausible readings, or the route matches none of the user's words, ask **one** question listing the candidates, then go. Use the same single question when target files are dirty in `<main>`: the worktree branches from `HEAD`, so uncommitted edits won't be in it. Ask whether to proceed without them or wait. No brief given → the brief is "make it better", and [`references/taste.md`](references/taste.md) picks the direction.

## 1. Setup (once)

1. **Settings.** `bash <skill>/scripts/refine-setup.sh detect`. This resolves the dev command, checks, env files, auth script, data states, taste file and critic (`impeccable` or `rubric`) from the super-board config's `refine` block, then from `package.json`, then from defaults. The keys and the auth contract are in [`references/config.md`](references/config.md). If `devCommand` is null, ask the user for the command once (and suggest saving it as `refine.dev_command`).
2. **Context.** With Impeccable, run `<impeccable> context --target <page or component file>` and condense its directives into one paragraph for the sub-agents. With the rubric, write that paragraph from `PRODUCT.md`/`DESIGN.md` if they exist. Otherwise use "the incumbent implementation is the design authority; refinement preserves it".
3. **Worktree, deps, server.** `slug` is the route or file in kebab-case.
   ```bash
   bash <skill>/scripts/refine-setup.sh up --slug <slug>
   ```
   This creates `<wt>` = `.claude/worktrees/refine-<slug>` on branch `refine/<slug>`, with `<run>` = `<wt>.run` beside it, so shots, auth state and logs never reach a commit. It records the base sha. It gives the worktree a node_modules: an **APFS clone** (`cp -c -R`, a real directory at near-zero disk cost, because a symlink breaks Turbopack), else a reflink copy, else a frozen-lockfile install. A lockfile that differs from `HEAD` always installs fresh. It copies the env files, starts the dev server on a **free port** (never the one another session holds), and waits for `ready_path`. It prints `{worktree, runDir, baseUrl, …}`. Exit 69 means the server never came up: read `<run>/dev.log`, fix it once, or tell the user.
   **Storybook instead** when the app cannot run but the target has a story: set `refine.dev_command` to the storybook script with `--port $PORT --ci --no-open`. The route becomes `/iframe.html?id=<story-id>&viewMode=story`.
4. **BEFORE shots, for every data state.** The states come from `refine.states` (default: `main` only). Never invent a dense dataset. If none exists, say the dense state was not shot.
   ```bash
   cd <wt> && node <skill>/scripts/shoot.mjs --base <baseUrl> --route <route> --out <run>/shots --label round-0 \
     --states '<states JSON from detect>' [--auth <authScript>] [--env <first env file>]
   ```
   [`scripts/shoot.mjs`](scripts/shoot.mjs) captures desktop 1440 and mobile 390 in light theme, grown to the inner scroll height, as `<label>-<state>-<viewport>.png`. With an auth script it signs in once per state and caches the session. Without one it never signs in. Playwright must resolve from `<wt>`. If it doesn't, `npx playwright install chromium` there. Read every image before you start. A sign-in page or an error overlay here means setup is not done.

## 2. The loop: a saved Workflow

Call the **Workflow** tool with `scriptPath: .claude/workflows/ui-refine-loop.js` and the `args` its header documents. Those are: mode, slug, target, scope, the brief verbatim, rounds, the absolute worktree/run/skill paths, critic + impeccable launcher, taste file, checks, `shootCmd` (the step 4 command without `--label`), baseUrl, route, the context paragraph, BEFORE shots, and the user's screenshots. Invoking this skill is the user's opt-in to that workflow.

Rounds run one after another. The critic follows [`references/critic-brief.md`](references/critic-brief.md). It runs critique and detect every round, and the audit only on round 1, every third round, and the rounds that may end the loop. It returns DONE or CONTINUE with ranked P0–P3 findings. On CONTINUE, the refiner follows [`references/refiner-brief.md`](references/refiner-brief.md): it keeps the checks green or reverts, commits once, and takes AFTER shots. The script then appends a [ledger](references/ledger.md) entry.

**Stop rules**, whichever comes first:

- N rounds have run.
- Two clean DONE verdicts in a row (DONE with no P0 or P1).
- The best score has not improved for three rounds.
- Two refiner rounds in a row were reverted.
- A sub-agent died.

**Workflow tool not exposed?** Run the same loop by hand with the Agent tool. Use one `general-purpose` agent per critic and one per refiner. Give each the brief pointer and the inputs the script's prompts carry, never the previous agents' transcripts. You keep the ledger and apply the same stop rules.

**Budget.** Each round runs two sub-agents, one at a time, so a 3-agent / one-browser load limit holds. A round costs about 300–450k tokens and 10–20 minutes (critic 120–200k, plus about 60k on an audit round; refiner 150–250k). Ten rounds come to roughly 3.5–4.5M tokens. Say so when the user asks for more than 10.

## 3. Finish

1. Write the returned ledger to `<run>/ledger.md`.
2. Report: the stop reason, the `scoreLine` (`R1 23 → R2 27.5 → …`, with audit scores alongside), what each commit landed (`git -C <wt> log --oneline $(cat <run>/base)..`), the agents' open questions, and any finding id still in "remaining" after three rounds. Show the `round-0-*` shots next to the final round's shots.
3. Offer a private before → after page with the shot pairs and the score line. Build it only if the user says yes.
4. `bash <skill>/scripts/refine-setup.sh down --run <run>`. Then ask whether to merge. On yes: in `<main>`, run `git merge --squash refine/<slug>` and commit in the repo's style (usually `style:` or `fix:`), with a body listing what each round landed. The `refine(<slug>) round N` messages stay on the throwaway branch. If `<main>` has uncommitted changes in the same files, stop and say so. After the merge, `git worktree remove <wt>`, `git branch -D refine/<slug>`, and delete `<run>`. On no, leave the branch and worktree and tell the user where they are.

## Guardrails

- **Never push.** Never merge without the user's yes. Never touch `<main>`'s working tree during the loop.
- The refiner edits outside the scope paths only with a stated reason. It changes a shared component only behind a new prop that defaults to today's behaviour.
- A refiner round that cannot get every check command green is reverted, never committed red.
- No auth script means no sign-in. No dense fixture means no dense shots. Never fabricate either.
