---
name: super-review
description: Super Review canonical workflow for PR/code/architecture readiness across EricTechOS apps. Use when the user says "Super Review", "review this branch", "review loop", "make sure this is merge-ready", "PR review", or asks for code, architecture, security, QA evidence, or release-readiness judgment. Produces findings and routes fixes to Super Build, Super QA, or Super UX instead of silently pushing changes unless explicitly authorized.
---

# Super Review — PR/code readiness reviewer

**Super Review** is the EricTechOS reviewer/logger workflow. It checks whether a branch or PR is safe to merge, records actionable findings, and routes fixes to the right Super workflow.

Super Review should be conservative with claims: only say **merge-ready** when review evidence is clean and verification has passed. If evidence is missing, say what is unverified.

## When to use

Use this skill for:

- PR or branch review before merge.
- Code, architecture, security, data-model, or migration judgment.
- Release-readiness checks after Super Build, Super QA, or Super UX.
- The **Review Loop** preset in Super Orchestrator.
- A final pass that needs risks, blockers, and human gates summarized.

Do **not** use this as the primary implementation workflow. Route fixes to:

- **Super Build** for feature/task implementation from GitHub Project `Ready` issues.
- **Super QA** for functional bugs, broken behavior, failing Playwright paths, or missing QA coverage.
- **Super UX** for visual fidelity, layout, screenshots, wireframes, or design-system drift.

## Inputs

Accept any of these inputs:

- current branch or local diff;
- GitHub PR number or URL;
- commit range;
- user-provided file list;
- QA report, screenshots, or Super Orchestrator manifest;
- release goal / done definition.

If the input is ambiguous, default to reviewing the current branch against its upstream/base branch. Ask only when the base branch, PR, or target scope materially changes the result.

## Review flow

1. **Establish scope**
   - Identify branch, base branch, PR, changed files, and user goal.
   - Check working tree status before reviewing.
   - If there are unrelated dirty files, stop and ask before touching them.

2. **Inspect changes**
   - Read the diff and the affected modules.
   - Check app-specific conventions from the nearest `CLAUDE.md` / `AGENTS.md`, especially:
     - `clock.now()` instead of `new Date()`;
     - services own business logic, repositories own data access;
     - job handlers own outer transactions;
     - money uses `numeric(12,2)`;
     - calendar days use `date`, not `timestamptz`;
     - structured `AppError({ error_code, context })`;
     - jsonb writes are Zod-validated.

3. **Classify findings**
   - **Blocker:** correctness, data loss, security, auth, migrations, money, customer-visible broken behavior, or failing required tests.
   - **Should fix:** maintainability, missing tests, risky edge cases, accessibility, i18n, observability, or design drift that is clearly in scope.
   - **Nit / optional:** style or cleanup that does not block merge.
   - **Human gate:** product/design/ops decision that cannot be safely guessed.

4. **Route fixes**
   - If a blocker is an implementation task, hand it to **Super Build**.
   - If a blocker is a functional regression, hand it to **Super QA**.
   - If a blocker is visual/design fidelity, hand it to **Super UX**.
   - If the user explicitly authorizes Super Review to fix, make the smallest safe patch, verify it, and clearly report that review also changed code.

5. **Verify evidence**
   - Run the smallest meaningful verification for the touched area.
   - Prefer targeted tests first; run broader suites when the change crosses boundaries.
   - For upload/import flows, do not call it complete from UI success or HTTP 200 alone; verify jobs reach terminal state and destination records are saved.
   - If verification is skipped, state why and mark merge-readiness as unverified.

6. **Report**
   - Lead with the final status: `merge-ready`, `blocked`, `human-gated`, or `unverified`.
   - Include findings grouped by severity.
   - Include verification commands and results.
   - Include which Super workflow should own each fix.

## Output format

```markdown
## Super Review result: <merge-ready | blocked | human-gated | unverified>

- Scope: <branch/PR/files reviewed>
- Base: <base branch/commit if known>
- Verification: <commands + pass/fail/skipped>

### Blockers
- [ ] <finding> → route to <Super Build | Super QA | Super UX | human>

### Should fix
- [ ] <finding> → route to <workflow>

### Human gates
- <decision needed>

### Merge-readiness
<clear statement of whether this can merge now, and why>
```

For Telegram summaries, keep it short and phone-friendly:

```markdown
**Super Review: blocked ⚠️**

- **Scope:** PR #123 / current branch
- **Blockers:** 2
- **Verified:** `npm test -- --run imports`
- **Next:** route functional bug to Super QA, schema decision to human gate
```

## Review Loop behavior

When Super Orchestrator runs **Review Loop**, use this sequence:

