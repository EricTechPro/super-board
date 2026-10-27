# Run the existing collector from your scheduler

The package supplies `super-collect`; the scheduler supplies the trigger. This
reference creates no job or cadence. Use a real configured project, not an
unconfigured Super Board source checkout.

## Host setup

Give the agent runner the project's working directory, installed skills/helpers,
authenticated GitHub CLI, Python, jq, and access to the configured sources.
Credentials remain in the owning project's environment/secret store. Never put
secrets or private ticket bodies in scheduler notifications or command arguments.
Confirm the active config matches the intended repo/board, then test a dry run.

## Copyable agent-job prompt

> In the configured project repository, use the existing super-collect skill with
> --yes --direct and only this project's configured sources. Confirm the active config's
> repo and board before writes. Verify candidates and deduplicate before filing.
> File verified new findings or recurrences into Backlog or its holding-column
> alias, never Ready; preserve cards already on the board. Do not build, merge,
> migrate, deploy or run calibration as part of intake. Keep unchanged results
> quiet. Notify only for verified new findings, meaningful new evidence or
> recurrences, failures, or required user action. Report unavailable/partial
> sources honestly. If reads or a write outcome are halted, preserve the reason
> and stop; do not clear the halt or blindly retry create/comment.

Adapt invocation to the host: Claude uses `/super-collect --yes --direct`; Codex uses
`$super-collect --yes --direct`. `--direct` skips the `/to-spec` → `/to-tickets` hand-off,
which asks questions no one is there to answer. A local timer can start that host's normal agent runner
with this prompt. A cloud job needs equivalent repo, tool, skill and credential
access. No universal scheduler service is bundled.

## Same-host overlap and receipts

Collectors serialize by repository identity on one machine. They share an OS lock
(flock on POSIX, msvcrt on Windows, where the filer runs as a `bash` child under a
per-hold token) in project-local `.claude/super-board/collect/`, resolved through
the existing GitHub halt location across worktrees. `SB_COLLECT_STATE_DIR` can
select another dedicated shared ignored directory. The helper creates a
self-ignoring `.gitignore` there, including after an app install. Receipts contain
issue identifiers, fingerprints and hashes, never ticket bodies or credentials.

`SB_COLLECT_LOCK_TIMEOUT` accepts 0–300 seconds (default 15). Busy callers exit 4
without remote mutations. Independent clones must deliberately share their
same-host state path; separate machines need scheduler-level exclusion. This is
not a distributed lock or a guarantee for arbitrary network filesystems.

Dedupe uses guarded complete paginated all-state issue history. Failed, malformed
or incomplete reads stop before writes. Open exact-fingerprint hits reuse the
issue; closed-only hits create a recurrence. A successful receipt suppresses the
same exact candidate body for the same open issue. Changed bodies create a new
sighting; the verifier still decides whether timestamp-only changes mean useful
new evidence.

Pending mutation receipts survive interruption and block automatic retry. Inspect
the saved halt and receipt, check the remote result, and resolve that specific
pending fingerprint only after its outcome is known:

```bash
python3 .claude/bin/super-board-collect-state.py --repo owner/repo \
  --action reconcile --fingerprint 'the-exact-pending-fingerprint'
```

This refuses a live writer and does not clear the GitHub halt. Follow the existing
required-read/mutation recovery process before explicit restart. Failed placement
can leave a known issue outside Backlog; do not report that as successful filing.

Complete issue dedupe does not imply complete source coverage. A capped board
membership snapshot is refused before adoption; fetcher errors/truncation stay
visible. Sentry and nested PR conversation coverage have separate limits, so do
not claim that no further problems exist from a partial fetch.
