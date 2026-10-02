# /super-collect

Turns errors, user reports and past-run failures into deduped Backlog cards on your super-board.

## What It Does

- **Intake** reads app errors (Sentry or whatever error tool is wired), open GitHub issues that are
  not on the board, and feedback. It groups them by symptom, dedupes against existing cards, and
  files typed cards (bug, feature, refactor) with evidence. Existing issues are adopted onto the
  board, not copied.
- **Lookback** reads past wave reports and Reviewer reports, finds cards that keep bouncing,
  findings that come back after a claimed fix, and repeated halts, and files one fix ticket per
  root cause with acceptance criteria.
- Filing goes through `super-qa-file-bug.sh` and `super-review-file-refactor.sh`, always into the
  holding column. Nothing reaches `Ready` until `super-board lint` says so.

## When To Use It

- Before a `super-board run`, when the Backlog is thin and the error tool is not.
- After a few runs, when the same cards keep coming back.

## Modes

| Command | Does |
|---|---|
| `/super-collect` | intake, then lookback |
| `/super-collect intake` | errors, unboarded issues, feedback |
| `/super-collect lookback` | past runs and Reviewer reports |
| `... --yes` | file without the confirm step |

Dry-run is the default: you see what would be filed, then confirm.

## Install

Ships in the super-board pack under `skills/super-collect/`. Copy it to `.claude/skills/super-collect/`
alongside the other super-board skills; it calls the pack's filers from `.claude/bin/` (or
`$SUPER_BOARD_BIN`). Needs a super-board config (`/super-board onboard`), `gh`, and `jq`.

Test: `bash tests/test-collect-file.sh`
