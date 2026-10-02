# qa-hook mode: called from the QA lane

The Tester lane calls this on a UI card after its acceptance tests pass. It polishes the surface the card changed before the card moves to Review. It is a bounded add-on. It never blocks a card on its own.

## When the Tester calls it

Call it only when all of these are true:

- The card is UI: label `ui`, `design` or `frontend`, or at least one AC is visual (layout, copy on screen, a screenshot AC).
- The Tester's own tests just **passed** (step 5 of the Tester first pass in `run.md`; this hook is step 5b). A failing card goes back to Build untouched.
- The repo is repo-backed, not URL-only, and `refine-setup.sh detect` prints a `devCommand`.

## What the Tester runs

From the QA worktree (`.worktrees/issue-<N>-qa/`, already on `issue-<N>-<slug>`):

1. `bash <skillDir>/scripts/refine-setup.sh up --worktree .worktrees/issue-<N>-qa` reuses the checkout and starts the dev server. It prints `{runDir, baseUrl, …}`. The run dir sits beside the worktree, so shots never land in a commit.
2. Take BEFORE shots: `node <skillDir>/scripts/shoot.mjs … --label round-0`.
3. Run the `super-refine` workflow with `mode: "qa-hook"`, `issue: <N>`, `rounds` set to `qaHookRounds` (default 3), the card's UI ACs verbatim as `prompt`, and the PR's changed UI files as `scope`.
4. `refine-setup.sh down --run <runDir>`.

## What changes on the branch

Each refiner round makes one commit, `refine(#<N>) round <k>: …`, on the issue branch. Reverted rounds leave nothing behind. Then the Tester:

- re-runs its own AC tests. If they are red, it runs `git reset --hard $(cat <runDir>/base)` to go back to the commit from before the hook, notes "refine reverted: broke AC tests" and carries on to Review with the original work;
- copies the final round's shots into its evidence folder as `after-refine-desktop.png` / `after-refine-mobile.png` and embeds them next to the QA shots (run.md "Screenshot embed format");
- adds one line to the 🔍 comment: `super-refine: <stopReason> · <scoreLine> · <n> commits`, plus any open questions;
- pushes once, along with its own test commits. The hook itself never pushes.

## What it never does

It never moves the card, never comments, never merges, and never blocks. Open questions go into the Tester's comment for the Reviewer to read.
