---
name: verify-app
description: Run affected app feature checks, inspect evidence, or maintain this project's verifier when source or accepted behavior changes.
---

# Project verifier starter

**Starter, not executable coverage.** Before saving, replace `verify-app`, adapt
the map to three to five real features and add project-owned scenarios/runner.
Read the installed super-qa `references/project-verifier.md` create/maintain/run
contract. Keep the owning project's instructions and accepted decisions.

## Commands and ownership

Document exact project runner paths and commands for `doctor`, selected features,
explicit `--all` and new run-owned output directories. Name allowed targets,
installed dependencies, reset/fixture policy and owned-process cleanup. Keep
credentials out of commands and proof. Mark unavailable setup explicitly.

## Feature checks

Read `references/feature-map.json`, issue ACs, diff and current source. Select
mapped IDs, state uncovered paths and additional AC checks. Resolve this skill
for the actual host before loading it. A valid map is structure, not a test pass.

## Run and proof

Write executable steps in this order: Select, Doctor, Launch, Drive, Inspect,
Proof, Cleanup. Define real assertions for each feature and relevant side
effects, including which are mocked. Record HEAD/dirty state, input hashes,
selected IDs, outcomes, screenshots/logs, exact rerun command and limits.
Preserve failure evidence and fail if cleanup fails.

## Upkeep

Read current source and live local behavior before editing. Distinguish stale
instructions, harness gaps, product regressions and authorized product changes.
Preserve accepted assertions; cite an issue/decision before changing expectations.
Rerun affected features and report old/new guidance, reason and proof.
