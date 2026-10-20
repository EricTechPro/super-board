# Issue 4 QA

## Preflight pass
- PR #5 head: `74b8d70037bfbd2121050548bdcd28058e8c8ad7`.
- Base: `codex/pi-pilot-20261020` at `ae886d7f9b6f20d5c6d41cee417fa1287c90a354`.
- Current issue and all issue/PR comments read through the guarded reader.
- All nine review threads contain author explanations only. No replies or QA findings. Pagination is complete.
- Existing branch and PR retained. No repair reservation supplied or consumed. Canonical repair state and repair labels remain unchanged.

## Classification and test plan
The confirmed seam is each real launcher CLI. Python unittest drives shell/Python launchers with recording external CLI stubs. No browser, service, authentication or production target applies.

| AC | Observable check | Unit | Component/integration | E2E CLI |
|---|---|---|---|---|
| AC1 | Mismatch refuses before startup effects, with identical checkout snapshots and zero external calls | n/a: boundary behavior | n/a: same real CLI seam | `tests/test_checkout_identity.py:116-131` |
| AC2 | Nonzero exit, both resolved roots, no traceback or readiness error | n/a: boundary behavior | n/a: same real CLI seam | `tests/test_checkout_identity.py:123-128` |
| AC3 | Absolute, symlink, subdirectory, relative, omitted/null and matching linked paths reach workers in the caller checkout | n/a: boundary behavior | n/a: same real CLI seam | `tests/test_checkout_identity.py:133-155` |
| AC4 | Old revision fails and corrected revision passes, across source/installed Pi/Codex lanes/waves and distinct linked worktrees | n/a: cross-process behavior | installation repair: `tests/test_checkout_identity.py:168-179` | `tests/test_checkout_identity.py:109-155` |
| AC5 | Independent regression and all configured safety suites pass | n/a: suite orchestration | `tests/run-safety.sh:14-37` | Review must rerun and use the unchanged head-pinned merge gate |

## Test-gap check
- Fill order: unit, component/integration, then E2E CLI. No AC relies on a unit mock as its only proof.
- Path classes pinned: sibling and linked mismatches, matching linked checkout, absolute/relative paths, symlink alias, caller subdirectory, omitted/null, blank/whitespace/non-string/NUL inputs (`tests/test_checkout_identity.py:116-165`).
- Startup ordering pinned with valid and empty verification commands. Filesystem hashes and Git status cover tracked files and runtime files outside Git metadata. GH/model recording asserts zero calls on refusal.
- Installation delivery and missing-helper repair are exercised through the real installer/setup entrypoints (`tests/test_checkout_identity.py:37-39,168-179`).
- Tests inspect real CLI exits, diagnostics, filesystem state and worker cwd. Recording stubs replace external services, not checkout validation. Expected roots come from fixture locations.
- Red capability checked on test-first commit `a2f109f`, before the guard existed. No product mutation or duplicate checker was needed.
- Test gaps (not written): low, filesystem mutation after validation is outside the startup-identity scope. Git object bytes are not snapshotted, but Git status is checked and the guard precedes operational Git writes by source inspection. No High gaps found.
- Optional project verifier absent. Ordinary issue AC checks remain authoritative.

## Truth-check pass
- Fresh historical run: `python3 tests/test_checkout_identity.py` on an archive of `a2f109f` exits 1 with 81 failing subcases. Valid paths pass. Mismatched direct lanes advance to QA and waves reach Done with recording stubs, reproducing the reported defect.
- Fresh current run: `python3 tests/test_checkout_identity.py` exits 0, four methods pass in 59.348 seconds. Its 137 subcases cover 32 mismatches, 56 valid paths, 48 invalid inputs and setup repair.
- Fresh full run: `bash tests/run-safety.sh` exits 0, all 69 suites pass with zero suite-error markers. The checkout regression passes again inside the full suite in 56.633 seconds.
- `git diff --check` and the base-to-head whitespace check pass. The merge gate, merge policy, repair engine and full-suite runner have no diff against the base.
- Source checks confirm refusal precedes readiness, hydration and runtime writes: Pi lane lines 58-69, Codex lane lines 94-106, shared wave lines 60-75. The helper compares canonical checkout directories, not common Git metadata.
- Full outputs retained at `/tmp/pi-issue-4-qa/{regression-red,regression-green,safety-full}.log`. `RESULTS.log` contains the captured result excerpts and full-log hashes. The full suite emits ResourceWarning/DeprecationWarning messages in unrelated tests, but no suite fails.
- Principles applied: Prove It Works selected the real source/installed CLI boundaries. Sequence work into verifiable units separated preflight, coverage classification, historical red, current green and the full suite.

## Handoff
QA passes its assigned checks. AC1-AC4 are proved. AC5 remains open only for the fresh Reviewer reruns and unchanged head-pinned merge gate. No product or test implementation changed. Review must rerun `python3 tests/test_checkout_identity.py && bash tests/run-safety.sh`. Screenshots intentionally omitted because all ACs concern command-line behavior. No deployment or release tag is authorized.
