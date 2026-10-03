# Checker brief

Each check runs three fresh agents. The **design reviewer** and the **detector** run in parallel and never see each other's output. Impeccable requires this: design review and detector in one context is a degraded critique. The **checker** then merges both into one ranked, typed problem list. Read only your own section. None of the three edits files, commits or asks the user anything; questions go in `openQuestions`.

Everyone reads the **taste and direction file** named in the prompt first. It holds the grill's answers (goal, direction, keep, avoid) and the project's taste rules (T*) and slop tells (S*). Cite their ids in `evidence`. Where the taste file and a generic playbook disagree, the taste file wins. The design context arrives in the prompt, so do not rerun `context`.

## Design reviewer

This is Impeccable critique's Assessment A, minus its ceremony.

1. **Playbook.** With `impeccable`, read `critique.md` (Assessment A only) and `craft-floor.md` from the playbooks folder in your prompt. Skip the live overlay, storage, "Ask the User" and "Recommended Actions". With `rubric`, read [`rubric.md`](rubric.md) §1.
2. **Look at everything.** Read every image in the prompt: the round-0 shots, the current shots, the before | after sheets and the section crops. That covers light and dark at desktop 1440 and mobile 390. Then read the source files in scope. Judge the brief first, the taste file second and generic craft third. If the repo documents a page-composition rule (`CLAUDE.md`, `AGENTS.md`, `docs/`), breaking it is a problem. Need another state, such as a dialog open? Run the screenshot command in your prompt, one browser at a time.
3. **Score the visual quality** 0–4 per dimension (4 is genuinely excellent; most real surfaces land at 2–3):
   - `specificity`: does it look like this product, or could any product ship it unchanged?
   - `hierarchy`: does the eye land on the primary task or figure first?
   - `typography`: scale, weight, line length, figures, truncation.
   - `color`: one meaning per color from tokens, contrast, and dark mode parity.
   - `composition`: spacing rhythm, alignment, grouping, and density at both widths.

   `designTotal` is the sum, out of 20. Do not score Nielsen heuristics; they are not this loop's signal.
4. **Problems**: up to 8, typed and ranked (format below). Each one names the theme, viewport and section where it shows.

Header line in your head, not your output: `Assessment A · isolated`.

## Detector

This is Impeccable critique's Assessment B plus the audit. You never see the screenshots or the design review.

1. **Run the detector** over every scope path that holds markup or styles: the detector command in your prompt (`<detect> <paths>`, from the worktree). Exit 0 means clean and exit 2 means findings. Check each hit in the source and drop false positives. If the command is missing or crashes after a real attempt, set `detectorRan: false` and say why in a problem's evidence. A skipped detector otherwise counts as a failed check. With `rubric`, run [`rubric.md`](rubric.md) §3's mechanical checks instead (`detectorRan: true`).
2. **Audit.** With `impeccable`, read `audit.md` and score its five dimensions 0–4: `accessibility`, `performance`, `responsive`, `theming`, `integrity` (implementation integrity). With `rubric`, use §2. `auditTotal` is the sum, out of 20.
3. **Problems**: one per verified detector cluster or audit gap, typed and ranked.

## Checker

You get both assessments as JSON, the shots, and the ledger.

1. **Merge, don't concatenate.** When A and B flag the same thing, keep one problem with both kinds of evidence. Drop what the brief or the taste file says to keep. Keep **at most 8**, ranked P0 → P3:
   - **P0**: broken. The task can't be done, content is clipped or unreadable, or a theme is unusable.
   - **P1**: blocks the brief or the page's job, or fails accessibility.
   - **P2**: off-taste or sloppy, but the job still gets done.
   - **P3**: polish.
2. **Reuse ids.** When the ledger names the same issue, reuse its id. That is how a problem that survived a fix gets noticed. If an id has survived three checks, say so in `summary`.
3. **Before vs now.** From the before | after sheets, set `vsBefore` to `better`, `same` or `worse` (on the first check, `baseline`). Write `vsBeforeNote` as one line by section, for example "header calmer, table denser, dark footer regressed". A change that made any section worse is a problem in its own right.
4. Return `problems`, `vsBefore`, `vsBeforeNote`, a two-sentence `summary` and `openQuestions`. The workflow computes the visual score: design /20 + audit /20 = **/40**.

## Problem format (all three)

- `id`: `<area>-<problem>`, for example `summary-strip-cramped`.
- `severity`: P0–P3.
- `type`: exactly one from [`routing.md`](routing.md). It picks the Impeccable command the fixer runs, so choose the type for the cause, not the symptom.
- `location`: `file:line`, repo-relative. A problem without one can't be acted on, so find the line.
- `evidence`: the screenshot path plus what it shows (theme, viewport, section), or the detector rule.
- `fix`: what done looks like, inside the existing visual world.

Never type a problem as a redesign (`shape`, `overdrive`, `live`). Something that needs one goes in `openQuestions`. Report a problem outside scope only when it breaks the target, and say so in `fix`.
