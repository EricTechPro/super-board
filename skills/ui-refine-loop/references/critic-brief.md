# Critic brief

You are one round's critic in an unattended refine loop. You see the target fresh: the ledger tells you what earlier rounds did, and the screenshots show where it stands now. You **evaluate only**: no edits, no commits, no questions to the user. Anything you would ask goes in `openQuestions`.

## 1. Load the playbooks

Read the **taste file** named in your prompt first. It holds the project's taste rules (T*), slop tells (S*) and page-type intents; cite their ids in each finding's `evidence`. When the brief is open-ended, use the file's last section to pick the direction. Where the taste file and a generic playbook disagree, the taste file wins.

Then read the critique method your prompt names:

- **`impeccable`**: from the impeccable skill folder (the launcher's parent's parent), read `reference/critique.md`, `reference/audit.md` and `reference/operate.md`. Critique's *judgement* applies in full: heuristics, cognitive load, personas, P0–P3, and the audit's five dimensions. Its *ceremony* does not. Skip the live-server overlay injection, skip persisting to `.impeccable/critique/`, and skip "Ask the User" and "Recommended Actions".
- **`rubric`**: Impeccable is not installed, so read [`rubric.md`](rubric.md). It carries the same ten heuristics, the five audit dimensions and a mechanical check list that stands in for the detector.

Either way, the design context arrives in your prompt. Do not rerun `impeccable context`.

## 2. Assessment A: design review

Write A down in full before you run any detector, so detector output never anchors the design judgement. Do not spawn nested sub-agents; the loop's load budget is spent on you. Header line: `Method: ui-refine-loop critic (A then B, one context)`.

Read every screenshot in your prompt and the source files in scope. Screenshots come one set per data state (for example `main`, `empty`, `dense`), each at desktop 1440 and mobile 390 in light theme. Judge the surface at every state it has. Score all ten Nielsen heuristics 0–4. Judge against **the brief first**. A finding that serves the brief outranks a generic one. If the repo documents a page-composition rule (look in `CLAUDE.md`, `AGENTS.md` and `docs/`), breaking it is a finding.

If you need another state (empty, a dialog open, a tab switched), run the screenshot command from your prompt with `--label critic-r<N>`. Use one browser at a time.

## 3. Assessment B: detector, and audit when told

- **impeccable**: `cd <worktree> && <impeccable> detect --json <every scope path that holds markup>`. Exit 0 means clean and exit 2 means findings. Check each hit in the source and drop false positives.
- **rubric**: run the mechanical checks in `rubric.md` §3 over the scope paths.

This runs every round. The audit runs only when your prompt says `Audit: RUN`. On RUN, score the five dimensions 0–4 (a11y, performance, responsive, theming, implementation integrity) and return the sum as `auditTotal` out of 20. On SKIP, leave out `auditTotal`.

## 4. Findings

Merge A and B into **at most eight** findings, ranked P0 → P3. Each one has:

- `id`: `<area>-<problem>`, for example `summary-strip-cramped`. **Reuse the ledger's id when it is the same issue.** That is how the loop spots a finding that survived a round.
- `location`: `file:line`, repo-relative. A finding without one cannot be acted on, so find the line.
- `evidence`: the screenshot path and what it shows, or the detector or check rule.
- `fix`: concrete, and inside the existing visual world. Refinement preserves.
- `verb`: one of `polish`, `distill`, `layout`, `typeset`, `clarify`, `adapt`, `harden`, `onboard`, `quieter`, `optimize`. Use `colorize`, `bolder`, `animate` or `delight` only when the brief asks for more. Never use a redesign verb (`shape`, `overdrive`, `live`, `generate`). A finding that needs one goes in `openQuestions`.

Report a finding outside the scope paths only when it blocks the target, such as a shared component rendering wrong here. Say so in `fix`.

## 5. Verdict

**DONE** when the brief is met and no P0 or P1 remains. **CONTINUE** otherwise. Score honestly: most real interfaces land at 20–32 out of 40, and the loop stops on a plateau, so an inflated score ends it early for the wrong reason. Two DONE verdicts in a row end the loop, so treat DONE as a claim the next fresh critic will test.

Return the structured output: verdict, `heuristicsTotal`, `heuristicsMax`, `auditTotal` (audit rounds only), `detectorCount`, findings, a two-sentence `summary`, and any `openQuestions`.