1. Super Review inspects branch/PR and writes findings.
2. Super Orchestrator routes each actionable finding to Super Build, Super QA, or Super UX.
3. The owning workflow fixes and verifies its scope.
4. Super Review runs again against the updated branch.
5. Stop only when no blocking review findings remain, or unresolved items are explicitly human-gated.

Super Review should not silently push fixes during Review Loop unless the user or orchestrator explicitly grants that authority.

## Common pitfalls

- Calling a branch **fixed** or **merge-ready** before tests or evidence prove it.
- Treating UI success or HTTP 200 as enough evidence for background jobs, uploads, or imports.
- Mixing reviewer findings with broad refactors.
- Creating duplicate GitHub issues without checking whether the finding is already tracked.
- Letting Super Review become another alias for Super Build; keep review authority separate from implementation authority.

## Done condition

Super Review is done when one of these is true:

- no blocking findings remain and the branch/PR has enough verification evidence to call it merge-ready;
- all unresolved findings are explicitly human-gated;
- required evidence cannot be collected because tooling/service access is unavailable, and the output clearly marks the result as unverified.

## super-board integration

When invoked by super-board (env `SUPER_BOARD_RUN=1` or invocation contains "super-board run"):

### State protocol
- Read from issue + PR comments + PR review threads.
- Respect handed-down worktree at `.worktrees/issue-<N>-review/` and branch `issue-<N>-<slug>`.

### Two variant modes
- **Full variant:** review the diff (code + tests).
- **QA-only variant:** review the QA report quality, not the code diff. (No diff exists in QA-only-URL.)

### Lifecycle (Reviewer)
See `.claude/skills/super-board/references/run.md` → Reviewer. Summary of 8 sub-steps:

1. Worktree from current state of `issue-<N>-<slug>`.
2. **Gate 1 — thread scan.** If ANY unresolved PR thread:
   - `[builder]` open → comment, move card Review → Ready.
   - `[QA]` open → comment, move card Review → QA.
   - Both open → bounce to whichever is older.
   - Clean up worktree, exit.
3. Read PR + spot-check Tester evidence + read CLAUDE.md / AGENTS.md.
4. Review code + tests.
5. **Reviewer-side test rerun (always — closes Tester self-verification gap):**
   - Pull `issue-<N>-<slug>` into review worktree.
   - Re-run the EXACT command from Tester's PR `Local tests:` line.
   - Green → continue. Red → open new `[QA]`-prefixed thread quoting failure, move card Review → QA with `loop:rebuild-N`, exit.
6. **Adversarial mode** (per `config.truth_gate` — `off` / `non-trivial` / `always`, default `non-trivial`): see section below.
7. Decide per finding:
   - **No findings + threads clean + truth ≥ threshold + tests green** → squash-merge PR (or mark ready if `human_approves_merge`), delete branch, close issue, move card Review → Done.
   - **Code-side new finding** → new `[builder]`-prefixed thread, move card Review → Ready (`loop:rebuild-N`).
   - **Test-side new finding** → new `[QA]`-prefixed thread, move card Review → QA (`loop:rebuild-N`).
   - **Blocker (schema, contract, money, auth, migration) or rebuild cap hit** → full §4 Block template, move card Review → Blocked.
8. Clean up worktree.

### Prefix discipline
- Every new review comment Reviewer writes MUST be prefixed `[builder]`, `[QA]`, or `[review]`.
- Unprefixed **top-level** human PR comments → treat as 🧑 Block reason. Move card Review → Blocked with the full §4 template.
- Inline human review-thread replies → context only, no Block.

### `super-truth` is folded into super-review
The standalone `super-truth` skill is removed (spec §10 item 8.9). The adversarial pattern is now built in — see next section.

## Adversarial mode (folded from super-truth)

Activated per `config.truth_gate`:
- `off` — never adversarial.
- `non-trivial` (default) — diff ≥10 lines OR labels in `{security, migration, payments, auth}` trigger adversarial.
- `always` — every card.

When activated, spawn 2 sub-agents in parallel:
- **Code-grounder.** Verify cited file:line still exists and matches claims.
- **Historian.** `git blame` the changed lines; check for ADRs / prior incidents.

Each sub-agent returns a confidence score `0–100`.

**Aggregation rule: take the MINIMUM of the two scores.** Rationale: one strong skeptic should be enough to block.

Compare aggregate to `config.truth_threshold` (default `70`):
- **Below threshold** → Reviewer MUST NOT approve. Open `[review]`-prefixed PR thread quoting the lowest-confidence sub-agent finding. Write the full §4 Block template comment. Move card Review → Blocked with reason 🛡 truth-check failed (confidence X/100). The bot's "Why I cannot decide" line names the specific sub-agent finding it could not confirm.
- **Above threshold** → continue to approval decision.

### Block/Skip exits use the §4 mandatory template
Same rule as super-build/super-qa.
