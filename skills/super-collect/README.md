# /super-collect

Finds problems in one project, checks each one, and writes one findings doc. Matt Pocock's
`/to-spec` turns that doc into a spec and `/to-tickets` turns the spec into tickets. Then 1–5
tickets go to `/implement-spec`; 6+ go to the super-board Backlog. See [routing](../../docs/super-board/routing.md).

## What It Does

- Reads pluggable sources: **sentry** (unresolved errors), **posthog** (exceptions, failure
  events, rage and dead clicks, slow pages, survey themes, tracking gaps), **github** (open issues
  not on the board, adopted rather than copied), **prs** (recurring problems across merged PRs and
  their human, bot and super-review comments) and **architecture** (read-only refactor finder).
- Checks every candidate with one fresh verifier: is it real, still happening, already fixed, or a
  duplicate. Unclear ones are filed with `needs-triage`, never silently dropped.
- Reports a source it cannot reach as `unavailable`, never `empty`: the Sentry and PostHog
  fetchers print `{"status":"unavailable","error":…}` and exit 2.
- Writes the findings doc to `docs/super-board/findings/collect-<YYYY-MM-DD>.md`, grouped by
  root cause (`scripts/collect_handoff.py`).
- No `/to-spec` or `/to-tickets` installed, or `--direct`: files each finding through
  `super-qa-file-bug.sh` and `super-review-file-refactor.sh`, always into the holding column,
  and says why. Nothing reaches `Ready` until `super-board lint` says so.

## Usage

| Command | Does |
|---|---|
| `/super-collect` | every source enabled in the config |
| `/super-collect sentry` | one source (or several) |
| `--since 30d` / `--since 2026-09-01` | window, default 14 days |
| `--yes` | write and file without the confirm step |
| `--direct` | skip `/to-spec` and `/to-tickets`; file straight into Backlog |

Dry-run is the default: you see the findings doc and the route, then confirm.

## Setup

`/super-board onboard` sets up the `collect` block per project: it detects Sentry and PostHog,
asks which sources to enable, writes IDs and hosts to the config, and tests each connection
read-only. Secrets stay in `.env`: `SENTRY_AUTH_TOKEN` (scopes `event:read project:read`),
`POSTHOG_PERSONAL_API_KEY` (`query:read`, `error_tracking:read`).

## Install

Ships in the super-board pack under `skills/super-collect/`; `install.sh` copies it to
`.claude/skills/super-collect/`. Needs a super-board config, `gh`, `jq` and Python 3 (stdlib only).

Tests: `python3 tests/test_collect_handoff.py` · `bash tests/test-collect-file.sh` · `bash tests/test-collect-fetchers.sh` ·
`bash tests/test-collect-baseline.sh` · `python3 tests/test_collect_baseline.py` (offline, all in
`tests/run-safety.sh`). The baseline suites replay the canned Sentry, PostHog and PR payloads in
`tests/fixtures/collect/`: fingerprint dedupe, ticket-format checks, the dry run, unreachable
sources.

Evals: the four `collect-*` cases in [`evals/`](../../evals/README.md) run the skill on a model
(paid, not in CI): Sentry verdicts, duplicate, PostHog gap, PR pattern.
