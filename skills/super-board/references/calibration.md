# Optional learning after a completed run

When `calibration.enabled` is true, the supervising host automatically delegates
a separate learning task to an **already installed external skill** after verified
selected work finishes. The package does not copy, install, or publish that skill.
The default is disabled. Configure `mode: "apply-existing"` and explicit existing
canonical `SKILL.md` edit paths before enabling it.

## Completion gate

A board process exiting 0, a Done count, or a worker claiming `advanced` is not
completion evidence. The host must perform the existing final reconciliation:
confirm each selected PR merged, record its actual reviewed and merge commits,
fetch the base and prove the merge landed, and retain the check/review receipts.
Every selected issue must be accounted for, with no active lane workers, pending
approval, Blocked card, partial delivery, or halt. An empty board with no landed
work does not trigger calibration. Closed-as-not-planned cards are not merges.
After confirming all waves/tasks ended, the host releases only its own native
`workflow-wave.lock`, matching the run identity it saved at creation. Numeric
lane locks, the native workflow marker, or a Codex wave marker still present
mean unfinished work. An uncertain/other host's marker is preserved and learning
is skipped; the adapter never clears or reaps markers.

The adapter validates these references and checks commit existence and ancestry
against the **locally recorded remote base**. It does not independently query
GitHub, fetch the base, re-run tests, or certify the contents of a caller's report.
Missing or stale final evidence means skipped, not calibrated.

## Prepare a bounded receipt

After normal completion, the host writes a version 1 `completion.json` inside
`<paths.runs_dir>/<run_id>/` (runs_dir defaults to `docs/super-board/runs`). Keep
only this run's evidence in that directory. The receipt contains:

| Field | Required content |
|---|---|
| `run_id` | A unique run name starting with a letter/digit, then letters, digits, dots, underscores or hyphens; at most 80 characters |
| `source` | `final-reconciliation` |
| `outcome` | `completed` |
| `selected_issues` | Unique positive issue numbers selected for this run; at most 100 |
| `active_workers`, `pending` | Empty lists, established by final reconciliation |
| `manifest` | Existing nonempty current-run manifest path |
| `cards` | Exactly one entry per selected issue |
| Each card | `number`, `state: "merged"`, positive `pr`, concrete `pr_url`, actual 40-character `reviewed_head_sha` and `merge_sha`, nonempty `evidence_files` |

The local merge commit must be on `refs/remotes/origin/<base_branch>`. The host
has already fetched that ref during merge confirmation. Evidence references must
resolve inside the current run directory; symlink escapes are refused. Use short
sanitized excerpts of relevant review findings, retries, test/runtime receipts,
and explicitly supplied user corrections. Do not copy personal chats, other
runs, secrets, or unrelated project evidence. A receipt is at most 64 KiB;
each evidence file at most 32 KiB, with at most 32 files and 128 KiB total.
The helper reads metadata, not a personal chat corpus.

## Delegate the installed skill

From the project root, with `BOARD_CONFIG` naming the active JSON config and
`RUN_RECEIPT` naming the completed receipt:

```bash
python3 .claude/bin/super-board-calibration.py --config "$BOARD_CONFIG" --receipt "$RUN_RECEIPT"
```

1. Read its JSON result. `skipped` reports the reason; do not install a missing
   skill, widen scope, or claim calibration ran. Product completion is unchanged.
2. On `ready`, use the current host's normal delegation tool to start one separate
   learning task with the returned `brief`. The same host that supervises workflow
   or explicit Codex waves supplies this tool. No new model launcher is required.
   If delegation is unavailable, report skipped/unavailable.
3. The learner follows the external skill's own learning process, confined to
   the supplied current-run evidence. It may automatically improve only the
   listed existing canonical skill files. No global chat search, memory/rules
   writes, wrapper edits, or new skills. AGENTS.md, CLAUDE.md, new skills and all
   unlisted destinations remain proposals requiring human approval.
   For recurring mistakes, use [correction prevention](../../super-collect/references/correction-prevention.md).
   Prefer a fitting structural correction before reminders. Product ownership/type/schema/guard/test
   changes remain proposals for ordinary verified, curated Backlog intake. This preference
   grants no product write authority and does not bypass verification or user curation.
4. The host inspects the actual diff and changed paths before accepting edits.
   Compare them to `allowed_skill_paths`; halt/report unexpected edits, preserve
   them for review, and never stage or commit them automatically. The read-only
   helper scopes the brief; it does **not** OS-enforce future model writes.
5. Record the actual result beside the receipt: existing-skill edits, no change,
   dropped lessons, approval proposals, or skipped/unavailable. Do not commit,
   push or publish private skills without separate authorization.

`skill_path` can name an installed SKILL.md explicitly (repo-relative, absolute,
or `~/...`). If unset, discovery checks only `calibrate/SKILL.md` in the project's
`.agents/skills/` and `.claude/skills/`, then known user `.agents/skills/`,
`.claude/skills/` and `.codex/skills/` roots. It does not scan other workspaces.
An invocation wrapper can lead to its installed canonical instructions; edit
targets must already be the canonical files, with no wrappers or symlink aliases.
The explicit list is capped at 20 files. Nothing is edited by the adapter itself.

## Legacy headless runs

An unsupervised `claude-p` runner reports calibration skipped: it has no host
that can invoke an installed skill. Do not launch a new unconfigured provider or
interpret the runner's clean exit as verified completion. A supervising host can
perform the same final reconciliation, prepare the receipt and delegate afterward.
Blocked-only, human-approval, partial and halted endings never run this hook.
