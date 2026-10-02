---
name: super-collect
description: Collect work and file it as tickets on the super-board GitHub Project, into Backlog only. Two sources — intake (app errors from Sentry or the project's error tool, user-filed GitHub issues not on the board, feedback) and lookback (repeat problems across past wave reports and Reviewer reports). Dedupes against existing cards, dry-run by default. Use when the user says "super-collect", "/super-collect", "collect tickets", "triage errors onto the board", "what keeps breaking", or "look back over the runs".
---

# super-collect — fill the Backlog from real signals

The one door onto the board for work nobody has filed yet. It sorts, dedupes and files; it never
builds, and it never moves a card to `Ready` — `super-board lint` decides that.

Adapted from BuilderIO/skills (MIT) — `factory-collect` and `factory-lookback`.

## When to use

- Before a `super-board run`, to turn errors and user reports into cards.
- After a few runs, to find what keeps bouncing and file the fix once.
- Not for one card you already understand — write it yourself, or use `super-board lint` on it.

## Modes

| Invocation | Sources |
|---|---|
| `/super-collect` | intake, then lookback |
| `/super-collect intake` | errors, unboarded issues, feedback |
| `/super-collect lookback` | `paths.runs_dir` wave reports + Reviewer reports on PRs |
| any of the above `--yes` | file without the confirm step |

Default is **dry-run**: show the plan table, file on confirm. `--yes` skips the confirm, never
the dedupe.

## Setup

1. Resolve the active config: `.claude/super-board/active` → `.claude/super-board/configs/<slug>.json`
   (shape: `../super-board/references/config-schema.json`). Read `project.{owner,number,title}`,
   `repo.remote`, `paths.runs_dir` (default `docs/super-board/runs`). No config → stop and point
   at `/super-board onboard`.
2. Source `.claude/bin/super-board-gh-guard.sh` and `sb_gh_guard_check 200` before each burst.
3. Snapshot the board once: `gh project item-list <number> --owner <owner> --format json --limit 500`.
   That list is the dedupe set for the semantic pass and the "not on the board" set for intake.

## Intake — real-world signals

Auto-detect each source; record it as `read (n)`, `empty`, `unavailable` or `truncated`. Never
report a missing connector as empty.

| Source | Detected by | Read |
|---|---|---|
| Errors | `SENTRY_AUTH_TOKEN` + org/project in env or root `.env`, `.sentryclirc`, or a connected Sentry MCP; otherwise any error-tool MCP/CLI the project has wired (Bugsnag, Rollbar, …) | unresolved issues, last 14 days, every page; keep id, count, users, first/last seen, release, link |
| Issues | always | `gh issue list --state open --json number,title,body,labels,url --limit 300`, minus issue numbers already on the board, minus `source:qa`/`source:review`/`source:collect` |
| Feedback | `docs/feedback/` or `feedback/` in the repo, or a connected support/feedback MCP | items since the last collect run |

Then:

1. **Classify** each item: `bug` (verified defect), `feature`, `refactor`, `duplicate`,
   `needs-info`, or `drop` (noise, out of scope). Group items that share a symptom and a code
   boundary; one card per group, every source link kept.
2. **Semantic dedupe** against the board snapshot and open issues: same symptom + same
   route/module = same card. A match becomes a comment on that card with the new evidence, not a
   new card.
3. **Issues get adopted, not copied.** An unboarded issue that is real work is placed with
   `--adopt <n>`; its author keeps the thread.
4. **Write the body.** Bugs use super-qa's required template (`../super-qa/SKILL.md` → "Required
   issue body template": Summary, Repro steps, Expected/Actual behavior, Evidence, Suggested fix
   path, Acceptance criteria) — the filer rejects bodies missing any of them. Features need
   Summary, Evidence, Acceptance criteria. Evidence is links and counts, never secrets or user PII.
5. **Fingerprint** — stable across runs: `err|<tool>|<tool-issue-id>`, `fb|<source>|<item-id>`,
   or `intake|<route-or-module>|<symptom-slug>` when nothing has a stable id.

`needs-info` items are not filed; list them in the report with the one question that would
unblock each.

## Lookback — across past runs

