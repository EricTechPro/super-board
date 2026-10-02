# /super-review

The Reviewer: decides whether a PR is safe to merge, and merges it through the gate when it is.

## What It Does

- **Forms its own view first.** It reads the ACs and the raw diff and writes 2-4 hypotheses before it reads the builder's summary, then checks the builder's claims like any other lead.
- **Remembers the last review.** On a re-review it loads the previous report, marks every finding `fixed`, `not fixed` or `no longer applies` with file:line proof, and bounces again on anything unfixed. A resolved thread is not proof.
- **Classes every finding**: Gap, Bug, Verification miss, Scope drift, or Over-engineering (from `ponytail:ponytail-review`; Should fix at most, never blocks alone). Checks that held go under `Verified`, gaps under `Not verified`.
- **Re-runs the Tester's tests** and, on non-trivial diffs, runs an adversarial truth-check with two sub-agents.
- **Merges through `super-board-merge-gate.sh`**, pinned to the head it reviewed. A push after review voids the evidence.
- **Files shape problems** in the diff to `Backlog` as refactor cards; it never blocks a card on them.

## When To Use It

- Inside a super-board run (the Review lane). This is the normal path.
- Standalone, as `/super-review`, on a branch or PR: you get a readiness verdict and findings routed to the lane that owns each fix.

## Report format

```
## Super Review result: <merge-ready | blocked | human-gated | unverified>
Prior findings · Blockers · Should fix · Over-engineering · Verified correct · Not verified · Human gates
```

Every report starts with `<!-- super-review:report -->` and gives findings stable ids (`R1`, `R2`, …) so the next review can check them.

## Install

Part of the super-board pack: `./install.sh /path/to/project`. Set `human_approves_merge: true` in the config to keep a person on every merge. Lane details: `skills/super-board/references/run.md` → Reviewer.
