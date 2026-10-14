# Project verifier: create, maintain, run

Use this contract when Onboard can seed a repo-backed app verifier, QA finds an
existing `.agents/skills/verify-<app>/` map, or its instructions need upkeep.
Keep the project's runner, issue AC checks, independent Review and merge policy.
This optional helper adds repeatable feature checks inside existing lanes.

## Create during Onboard

1. Read the owning app's instructions, package commands, current source, tests
   and decisions. Detect existing verifier skills and maps before staging files.
2. Pick three to five important features with real source owners and accepted
   behavior witnesses. Preserve human-owned `critical-paths.md` and `flows.md`.
   Insufficient source or setup means leave the optional verifier absent and
   state the missing evidence. A starter template proves no app behavior.
3. Adapt `../templates/project-verifier/SKILL.md` and `feature-map.json` into
   `.agents/skills/verify-<app>/`. Write real project-owned scenarios and a runner
   beside it. Use the app's installed runner; browser/dependency installs and DB
   initialization remain separate project decisions. Where supported, Claude
   may use a relative `.claude/skills/verify-<app>` compatibility link.
4. Stage the files for Onboard's existing step-8 Save. List them in its review;
   write only with that save authorization. Keep `verify_commands` independent:
   a map does not turn browser work into every PR's required merge check.
5. Inspect the saved map with the public helper below. Resolve the actual local
   skill with `super-board-skills-ready.py --require verify-<app>` for the active
   host before loading it. A folder or valid map alone proves no host readiness.

Templates are unfinished scaffolds: the empty feature array must be replaced.
Onboard reports `starter, not run` until actual scenarios run with proof.

## Map inspection and selection

```bash
python3 .claude/bin/super-board-project-verifier.py inspect \
  --root . --map .agents/skills/verify-app/references/feature-map.json
python3 .claude/bin/super-board-project-verifier.py select \
  --root . --map .agents/skills/verify-app/references/feature-map.json \
  --changed - --feature cart.checkout
```

Pipe a JSON array of repo-relative changed paths to `--changed -`, or supply a
repo-relative JSON file. `[]` supports explicit feature selection alone. The
helper validates structure and selects IDs; it executes no scenario. Exit 0
means valid inputs, 9 means missing/stale/unreadable setup, 64 means malformed
input. Unknown IDs fail. Empty selection proves no feature.

Version 1 fields:

| Field | Contract |
|---|---|
| `version`, `app`, `skill` | integer `1`, nonempty app name, repo-relative canonical `SKILL.md` |
| `features` | nonempty array; unique stable `id` and nonempty `description` |
| `route`, `witness` | route or non-browser entry point; existing test/decision reference |
| `owners` | nonempty repo-relative path/glob array; at least one existing file per feature |
| `scenario` | nonempty readable project-owned scenario file |
| `expected`, `side_effects` | nonempty text or string array; observable assertions and explicit mocks/absence |

Extra project fields are retained in the map but not interpreted. Globs are
root-anchored, case-sensitive; `*` stays in one path component and `**` spans
zero or more. Shared owners select several features. Deleted changed paths
still match. Output contains ordered IDs, uncovered paths, canonical relative
map/skill/scenario paths and hashes of their actual bytes, never file contents.
Absolute/traversal/NUL paths and input symlinks escaping the repo are rejected.
Owner globs must not traverse symlinks outside the repo.

## Run affected features

QA reads ACs, diff, map and latest source to choose relevant features. With no
map, use ordinary QA. Missing or stale optional coverage goes in the handoff;
it never counts as a green test and creates no new board-wide halt. If a relevant
verifier cannot run, keep its ACs unverified until another valid check proves
them. Resolve its skill for the current host before loading it, for example:

```bash
python3 .claude/bin/super-board-skills-ready.py --root . --host codex \
  --cards cards.json --lane qa --require verify-app
```

`cards.json` is the current hydrated card selection accepted by the resolver.
Keep the active host/catalog options from the lane's readiness check.

The app owns its runner interface. Document `doctor`, affected selection and an
explicit full sweep, such as `run --feature <id> --output <new-directory>` and
`run --all`. Complete these operations in order:

1. **Select:** record IDs, uncovered changed paths and additional issue AC checks.
2. **Doctor:** verify owning checkout/revision, installed runner/browser, allowed
   local target, fixture/reset mode, new output directory and process ownership.
   Check setup without reading credentials.
3. **Launch:** use a private port and the documented command; refuse occupied
   ports, wait for real readiness, record actual checkout and command.
4. **Drive:** reset each scenario with a fresh context or equivalent; use semantic
   or test-ID controls, deterministic inputs and bounded waits.
5. **Inspect:** assert visible behavior and relevant persisted/network effects.
   Separate mocked effects from observed ones. Capture console/page/request
   errors; allowances name only deliberately injected failures.
6. **Proof:** record each feature's assertions and passed/failed/not-run result,
   actual HEAD and dirty state, input/scenario/manifest hashes, target/environment,
   exact rerun command, screenshots/logs and limits. Put rebuilt output in the
   project's dated scratch location; keep canonical inputs in source history.
7. **Cleanup:** close contexts and stop only owned processes. Preserve failing
   proof. Cleanup failure makes the run fail.

Keep the existing `Local tests:` command and per-AC proof in QA's handoff; add
selected verifier results and uncovered paths there. Follow the project's
privacy and existing screenshot publishing rules. Reviewer reruns relevant
checks on the reviewed head into fresh output and compares revisions/hashes.
Old-head proof cannot approve changed code.

## Maintain on demand

Triggers: explicit upkeep request, changed mapped source, setup/selector failure,
unmapped important feature, or an authorized expectation change. Read current
source and the live local app against issue ACs, witnesses and newest decisions.

| Finding | Response |
|---|---|
| Stale instructions | Accepted behavior still holds; fix obsolete route/control/launch guidance or selector, preserve assertions, rerun affected IDs. |
| Harness gap | Repair wrong fixtures/environment/selector, escaped requests, reused server or pre-behavior timeout; otherwise report setup blocked. It proves no product bug. |
| Product regression | Preserve failing evidence for the unchanged accepted behavior; return through Builder/QA and localize the regression test using the project's testing ladder. |
| Accepted product change | Cite explicit issue/decision authorization before changing expected values; record before/after rationale and rerun proof. |

Report old/new guidance, reason/source, selected rerun and evidence. Preserve
failing mapped features and behavior assertions. Never copy observed output into
expectations or weaken checks to obtain green. No whole-app sweep on every PR,
private-history scan, new worker lane or new lifecycle is required.
