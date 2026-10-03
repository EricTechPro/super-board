# /super-collect

Finds problems in one project and files them as deduped Backlog cards on its super-board. The
board fixes them.

## What It Does

- Reads pluggable sources: **sentry** (unresolved errors), **posthog** (exceptions, failure
  events, rage and dead clicks, slow pages, survey themes, tracking gaps), **github** (open issues
  not on the board, adopted rather than copied), **prs** (recurring problems across merged PRs and
  their human, bot and super-review comments) and **architecture** (read-only refactor finder).
- Checks every candidate with one fresh verifier: is it real, still happening, already fixed, or a
  duplicate. Unclear ones are filed with `needs-triage`, never silently dropped.
- Files through `super-qa-file-bug.sh` and `super-review-file-refactor.sh`, always into the
  holding column. Nothing reaches `Ready` until `super-board lint` says so.

## Usage

| Command | Does |
|---|---|
| `/super-collect` | every source enabled in the config |
| `/super-collect sentry` | one source (or several) |
| `--since 30d` / `--since 2026-09-01` | window, default 14 days |
| `--yes` | file without the confirm step |

Dry-run is the default: you see what would be filed, then confirm.

## Setup

`/super-board onboard` sets up the `collect` block per project: it detects Sentry and PostHog,
asks which sources to enable, writes IDs and hosts to the config, and tests each connection
read-only. Secrets stay in `.env`: `SENTRY_AUTH_TOKEN` (scopes `event:read project:read`),
`POSTHOG_PERSONAL_API_KEY` (`query:read`, `error_tracking:read`).

## Install

Ships in the super-board pack under `skills/super-collect/`; `install.sh` copies it to
`.claude/skills/super-collect/`. Needs a super-board config, `gh`, `jq` and Python 3 (stdlib only).

Tests: `bash tests/test-collect-file.sh` · `bash tests/test-collect-fetchers.sh`
