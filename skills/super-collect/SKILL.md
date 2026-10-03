---
name: super-collect
description: Find problems in one project and file them as tickets into its super-board Backlog — the board fixes them. Source plug-ins - sentry (app errors), posthog (exceptions, rage/dead clicks, failure events, web vitals, tracking gaps), github (issues not on the board), prs (recurring problems in merged PRs and their review comments), architecture (refactor findings), plus any custom source added in onboard (an MCP server, HTTP API, CLI command or app). Each candidate is checked by one fresh verifier before filing. Dry-run by default. Use when the user says "super-collect", "/super-collect", "/super-collect sentry", "collect tickets", "triage errors onto the board", "what keeps breaking", or "find refactors".
---

# super-collect — find problems, file them into Backlog

One job: find problems and file tickets into the board's **Backlog**. The board fixes them.
super-collect never builds, never edits app code, and never moves a card to `Ready` —
`super-board lint` decides that. Per project only: it reads the active project's super-board
config and files onto that project's board.

## Invocation

| Command | Does |
|---|---|
| `/super-collect` | every source enabled in `collect.sources` |
| `/super-collect <source> [<source>…]` | just those: `sentry`, `posthog`, `github`, `prs`, `architecture`, or a custom source's `name` |
| `--since 30d` / `--since 2026-09-01` | window; default `collect.window_days`, else 14 days |
| `--yes` | file without the confirm step (never skips verify or dedupe) |

Default is **dry-run**: show the plan table, file on confirm.

## Setup

1. Resolve the config: `.claude/super-board/active` → `.claude/super-board/configs/<slug>.json`
   (shape: `../super-board/references/config-schema.json`). No config, or no `collect` block for a
   requested source → stop and point at `/super-board onboard` (its collect step sets sources up).
2. Secrets come only from `.env` (nearest walking up): `SENTRY_AUTH_TOKEN`,
   `POSTHOG_PERSONAL_API_KEY`. Never print, echo or paste them.
3. Source `.claude/bin/super-board-gh-guard.sh`; `sb_gh_guard_check 200` before each gh burst.
4. Snapshot the board once: `gh project item-list <number> --owner <owner> --format json --limit 500`.
   It is the dedupe set for verification and the "not on the board" set for `github`.

Scripts live in `.claude/skills/super-collect/scripts/` (`S=` below). Every fetcher takes
`--since` and prints JSON; a fetcher that cannot reach its source prints
`{"status":"unavailable","error":…}` and exits 2. Record each source as `read (n)`, `empty`,
`unavailable` or `truncated` — never report an unreachable source as empty.

## Sources

| Source | Fetch | Candidate → ticket |
|---|---|---|
| `sentry` | `python3 $S/collect_sentry.py list --since <w>` — Sentry REST, Bearer token (scopes `event:read project:read`): org issues list, then `event <id>` / `tags <id>` for evidence | one unresolved issue → `bug`, fp `err|sentry|<id>` |
| `posthog` | `python3 $S/collect_posthog.py list --since <w>` — HogQL `POST {host}/api/projects/{id}/query/` | one signal group → see table below |
| `github` | `gh issue list --state open --json number,title,body,labels,url --limit 300`, minus issues on the board and `source:*` labels | real work → **adopt** (`--adopt <n>`), never copied |
| `prs` | `python3 $S/collect_prs.py list --since <w>` — one GraphQL search `is:pr is:merged merged:>=DATE`, paginated, with comments, reviews and review threads (human and bot), super-review reports flagged (`<!-- super-review:report -->`) | one recurring root cause → `fix` / `refactor` / `feature`, fp `prs|<boundary>|<cause>` |
| `architecture` | read-only finder sub-agent (below) | one finding → `refactor`, fp `arch|<module>|<problem>` |
| custom (`collect.custom[]`) | `python3 $S/collect_custom.py list --since <w>` — http and cli sources run in the script; an `mcp` source comes back `status: agent`: call that server's read/list tool yourself (read-only), then pipe its JSON into `collect_custom.py normalize --name <n>` | one candidate → `bug` (errors, incidents) or `feature` (requests), `--source custom`, fp `custom|<name>|<key>` (the script emits it) |

### custom sources

