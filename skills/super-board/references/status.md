# `super-board status` — read-only live snapshot

> **Source of truth:** spec §7.5 in
> `docs/superpowers/specs/2026-05-21-super-board-design.md`.
>
> This is the **only read-only verb** in the `super-board` skill. It performs
> no GitHub mutations and is safe to invoke during a headless `super-board run`.

---

## ⚡ Fast path — prefer this

If `.claude/bin/super-board-status.py` exists:

1. **Run it.**
2. **Print its stdout verbatim, inside a single fenced code block.**
3. **Stop.** Do not write anything before or after the code block.

Skip everything below in this file — the script implements the locked
template defined here.

```bash
python .claude/bin/super-board-status.py                # sole-config or active marker
python .claude/bin/super-board-status.py <config-slug>  # multi-project repo
```

### Do NOT, under any circumstances:

- **Do not** summarize, paraphrase, condense, or rewrite the output.
- **Do not** add a `TL;DR`, `Summary`, intro, outro, or any prose around it.
- **Do not** collapse empty lanes onto one line (e.g. don't merge
  `Building [0]`, `QA [0]`, `Review [0]` into one row). Each lane is its
  own multi-line box; preserve every line and every newline as-is.
- **Do not** merge `Blocked` and `Skipped` into one combined box.
- **Do not** strip the `▎Workers` / `▎Block reasons` / `▎Recent` / `▎Health`
  section headers, or fold them into the kanban box stack.
- **Do not** re-render the box-drawing characters, "fix" alignment, or
  "improve" the layout in any way.
- **Do not** add markdown links, bold, or other styling inside the code
  block. Issue numbers stay as plain `#NNN`.

The user chose the rich 80-column template deliberately. Compressing it
back into a chat-friendly summary defeats the entire point of having the
script. If the output looks long, that **is** the correct length — print
it anyway and trust the user to scroll. The ≈150× speedup claim assumes
the agent does no rendering work post-script; summarizing forfeits part
of that win and gives the user the wrong layout.

### Background

This file defines a richer status template than the one super-board
originally shipped with: a fixed 80-column Kanban plus dedicated
`▎Workers`, `▎Block reasons`, `▎Recent`, and `▎Health` sections.
Model-rendering all of that token-by-token takes ≈3 min per invocation;
the Python script renders the same template in ≈1.3 s (≈150× faster),
so the richer view stays usable in practice. Pure Python 3 stdlib +
`gh` CLI; no `jq`, no bash — runs on macOS, Linux, and Windows alike.

Exit codes the orchestrator should respect:

- `0` — printed snapshot, done.
- `64` — no config-slug arg and ambiguous configs, or invalid slug (path
  traversal); ask the user which / for a valid slug.
- `66` — config not found.
- `67` — `gh` / network failure; surface the stderr line and stop.

The script enforces the same read-only contract as the rest of this file
(no `gh ... edit/create/delete`, no GraphQL mutations). If you want to verify
that for a given invocation: `grep -E 'gh ?\.api\.(issue|pr|project) (edit|create|delete)|mutation {|gh.*(edit|create|delete)' .claude/bin/super-board-status.py` — should return nothing.

The rest of this document is the format spec the script implements. Read it
only when (a) the script is missing and you need to hand-render, or (b) you're
editing the script and need to confirm the locked template.

---

## Intro shown when status starts

```
📊 super-board status
────────────────────────────────────────────────────────────────────────────────
```

---

## The locked template — render EXACTLY this shape

This is a **template, not an example**. Print every section, in this order,
every time — even when counts are zero. Width is fixed at 80 columns. The
sample below is rendered against live data, but the structure is what's
locked: section labels, box layout, emoji, timestamp format, empty-state
strings. Do **not** improvise.

