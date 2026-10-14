# Optional runtime verification

Use this only for an issue that needs browser timing or memory evidence, or when
`config.runtime_verification.config` points to a project-owned comparison file.
It adds no lane, installation, scheduler, or all-PR profiling requirement.
Existing QA correctness tests remain the completion contract.

## What runs

The shared `../scripts/runtime_compare.py` starts the original and changed app
versions locally, waits for readiness, warms both, then runs at least five
measurements per side (configurable 5–50, warmups 1–10). Pair order alternates (AB, BA) to reduce order bias. Both
servers stay running; each browser sample uses a fresh browser/context, the same
scenario/data, viewport, locale, timezone and Chromium version. This is a **cold
browser action comparison**, not a warm-session benchmark. Specify another
project adapter if warm-session behaviour is the issue.

The runner reports medians, ranges, sample order, declared revisions, scenario/data
fingerprints, optional source-file hashes, actual git HEAD/dirty status where available,
failures and artifact paths. The browser adapter captures CDP heap
metrics before/after the action (after explicit GC), console/page errors and a
screenshot. Browser launch, initial navigation, tracing, screenshots, GC and CDP
sampling are outside the primary timing interval. Timing includes automation
latency in `run(page)`. Use separate diagnostic runs for expensive traces/heap
snapshots; never mix traced samples into primary timings.

A separated improvement above the configured tolerance is `faster`; a separated
regression is `slower`. High variability (range greater than 20% of its median or the absolute tolerance),
overlapping ranges with a material median difference,
insufficient samples, mismatched environments or failures are `inconclusive`.
Stable medians within tolerance are `unchanged` (within the chosen resolution,
not proof of equivalence). Results are descriptive, not statistical significance
or production latency guarantees. Heap values are retained JS heap snapshots,
not total process memory and not a leak verdict.

## Project-owned adapter config

Keep this JSON, seeded data, scenario and app dependencies in the owning project.
Paths below resolve from this file's directory. For a real change, use two clean
worktrees with pinned original/changed revisions. Build/seed both the same way.
Never silently snapshot a dirty checkout or mutate the original checkout.

```json
{
  "scenario_id": "search-results",
  "data_id": "fixed-search-fixture-v1",
  "environment_id": "local-chromium-same-build-mode",
  "scenario_files": ["search.mjs", "seed.json"],
  "scenario_command": ["node", "../../.claude/skills/super-qa/scripts/runtime_browser.mjs", "search.mjs"],
  "environment": {"SB_RUNTIME_PROJECT": "../.."},
  "repetitions": 5,
  "warmups": 1,
  "relative_tolerance": 0.1,
  "absolute_tolerance_ms": 5,
  "timeout_seconds": 30,
  "ready_timeout_seconds": 30,
  "baseline": {
    "cwd": "../../../original-worktree",
    "revision": "original-commit-sha",
    "source_files": ["package.json"],
    "start_command": ["npm", "run", "dev", "--", "--port", "4171"],
    "url": "http://127.0.0.1:4171"
  },
  "changed": {
    "cwd": "../../../changed-worktree",
    "revision": "reviewed-commit-sha",
    "source_files": ["package.json"],
    "start_command": ["npm", "run", "dev", "--", "--port", "4172"],
    "url": "http://127.0.0.1:4172"
  }
}
```

Choose tolerances from the issue, prior measurements or an explicit decision;
5 ms / 10% are conservative demo defaults, not a universal budget. Include every
scenario/data file in `scenario_files`; verify data, source revisions and build
mode yourself. List critical application inputs in each side's optional `source_files` for source hashes;
the report also records git HEAD and dirty status where available. Require a clean
worktree at the declared commit for real PR evidence. The runner fingerprints declared files; it cannot establish that
an arbitrary adapter actually used all inputs or that a supplied revision is true.
The two app commands may differ only as needed to bind separate local ports.
Environment overrides are shared, never side-specific. `SB_RUNTIME_PROJECT` must
resolve to the app with existing Playwright, package manifest and browser binary.
No fallback install is attempted. Node's project resolution accepts a relative
path from the config directory. Store no secrets in argv or evidence.

The scenario exports `async run(page)` and returns `{correct: true}` only after
asserting the expected result. Each run must use the same deterministic data,
including reset/seed where needed. Dynamic ports/data and uncontrolled workloads
can make a result inconclusive. The shared browser adapter handles fresh contexts;
a custom adapter must report its actual environment and follow equivalent isolation.

Any command adapter can replace the browser helper. It prints a single JSON object
with `correct` (boolean), `duration_ms` (finite nonnegative), `environment` (stable
object identifying its runtime), optional `memory_bytes` and diagnostic details.
`SB_RUNTIME_URL` and `SB_RUNTIME_ARTIFACT_DIR` identify the local target/evidence.
Commands run without a shell. Failures/timeouts are counted, never discarded into
a claim of success. Started server process groups are terminated on completion.
App URLs use HTTP, `localhost` or `127.0.0.1`, an explicit port, and no credentials.
Readiness and occupancy probes bypass host proxies. Redirects may stay on loopback;
an off-loopback destination is refused before a request is sent. Custom adapters
keep their own network policy. An occupied target URL is refused, including HTTP
error responses. This helper supports POSIX local process groups
and needs the system `ps` command for bounded inspection of live members. Cleanup
escalates the whole owned group, reaps the wrapper, and bounds pipe draining.
Empty/zombie-only groups are not signalled; reused/foreign groups are refused.
Live processes that cannot be cleaned produce an explicit failure and preserve
an inconclusive report. Custom adapters must not daemonize into detached sessions.

## QA and Review handoff

```bash
python3 .claude/skills/super-qa/scripts/runtime_compare.py \
  --config docs/runtime/search.json --output docs/super-board/runs/issue-N-qa-v1/runtime
```

The output directory must be new; old evidence is never overwritten. Attach
`report.json` through the existing QA evidence handoff. Give the command under
`Runtime checks:` alongside `Local tests:`; name the scenario, baseline/changed
revisions, input/config hashes, medians/ranges, correctness failures and verdict.
Only claim the relevant acceptance criterion when correctness passes and its
actual budget is met. `inconclusive` provides no speed proof. A correctness
failure bounces to Builder using the normal QA flow. A measured slowdown fails a
performance AC only if the issue specifies that requirement. Memory evidence
needs its own explicit budget/criterion.

Reviewer reruns the same config/scenario against the same pinned versions into a
**new** review evidence directory. Check input hashes and actual revisions/build
mode against QA, then compare results; changed head or inputs invalidate the
previous evidence. Keep ordinary test reruns mandatory. This is the existing
QA/Review loop, not a new approval mechanism.

A project can add its deterministic adapter wrapper to existing `verify_commands`
when the issue justifies a merge check. The helper exit code is 2 for execution,
correctness or measurement failures, but 0 for a valid measurement including
`slower`/`inconclusive`: a project wrapper must evaluate the report against its
explicit acceptance budget and fail when it is not met. Never treat exit 0 as
proof of speed. Profiling need not run inside every merge lock.

## Real browser demonstration

From the pack checkout, with Playwright already installed in an app:

```bash
python3 skills/super-qa/examples/runtime-demo/demo.py \
  --playwright-project /absolute/path/to/app --output /new/evidence/folder
```

The demo starts original/changed versions of the same small local app, checks the
same total from the same data, alternates five samples each and saves CDP evidence.
It reduces deliberate work from 180 ms to 30 ms; this demonstrates measurement,
not a production optimization. `--changed-delay 180` gives unchanged/noisy evidence;
`--changed-delay 400` demonstrates slower. Neither downloads nor installs anything.