Added in onboard's "➕ Add another source" (`super-board onboard` → 📥 Bug sources): the user types a
link, an app name, an API URL, an MCP server or a command; `collect_custom.py classify` decides
which, `ping` proves it can be read (read-only) and `add` saves `{name, kind, target, auth_env?,
map?}` to this project's config and its `name` to `collect.sources`. Here they run like any other
source: every candidate goes to the same verifier and the same filer. A source that cannot be
reached is `unavailable`, never `empty`. A command that looks like it changes something is refused
by the script — never work around that.

### posthog signals

The signal set is a table in `collect_posthog.py` (`SIGNALS`) plus the config's
`collect.posthog.failure_events`; narrow it with `collect.posthog.signals`.

| Signal | Grouped by | Files when | Ticket |
|---|---|---|---|
| `exception` | `$exception` by `issue_id` (follows merges) | ≥ `min_users` (5) people | `bug`, label `error` |
| failure events | each configured `{event, fail}` (e.g. `push_completed` with `properties.status = 'failed'`) | ≥ 5 people, or failing-people rate ≥ `failure_rate` (10%) | `bug`, label `error` |
| `rageclick` | `$rageclick` by URL + element | ≥ 5 people | `bug`, label `ux` |
| `dead_click` | `$dead_click` by URL + element | ≥ 5 people | `bug`, labels `ux`, `needs-triage` (high false-positive rate) |
| `web_vitals` | p75 per pathname | ≥ 50 samples and p75 LCP > 4 s, INP > 500 ms or CLS > 0.25 | `bug`, label `perf` |
| `survey` | raw `survey sent` responses (only when surveys exist) | you theme them; one theme from ≥ 3 people | `feature` |

Each candidate carries a `replay` link (latest `$session_id`) — put it in Evidence. Funnel
drop-off and abandonment spikes are **report only**: `collect_posthog.py funnel --since <w>` →
`<paths.runs_dir>/collect-funnel-<YYYY-MM-DD>.md`. No tickets from them.

**Tracking gaps** (posthog runs only). `collect_posthog.py events --since <w>` lists every event
seen plus `silentSignals`. Find the app's key user workflows from its routes and existing
`capture()` calls; for each, list the success and failure events that are missing and the
signals that return no data (e.g. autocapture off ⇒ no `$rageclick`). File one `feature` ticket
per workflow with gaps, label `analytics`, fp `gap|<workflow>` — Problem, Context (routes, the
capture calls found, what is missing), Fix, Acceptance Criteria (named events with their
properties), Risk.
Suggestions stay perf- and privacy-safe: sampling, clicks only, no input or text capture, no PII
in properties. Never edit app code.

### prs — what to look for

Read the JSON for problems that **recur**, not one-off nits:

1. The same finding shape (same module, same rule) on two or more PRs — from human reviewers,
   bots or super-review reports.
2. A super-review finding marked `fixed` that comes back `not fixed` in a later report.
3. Unresolved review threads on merged PRs that point at a real defect.
4. A skill, prompt or workflow whose reports keep missing the same thing → a `feature` to refine it.

Cluster by **root cause at a shared boundary**, not by wording. One ticket per cause with
Problem, Context, Evidence (every PR, comment link and finding id), Fix (names the root cause),
Acceptance Criteria, Risk — at least one criterion is a regression check that would have caught
the recurrence.

### architecture — the finder

Spawn one fresh, **read-only** sub-agent (it edits nothing and commits nothing). It uses, in order
of what is installed: mattpocock `improve-codebase-architecture` (skip its HTML report and
grilling; findings only) or `codebase-design` (module, interface, depth, seam, deletion test),
plus `ponytail:ponytail-audit` for over-engineering. It reads `CONTEXT.md` and `docs/adr/` and
does not re-open a recorded decision; recently changed files weigh higher. It returns
`{module, problem, finding, files, why, severity}`; each finding = one `refactor` ticket with
Problem, Context (files, the shallow interface or duplicated concept), Fix, Acceptance Criteria
(observable, plus "existing tests still pass"), Risk. Cap at `collect.architecture.max_findings` (5).

## Verify — one fresh verifier per candidate

Before anything is filed, each candidate goes to **one** fresh verifier sub-agent. No for/against
panel, no debate — one verifier, one verdict. Give it the candidate JSON, the board snapshot path
and the window; nothing from other candidates. It checks, in order:

1. **Real** — the evidence holds up: open the Sentry event / replay / PR comment / code it cites.
2. **Still happening** — `collect_sentry.py check <id> --after <window start>` (`seenAfter`), or
   `collect_posthog.py check <signal> <key> --after <date>` (`stopped`, `issueStatus`).