```
📊 super-board · <Project Title> (#<number>)
────────────────────────────────────────────────────────────────────────────────
config: <slug>   variant: <full|qa-only>   base: <base_branch>
mode:   <auto-merge|human-approves>        truth gate: <off|non-trivial (≥N)|always>

┌─ Ready    [N] ───────────────────────────────────────────────────────────────┐
│ <card lines, one per issue — see §C>                                         │
└──────────────────────────────────────────────────────────────────────────────┘
┌─ Building [N] ───────────────────────────────────────────────────────────────┐
│ <card lines>                                                                 │
└──────────────────────────────────────────────────────────────────────────────┘
┌─ QA       [N] ───────────────────────────────────────────────────────────────┐
│ <card lines>                                                                 │
└──────────────────────────────────────────────────────────────────────────────┘
┌─ Review   [N] ───────────────────────────────────────────────────────────────┐
│ <card lines>                                                                 │
└──────────────────────────────────────────────────────────────────────────────┘
┌─ Done     [N] ───────────────────────────────────────────────────────────────┐
│ <collapsed line — see §D>                                                    │
└──────────────────────────────────────────────────────────────────────────────┘
┌─ Blocked  [N] ───────────────────────────────────────────────────────────────┐
│ <card lines with reason glyph>                                               │
└──────────────────────────────────────────────────────────────────────────────┘
┌─ Skipped  [N] ───────────────────────────────────────────────────────────────┐
│ <card lines with reason glyph>                                               │
└──────────────────────────────────────────────────────────────────────────────┘

▎Workers  (claim: <login> · <active>/<max> active)
   <one line per in-flight worker — see §E>

▎Block reasons
   <one line per reason tag — see §F>

▎Recent  (last 5 manifest events)
   <one line per event — see §G>

▎Health
   last tick: <time>    run started: <time>    workers: <a>/<m>    worktrees cleaned: <n>
```

### Sample render (today's live NSAdashboard board)

```
📊 super-board · NSAdashboard Super-Board (#1)
────────────────────────────────────────────────────────────────────────────────
config: nsadashboard-super-board   variant: full   base: staging
mode:   auto-merge                 truth gate: non-trivial (≥70)

┌─ Ready    [1] ───────────────────────────────────────────────────────────────┐
│ 🔨 #26  Strip nav + editor groups from command palette            ↻ 2/3      │
└──────────────────────────────────────────────────────────────────────────────┘
┌─ Building [0] ───────────────────────────────────────────────────────────────┐
│ (empty)                                                                      │
└──────────────────────────────────────────────────────────────────────────────┘
┌─ QA       [2] ───────────────────────────────────────────────────────────────┐
│    #24  Unify status options across Ads and Organic                          │
│ 🔍 #29  Organic video detail modal — create + edit-ready          ↻ 1/3      │
└──────────────────────────────────────────────────────────────────────────────┘
┌─ Review   [0] ───────────────────────────────────────────────────────────────┐
│ (empty)                                                                      │
└──────────────────────────────────────────────────────────────────────────────┘
┌─ Done     [9] ───────────────────────────────────────────────────────────────┐
│ #20 #18 #7 #6 #5 #4 #3 #2 #1   (squash-merged, collapsed)                    │
└──────────────────────────────────────────────────────────────────────────────┘
┌─ Blocked  [1] ───────────────────────────────────────────────────────────────┐
│ 🛡 #25  Add Controle page — gated on #24                                     │
└──────────────────────────────────────────────────────────────────────────────┘
┌─ Skipped  [0] ───────────────────────────────────────────────────────────────┐
│ (empty)                                                                      │
└──────────────────────────────────────────────────────────────────────────────┘

▎Workers  (claim: LucariusWest · 2/3 active)
   🔨 Builder  #26  attempt 2/3 · 6m · loop:rebuild-1
   🔍 Tester   #29  attempt 1/3 · 6m

▎Block reasons
   🛡 ×1  dependency gate    #25 → waiting on #24

▎Recent  (last 5 manifest events)
   T-6m    🔨 dispatch  #26 → Builder  attempt 2/3
   T-6m    🔍 dispatch  #29 → Tester   attempt 1/3
   T-6m    ♻ reap      #29 stale lock + assignee swept
   T-16m   ♻ reap      #26 stale lock + assignee swept
   T-22m   🔨 dispatch  #29 → Builder  attempt 1/3

▎Health
   last tick: 93s ago    run started: 67m ago    workers: 2/3    worktrees cleaned: 5
```

---

## Conventions

### §A — Width contract

- Every line ≤ 80 characters.
- Kanban box frames are **exactly 80 chars wide**: `┌─` + label + `[N]` + `─`-padding to col 79 + `┐`. Closing `└…┘` mirrors the top.
- Card lines inside a box: `│ ` (2 chars) + 76 chars of content (padded with trailing spaces) + ` │`. Truncate the title with `…` if the row would exceed the budget.

### §B — Section order (mandatory, always print)

1. Header line (project + `#number`)
2. Separator (80 × `─`)
3. Config strip (2 lines: `config/variant/base`, `mode/truth-gate`)
4. Kanban — 7 boxes, **fixed order**: Ready → Building → QA → Review → Done → Blocked → Skipped
5. `▎Workers`
6. `▎Block reasons`
7. `▎Recent`
8. `▎Health`

**Empty-state strings (locked):**