Bounded evidence: the last 10 run files (or `--since <date>`), and Reviewer reports on PRs merged
or closed in the same window.

```bash
# Card outcomes, one row per card per wave: | #N | lanes | finalStatus | column | detail |
grep -hE '^\| #[0-9]+ ' "$RUNS_DIR"/*.md | awk -F'|' '{print $2}' | sort | uniq -c | sort -rn   # waves per card
grep -hE '^\| #[0-9]+ ' "$RUNS_DIR"/*.md | awk -F'|' '$4 !~ /done|merged/ {print $2"|"$6}'      # non-landing outcomes

# Reviewer reports (finding ids R1…), one PR at a time
gh pr view <PR> --json comments \
  --jq '[.comments[] | select(.body | contains("<!-- super-review:report -->"))] | .[].body'
```

Plus the machine lines on issues and PRs: `root-cause-hash:` (lane failures) and `blocked-by:`
with its reason tag (halts).

Look for, in order of signal:

1. **Bouncers** — a card in 3+ waves without reaching Done, or two failures sharing a
   `root-cause-hash`.
2. **Recurrent findings** — a Reviewer finding marked `fixed` that returns as `not fixed` in a
   later report, or the same finding shape (same module, same rule) on different PRs.
3. **Repeated halts** — the same Block reason tag or halt gate (`no_progress_cycles`, block-rate,
   merge-gate rebase) across runs.

Cluster by **root cause at a shared boundary**, not by wording. For each cluster, trace one
representative case to code, check whether a claimed fix landed, and separate the confirmed cause
from hypotheses. **One fix ticket per root cause** — `--type fix` (a `refactor` when the cause is
module shape), fingerprint `lookback|<boundary>|<cause-slug>`, body with Summary, Evidence (every
card, PR, finding id and run file it explains), Root cause, Acceptance criteria. At least one
criterion must be a regression check that would have caught the recurrence.

A thin history is not evidence of no pattern. Say how many runs and PRs were read.

## Filing

Every card goes through one script, which routes to the pack's existing filers:

```bash
.claude/skills/super-collect/scripts/super-collect-file.sh --config <cfg> \
  --type bug|feature|refactor|fix --source intake|lookback \
  --title "<one line>" --body-file <md> --fingerprint "<key>" [--priority p] [--area a] [--yes]
.claude/skills/super-collect/scripts/super-collect-file.sh --config <cfg> --adopt <n> --type <t> [--yes]
```

- `bug`, `feature`, `fix` → `super-qa-file-bug.sh` (`fix` files as `tech-debt`);
  `refactor` → `super-review-file-refactor.sh`. Both keep their own guards and Blocked-by default.
- **Dedupe** is exact-fingerprint, repo-wide, any label: an open hit gets a "Seen again" comment and
  its number back; a closed-only hit is a **recurrence** — filed again with a line naming the
  closed issue.
- **Column** is the board's holding column (`Backlog`, else `Todo`/`To do`/`Triage`/`Inbox`),
  resolved before dispatch and passed explicitly. A board with none is refused (exit 65), because
  both filers would fall back toward `Ready`.
- Labels: `source:collect`, `collect:<intake|lookback>`, plus the filer's own.

Dry-run flow: run each item without `--yes`, collect the plan lines, show one table
(`would-file` / `duplicate` / `recurrence` / `would-adopt`), wait for confirm, then rerun with
`--yes`.

## Report

```
## super-collect: <filed n | dry-run n> · <mode>
Coverage   errors: read 42 | issues: read 7 | feedback: unavailable | runs: 10 files, 23 PRs
Filed      #412 bug  Checkout 500 on empty cart          (err|sentry|4411)
Duplicate  #301 ← Sentry 4502 (comment added)
Recurrence #418 fix  Merge gate rebases on lockfile drift (was #88)
Needs info Sentry 4490 — which tenant? (not filed)
Next       /super-board lint  — nothing here is in Ready
```

## Common pitfalls

- Filing one card per error event. Group by symptom and boundary first.
- Treating a Reviewer's `fixed` as proof. Recurrence is decided by the next report, not the claim.
- Copying a user's issue into a new one. Adopt it.
- Moving anything to `Ready`, or "helping" by writing code. Collect files; lint and run do the rest.
