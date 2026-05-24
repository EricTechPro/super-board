# `super-board status` — read-only live snapshot

> **Source of truth:** spec §7.5 in
> `docs/superpowers/specs/2026-05-21-super-board-design.md`.
>
> This is the **only read-only verb** in the `super-board` skill. It performs
> no GitHub mutations and is safe to invoke during a headless `super-board run`.

---

## Intro shown when status starts

```
📊 super-board status
─────────────────────────────────────────────────────────
```

## What it prints

```
📊 super-board · <active-config-description>
   Project:    <title> (#<number>) under <owner>     <link>
   Variant:    <full|qa-only>          Base branch: <base_branch>
   Mode:       <auto-merge|human-approves>   Truth gate: <off|non-trivial|always>

Columns (live from gh api):
   Ready    [12]   Building [1]   QA   [2]   Review [1]   Done [33]
   Blocked  [4]    Skipped  [0]

In-flight (issues with the claim assignee from config — bot identity or user account):
   🔨 #42 issue-42-add-chat-streaming      Builder       claimed 4 min ago
   🔍 #41 issue-41-paginate-events         Tester        claimed 11 min ago

Block / Skip breakdown:
   🔐 ×2  missing creds (#19, #27)
   💳 ×1  Stripe quota hit (#31)
   ❓ ×1  ambiguous AC (#23)

Recent (last 5 events from current run manifest):
   T-12m  ✅ #41 → Review        (Tester pass v2)
   T-25m  ⛔ #19 → Blocked       (🔐 OPENAI_API_KEY missing)
   T-31m  🔨 #42 → QA            (Builder done)
   T-47m  🔍 #38 → Ready         (Tester rebuild, loop:rebuild-1)
   T-52m  ✅ #36 → Done          (Reviewer merged)

Health:
   Last tick: 47s ago     Stale worktrees cleaned: 1
   Run started: 2h 14m ago  Active worker count: 2/3
```

## Behaviors

- Pure-read. Touches GitHub for column counts + assignee scan + run-manifest read. No writes.
- Works whether `super-board run` is currently active or not (just reports what's there).
- Multi-project: `super-board status bookkeeping-app` operates on that project's config (same lookup rules as §4).
- Safe to run during a headless `run`. Does not interfere with worker dispatch.

---

## Implementation hints (authored — NOT in spec)

These notes guide the worker that executes `status`. They are derived from the
spec but the spec itself does not prescribe the mechanics; treat them as
guidance, not contract.

- **Active config resolution:** load
  `.claude/super-board/configs/<slug>.json` for the resolved project slug.
  Prefer reading once and printing the header fields directly from the JSON.
- **Claim assignee resolution:** the in-flight worker scan must match the
  identity recorded in the config under `notifications.bot_identity`. This may
  be a GitHub App bot account (e.g. `super-board-bot[bot]`) **or** the user's
  own login when running in user-account mode. If `notifications.bot_identity`
  is absent, fall back to scanning for any assignee that matches the
  configured identity (e.g. `claim.assignee_login`).
- **Column counts:** use the read-only GitHub Projects v2 API via
  `gh project item-list <project-number> --owner <owner> --format json --limit 500`,
  then group by the `Status` field locally. Do **not** call
  `gh project item-edit` or any mutation in this verb.
- **In-flight workers:** list issues assigned to the claim assignee with
  `gh issue list --assignee <login> --state open --json number,title,assignees,labels,updatedAt`,
  then bucket by role (`role:builder` / `role:tester` / `role:reviewer`)
  using labels written by `run`.
- **Block/Skip breakdown:** read issues currently in the `Blocked` /
  `Skipped` columns (from the column-count JSON above) and parse the latest
  §4 reason-tag comment on each. Group by reason tag emoji (🔐, 💳, ❓, ⚙️,
  etc.). Do not re-tag or edit anything.
- **Recent events:** tail the active run manifest at
  `docs/super-board/runs/<YYYY-MM-DD>-<slug>.md` — pick the most recent file
  whose front-matter `status:` is `running` or `completed`. Show the last 5
  state-transition lines.
- **Health:**
  - `Last tick` — most recent timestamp in the run manifest.
  - `Stale worktrees cleaned` — count from manifest housekeeping section.
  - `Run started` — manifest front-matter `started_at`.
  - `Active worker count` — derived from in-flight scan above, capped at
    `config.parallelism.max_concurrent_workers`.

---

## Multi-project lookup

Same rules as §4 config discovery:

- **Bare `super-board status`** invoked in a project root → use that
  project's config.
- **`super-board status <name>`** invoked in an umbrella repo → switch to the
  named sub-project's config.
- **No active config found** → halt with:
  `Run super-board onboard first.`

---

## Worker self-check (MANDATORY before exit)

Before returning, the worker MUST confirm that no `gh` invocation issued by
this verb belongs to the mutation set below. If any forbidden call was made,
**halt immediately** and report a contract violation; do not print the
snapshot.

Forbidden in `status`:

- `gh ... edit` (e.g. `gh issue edit`, `gh project item-edit`,
  `gh pr edit`, `gh label edit`, `gh repo edit`)
- `gh ... create` (e.g. `gh issue create`, `gh pr create`,
  `gh project item-create`, `gh label create`, `gh release create`)
- `gh ... delete` (e.g. `gh issue delete`, `gh project item-delete`,
  `gh label delete`, `gh repo delete`)
- `gh issue ... add-label` / `gh issue ... remove-label`
- `gh issue ... add-assignee` / `gh issue ... remove-assignee`
- `gh api graphql` invocations with mutations such as `resolveReviewThread`,
  `addProjectV2ItemById`, `updateProjectV2ItemFieldValue`, `closeIssue`,
  `mergePullRequest`, etc.

Allowed in `status` (read-only):

- `gh project item-list` / `gh project view`
- `gh issue list` / `gh issue view`
- `gh pr list` / `gh pr view`
- `gh api graphql` strictly with `query { ... }` (never `mutation { ... }`)
- Local filesystem reads of the config JSON and run-manifest markdown.

If implementation accidentally calls a mutation, halt and report:
`super-board status: contract violation — mutation attempted from a read-only verb.`