- Empty Kanban box: `│ (empty)` + padding.
- Empty `▎Workers`: `   (idle)`
- Empty `▎Block reasons`: `   (none)`
- Empty `▎Recent`: `   (no manifest events yet)`
- No active run at all: see §H.

### §C — Card line format

Inside a Kanban box, one line per issue:

```
│ <glyph> #<NNN>  <title…>                                    <suffix>      │
```

- **glyph** (2 visual cells + space): the lane glyph (`🔨`/`🔍`/`✏️`) if the issue
  is in-flight (claim assignee + `loop:in-{builder,tester,reviewer}` label),
  else three spaces. **This glyph is the highlight** — no separate "active in
  column X" callout needed.
- **#NNN**: issue number, left-padded to keep title column aligned.
- **title**: truncated to `…` to fit the remaining budget after the suffix.
- **suffix** (right-justified):
  - In-flight rebuild: `↻ N/3` (from `loop:rebuild-N` label)
  - Blocked: `— <reason glyph> <short reason>` or `— gated on #N`
  - Skipped: `— ⏭ <short reason>`
  - Otherwise: empty

### §D — Done column collapsing

Done is **always one line** of issue numbers, newest first, no titles, tagged
`(squash-merged, collapsed)`. Never expand Done card-by-card. If Done has more
than ~12 issues at 80-col width, truncate with `… +N more` at the end.

### §E — Workers section format

One line per in-flight worker, sorted by lane (Builder, Tester, Reviewer):

```
   <glyph> <Role-padded-to-8>  #<NNN>  attempt <a>/3 · <Nm> · <extra-labels>
```

Where `<Nm>` is "minutes since the most recent `dispatch lane=…` line for that
issue in the run manifest". `<extra-labels>` lists any other meaningful
`loop:*` labels (e.g. `loop:rebuild-1`), comma-separated, omitted when none.

### §F — Block-reasons section format

Group `Blocked` and `Skipped` cards by reason-tag emoji, sorted by count desc:

```
   <glyph> ×<count>  <short reason>    <#N> → <detail> [, <#N> → <detail>…]
```

Reason glyph is determined by parsing the latest §4 reason-tag comment on each
issue. Use the locked vocabulary in §I — never improvise. Fall back to `🚫
other` if the comment can't be parsed.

### §G — Recent-events section format

Tail the last 5 state-transition lines from the most recent run manifest
(`docs/super-board/runs/<YYYY-MM-DD>-<slug>.md`). Reformat each as:

```
   T-<Nm>    <glyph> <verb>      #<NNN> → <Target>  <detail>
```

Where:

- `T-<N>m` if event was < 60 minutes ago, `T-<N>h` if < 24h, `T-<N>d` otherwise.
- `<verb>`: `dispatch`, `pass`, `block`, `skip`, `reap`, `alert`, `zombie`, `merge`.
- `<glyph>`: the lane glyph for `dispatch`, else the action glyph from §I.
- `<Target>`: target lane/column for the transition (or omit for `reap`).
- Pad columns so verbs align visually.

A "state-transition line" is any manifest line containing `dispatch`,
`reaped`, `→ Done`, `→ Blocked`, `→ Skipped`, `→ QA`, `→ Review`,
`block-rate alert`, or `zombie`. Tick-only lines (`tick — Ready=…`) are
**not** state transitions; skip them.

### §H — No-active-run state

If today's manifest doesn't exist or its last line is `✅ … exiting cleanly`,
the run is not active. Adjust three sections:

- `▎Workers` → `   (no active run — \`super-board run\` to start)`
- `▎Recent` → tail the most recent manifest (any date) and prefix each event
  with the date when it's not today: `2026-05-25 T-1d ✅ #20 → Done`
- `▎Health` → `last run: completed <N>{m,h,d} ago    workers: 0/<max> idle`

The Kanban board still renders normally — column counts come from the live
Projects v2 API, not from the manifest.

### §I — Locked emoji vocabulary

Pick from this set only. If a runtime situation doesn't match, fall back to
`🚫`. Do **not** invent new emoji.

**Lane roles:**

| Glyph | Meaning          |
| ----- | ---------------- |
| 🔨    | Builder lane     |
| 🔍    | Tester (QA) lane |
| ✏️    | Reviewer lane    |

**Action markers (Recent + Workers):**

| Glyph | Meaning                                  |
| ----- | ---------------------------------------- |
| ↻     | rebuild iteration (`attempt N/3`)        |
| ✅    | pass / merged / lane-complete            |
| ⛔    | blocked transition (Ready → Blocked)     |
| ⏭    | skipped transition (Ready → Skipped)     |
| ♻     | reap stale lock + assignee swept         |
| ⚠     | block-rate / rebuild-cap / generic alert |
| 💀    | zombie worker killed                     |