3. **Already fixed** — a closed issue or merged PR that matches
   (`gh pr list --state merged --search "<symptom> in:title,body"`, plus the fingerprint), and
   then from the fix's merge date or release: Sentry `status: resolved` with `seenAfterRelease:
   false`; PostHog `stopped: true` (zero hits and ≥ 3 days of traffic since the merge; with
   `version_property`, no hits on versions after the fix). A refactor already landed counts too.
4. **Duplicate** — same symptom + same route/module as a card in the snapshot or an open issue.

Verdict schema: `{verdict: file | drop-fixed | drop-stale | drop-noise | duplicate | needs-triage,
evidence: [links], note}`. `duplicate` names the card; the filer then comments on it. **Unclear is
not a drop**: `needs-triage` files the card with `--label needs-triage`. Report every drop with its
evidence.

## Filing

Every card goes through one script, which routes to the pack's filers:

```bash
$S/super-collect-file.sh --config <cfg> --type bug|feature|refactor|fix \
  --source sentry|posthog|github|prs|architecture|custom --title "<one line>" --body-file <md> \
  --fingerprint "<key>" [--priority p] [--area a] [--label needs-triage] [--label ux] [--yes]
$S/super-collect-file.sh --config <cfg> --adopt <n> --type <t> [--yes]
```

- `bug`, `feature`, `fix` → `super-qa-file-bug.sh` (`fix` files as `tech-debt`); `refactor` →
  `super-review-file-refactor.sh`. Every body uses the ticket format in
  `.claude/skills/super-board/references/writing-standard.md` § 3: Problem · Context (lettered
  steps under Where) · Fix · Acceptance Criteria (checklist) · Risk; bugs add the folded 12-row
  Evidence table (a missing row says `n/a — why`), fixes add an Evidence section. Evidence is
  links and counts — never secrets or user PII. The filer refuses a body that misses a section.
- **Fingerprint per source** (the filer rejects a mismatch): sentry `err|sentry|<id>`, posthog
  `posthog|<signal>|<key>` (fetchers emit it) or `gap|<workflow>`, github `github|<n>`, prs
  `prs|<boundary>|<cause>`, architecture `arch|<module>|<problem>`, custom `custom|<name>|<key>`.
- **Dedupe** is exact-fingerprint, repo-wide, any label: an open hit gets a "Seen again" comment; a
  closed-only hit is a **recurrence**, filed again naming the closed issue.
- **Column** is the board's holding column (`Backlog`, else `Todo`/`To do`/`Triage`/`Inbox`); none
  → refused (exit 65).
- Labels: `source:collect`, `collect:<source>`, every `--label`, plus the filer's own.

Dry-run: run each verified item without `--yes`, show one table (`would-file` / `duplicate` /
`recurrence` / `would-adopt`, plus the verifier's drops), wait for confirm, rerun with `--yes`.

## Report

```
## super-collect: <filed n | dry-run n> · since 2026-09-18 (14d)
Coverage   sentry: read 42 | posthog: read 9 (silent: rageclick) | github: read 7 | prs: 23 PRs, 6 reports | architecture: 4 | linear: read 12
Filed      #412 bug       Checkout 500 on empty cart              (err|sentry|4411)
Filed      #413 bug       Dead clicks on /pricing  [needs-triage]  (posthog|dead_click|1a2b3c4d5e6f)
Duplicate  #301 ← Sentry 4502 (comment added)
Recurrence #418 fix       Merge gate rebases on lockfile drift     (was #88)
Dropped    Sentry 4490 drop-fixed — resolved in web@1.4.0, not seen since (PR #377)
Gaps       #420 analytics Receipt upload: no failure event         (gap|receipt-upload)
Report     docs/super-board/runs/collect-funnel-2026-10-02.md
Next       /super-board lint  — nothing here is in Ready
```

## Common pitfalls

- Filing one card per error event. Group by symptom and boundary first.
- Skipping the verifier because the count looks big. Volume is not proof it is still happening.
- Dropping an unclear candidate. File it `needs-triage`.
- Copying a user's issue into a new one. Adopt it.
- Treating a reviewer's `fixed` as proof. Recurrence is decided by the next report.
- Editing app code, adding instrumentation, or moving anything to `Ready`. Collect files; lint and run do the rest.
