# Issue 12 QA, version 1

Result: pass for the scoped helper correction. Independent Review is still required.

- Tested source head: `0c127906c5ed6b9040e71a8310d456572051c920`.
- Historical regression-only head: `c47c2a369e0b6920441c548b966acc7d6ed76295`.
- Branch: `issue-12-tolerate-absent-phase-display-labels`, PR #13.
- Only permitted merge destination: `codex/pi-pilot-20261020`.
- Host: fresh Pi QA lane, Python 3.14.6, git 2.50.1, macOS.
- Rerun command for Review: `bash tests/run-safety.sh`.

## P1. Preflight

Pi QA skill readiness returned `ready=true` before any worktree or lifecycle write. Required skills were loaded. Guarded complete PR metadata preceded the diff read with `--meta`. Issue comments, PR comments, review comments and thread replies were read completely. All thread and reply pagination ended. Five author-note threads have no replies or findings. No prior Reviewer report exists.

The card was in QA. PR #13 was open and draft at the tested head. Its base was the configured pilot branch. The latest base was fetched at `b7abfda3576cdd2a0d6a69a04c3315abaa6bcb8b`. The issue merge-base is `c957c978d1f4c5ecad45d3e89e9c4fa2cbce4c29`. QA used only `.claude/worktrees/issue-12-qa` and preserved the Builder's exact source.

PR #1 overlap is the authorized stacked correction, not duplicate work. The Builder's expected-conflict note remains. This lane did not modify PR #1. No `repairReservation` was supplied. Read-only verification consumes no repair. No canonical record or repair-count/phase label was changed.

## P2. Classification and AC ledger

This is a Python CLI integration defect, not a browser defect. Unit coverage was mapped first, integration coverage second, and browser coverage last. The accepted seam is the existing installed wave/lane/handoff/card helpers, with external GitHub and model processes replaced by fixtures. No new runner, framework or product code was added.

| AC | Unit proof | Integration or operational proof | Browser |
|---|---|---|---|
| AC1, old code fails faithfully | n/a, external CLI rejection | `tests/test_repair_wave.py:121` at regression-only `c47c2a3` failed for both hosts with `79 != 0 : 'loop:repair-diagnosis' not found` | n/a, no UI |
| AC2, first failure retains zero | `tests/test_repair_budget.py:104,108` | `tests/test_repair_wave.py:121` asserts one idle/0 canonical record, no phase-label creation, then one reserved/1 dispatch | n/a |
| AC3, counts and exact phase | `tests/test_repair_budget.py:22-84,162,205` | `tests/test_repair_wave.py:157,181,190,202,211` covers normal/final success, diagnosis/final exhaustion, invalid diagnosis and interrupted reservations | n/a |
| AC4, unknown outcome halts | `tests/test_repair_budget.py:122` | `tests/test_repair_wave.py:139` applies the edit, loses the response, then asserts halt/79, one edit, retained claim and no replay or new dispatch | n/a |
| AC5, preserve explicit restart boundary | n/a, operational constraint | Guarded reads found one idle/0 record with pending_lane=build on #9 and unchanged draft PR #11. No fixture restart or mutation was performed. Actual resumed live acceptance belongs to #7 after this fix is accepted. | n/a |

AC5 is a preservation check, not a claim that the later live restart passed. The owner explicitly separated that restart from this lane.

## Fresh verification

| Command | Revision | Result |
|---|---|---|
| `python3 tests/test_repair_wave.py RepairWave.test_both_hosts_initial_failure_without_phase_labels_persists_zero_before_next_dispatch` | disposable export of `c47c2a3` | Expected red, exit 1, two matching host failures, 4.454 seconds |
| `python3 tests/test_repair_wave.py` | `0c12790` | Exit 0, 7 tests, 68.662 seconds |
| `python3 tests/test_repair_budget.py` | `0c12790` | Exit 0, 23 tests, 8.993 seconds |
| `bash tests/run-safety.sh` | `0c12790` | Exit 0, `PASS: 69 safety suites`; includes 23 budget and 7 wave tests again |
| `git diff --check` | QA worktree | Exit 0 |

The full 916-line safety log was inspected. No suite failed. Existing unrelated ResourceWarning and DeprecationWarning messages were retained. The current run installed the pack from this QA checkout into fresh disposable test repos. It did not use stale ignored installed helpers from the pilot root.

`verification.txt` contains exact selected output and SHA-256 hashes of the complete raw logs. Complete logs, guarded reads, classification and task receipts remain in `/Users/maxchan/Documents/Codex/2026-10-20/op/outputs/super-board-handoff/implementation-evidence/finish-20261021/issue-12-qa/`.

## Test-gap check

E1. Empty attached labels and absent repository phase labels are pinned by wave :121. Historical red proves this test can catch the reported symptom.

E2. Counts 0/1/2, stricter cap 0, invalid boolean count, duplicate owner, interrupted reservation and old cause history are pinned by budget :39/:69/:79 and wave :102/:211.

E3. Attached final cleanup and diagnosis/final/exhausted projection are pinned by wave :157/:181/:190. Dropping phase removal would leave `loop:repair-final` attached and fail the success test. Suppressing mutation errors or replaying would fail wave :139. Assertions observe literal intended counts and phases, not a recomputation through the production transition.

E4. One canonical record, unrelated `docs` label survival, malformed canonical state, readback and halt ordering are pinned by wave :121/:157 and budget :108/:122/:148/:155/:219. Existing source-string order checks are supplemental, not the sole proof.

No High gap was found. Test gaps not written: Medium, no dedicated combined witness starts with all three stale phase labels attached at once. Individual attached-phase cleanup and exact end states are covered. Money, dates, volume, form input, accessibility and UI states are n/a to the changed membership branch. No optional app verifier is installed. Its starter template is not run evidence.

## P3. Separate truth-check

H1. Canonical durability precedes display projection and dispatch. Held by source `scripts/super-board-repair.py:133-153`, wave `:242,282`, and the readback/halt tests.

H2. Unknown mutations remain fatal. Held by unchanged `check=True`, wave `:351-354`, and the lost-response witness. No failure is ignored or blindly replayed.

H3. Reservation ownership, cause history, counts and head-bound merge policy are unchanged. Held by the five-line product diff and the budget, wave and merge-gate suites. Read-only QA did not reserve or complete an attempt.

H4. The preserved live fixture remains halted. Issue #9 has canonical comment `6305789024`, last updated `2026-10-21T01:32:18Z`, with one idle/0 record and pending_lane=build. Attached labels remain `tests` and `loop:rebuild-0`. PR #11 remains draft/open at `fc109484c356e68b884447b25408740aa9879ea8`. Existing #7 worktree, both nested fixture roots and claims 8/9 remain in place. No fixture state, signal, claim, branch or PR was reset.

Standards pass: no scope expansion, source comment additions, copied pack files or helpers. Spec pass: AC1-4 have independent executable proof and AC5's preservation boundary holds. No auth, money or destructive-schema behavior changes. Graph tools and native subagents are unavailable, so preflight, classification and truth-check ran as distinct passes in this fresh lane. Review must use another fresh session.

Principle used: Prove It Works required historical red plus fresh installed-artifact and full-suite verification instead of accepting the Builder's report. No deployment, release tag, merge or live acceptance restart was attempted. Screenshots are intentionally omitted because this change has no UI.