**Block / skip reason tags (Blocked + Skipped column suffixes, ▎Block reasons):**

| Glyph | Meaning                                   |
| ----- | ----------------------------------------- |
| 🛡    | dependency gate (waiting on another card) |
| 🔐    | missing creds / API key                   |
| 💳    | quota / billing                           |
| ❓    | ambiguous AC (lint flagged)               |
| ⚙     | infra / tooling issue                     |
| 🚫    | unparsed "other" reason — fallback        |

### §J — Timestamp format (locked)

| Where                | Format                                    | Example                 |
| -------------------- | ----------------------------------------- | ----------------------- |
| `▎Recent` events     | `T-<N>m` / `T-<N>h` / `T-<N>d`            | `T-6m`, `T-3h`, `T-1d`  |
| Health "last tick"   | `<N>s ago` if < 90s, else `<N>m ago`      | `93s ago`, `4m ago`     |
| Health "run started" | `<N>m ago` if < 90m, else `<N>h <M>m ago` | `67m ago`, `2h 14m ago` |
| Workers "dispatched" | `<N>m` / `<N>h` (no "ago" suffix)         | `6m`, `2h`              |

Never print absolute clock times (`14:21:45`) in the user-facing output — they
belong in the manifest, not the snapshot.

---

## Behaviors

- Pure-read. Touches GitHub for column counts + assignee scan + run-manifest read. No writes.
- Works whether `super-board run` is currently active or not — see §H.
- Multi-project: `super-board status bookkeeping-app` operates on that project's config (same lookup rules as §4 of the spec).
- Safe to run during a headless `run`. Does not interfere with worker dispatch.

---

## Implementation hints (authored — NOT in spec)

These notes describe the data flow that `super-board-status.py` implements.
They also apply if you need to hand-render via the model-render fallback when
the script is missing.

- **Active config resolution:** load
  `.claude/super-board/configs/<slug>.json` for the resolved project slug.
  Header fields come straight from the JSON.
- **Claim assignee resolution:** the in-flight worker scan must match the
  identity recorded in the config under `notifications.bot_identity`. This may
  be a GitHub App bot account (e.g. `super-board-bot[bot]`) **or** the user's
  own login when running in user-account mode. If `notifications.bot_identity`
  is absent, fall back to scanning for any assignee that matches the
  configured identity (e.g. `claim.assignee_login`).
- **Project items (column counts + in-flight workers, both from ONE call):**
  the script issues a single targeted `gh api graphql` query (`ITEMS_QUERY`
  near the top of `super-board-status.py`) that fetches each item's `number`,
  `title`, `labels{nodes{name}}`, and the `Status` single-select field —
  ≈3 KB total. Group locally by Status for column counts; filter the same
  `labels` array for `loop:in-{builder,tester,reviewer}` to identify
  in-flight workers per lane; `loop:rebuild-N` feeds the `↻ N/3` suffix.
  Deliberately avoids `gh project item-list --format json` (≈100 KB — it
  slurps every issue body) and any separate `gh issue list --assignee` call.
  Do **not** call `gh project item-edit` or any mutation in this verb.
- **Block-reason parsing:** for each issue in `Blocked` or `Skipped`, read the
  latest §4 reason-tag comment via `gh issue view <N> --json comments` and
  match the leading emoji against §I. Cache results during the snapshot — do
  not re-read mid-render.
- **Recent events:** tail the most recent run manifest at
  `docs/super-board/runs/<YYYY-MM-DD>-<slug>.md`. Filter to state-transition
  lines (§G); skip `tick —` lines. Take the last 5 after filtering.
- **Health:**
  - `Last tick` — most recent `tick —` line in today's manifest.
  - `Stale worktrees cleaned` — count `reaped worktree` lines since the most
    recent `super-board run started` line in today's manifest.
  - `Run started` — most recent `super-board run started` line in today's
    manifest. If absent or followed by `exiting cleanly`, see §H.
  - `Active worker count` — derived from in-flight scan above, capped at
    `config.max_workers` (top-level, defaults to 3).

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

## Read-only contract — enforced on both rendering paths

When `super-board-status.py` runs, this contract is enforced by inspection:
the script issues no `gh` mutations (see the `grep` verification command in
the Fast-path block above). When the model-render fallback executes instead,
the model MUST confirm before printing the snapshot that no `gh` invocation
it issued belongs to the mutation set below. Either way, if any forbidden
call was made, **halt immediately** and report a contract violation; do not
print the snapshot.

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
