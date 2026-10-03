# Writing standard

One format for everything super-board writes: commits, PR bodies, tickets, comments, the
AGENTS.md block. It applies in the super-board repo and in every project super-board is
installed into. A host repo with its own commit style (EricOS root) keeps it outside the pack.

Every template in this pack points here. Change the format here first, then the templates.

## Rules

- ALWAYS run prose through the `humanizer` skill when it is installed. Without it, use the
  plain-words rules at the bottom.
- ONE step per line. NEVER chain steps with arrows (`→`) in Problem, Context or Steps.
- EMBED screenshots (`![desktop](https://github.com/<o>/<r>/raw/<sha>/<path>)`), pinned to a
  commit sha. NEVER link to them, NEVER upload to a public image host.
- NEVER write a "Not verified" section or a "Next" section in a PR body. An unchecked AC
  with its one-line reason replaces both.
- NEVER list changed files in a comment. GitHub already shows them.
- DON'T restate the ticket. DON'T narrate ("I have successfully…").

## 1 · Commit

```
<emoji> [<type>] <scope>: <subject>

- <short bullet>
- <short bullet>
Closes #<N>
Co-Authored-By: …
```

| Field | Rule | Required |
|---|---|---|
| Subject | `<emoji> [<type>] <scope>: <subject>` · imperative · ≤ 72 chars | yes |
| Body | 1–4 short bullets: what changed, what proves it | yes, except trivial commits |
| `Closes #N` | when the commit finishes a ticket | when it applies |
| `--- decision ---` trailer | a rung-3 fork (super-build decision policy) | when it applies |

| Emoji | Type | Use for |
|---|---|---|
| ✨ | `feat` | new behaviour |
| 🐛 | `fix` | bug fix |
| 🔧 | `chore` | tooling, config, loop markers |
| ♻️ | `refactor` | same behaviour, better shape |
| 🧪 | `test` | tests only |
| ⚡ | `perf` | faster, same behaviour |
| 📝 | `docs` | docs only |
| 👷 | `ci` | CI pipelines |
| 💄 | `ui` | visual polish, screenshots |
| 🔒 | `security` | auth, secrets, hardening |
| ⏪ | `revert` | revert a commit |
| 🚧 | `wip` | partial work, checkpoints |

Subject regex (checked by `tests/test_writing_format.py`):
`^(✨|🐛|🔧|♻️|🧪|⚡|📝|👷|💄|🔒|⏪|🚧) \[(feat|fix|chore|refactor|test|perf|docs|ci|ui|security|revert|wip)\] [a-z0-9][a-z0-9._/-]*: \S`
The emoji must match its type.

Machine-read subjects (scripts grep these exact shapes):

| Commit | Subject |
|---|---|
| Builder done | `🔧 [chore] loop: close #<N> — <summary>` |
| Builder partial | `🚧 [wip] loop: #<N> partial — <slice or reason>` |
| super-qa iteration done | `🧪 [test] super-qa: iter <N> (<X> bugs, <Y> items, <Z> PRs opened)` |
| super-qa checkpoint | `🚧 [wip] super-qa: iter <N> — <one-liner>` |

**Squash merge.** Subject = the PR title. Body = the PR's commit bullets, deduplicated, plus
`Closes #N`. The merge gate takes them as `--subject` and `--body-file`.

Example:

```
🐛 [fix] receipts: show a size error over 10 MB

- 413 now shows "File too large"
- client checks size before upload
- e2e covers desktop + mobile
Closes #790
```

## 2 · PR

**Title** = commit subject format: `🐛 [fix] receipts: show a size error over 10 MB`.

**Body** = marker blocks, in this order. A lane rewrites only its own blocks, with
`.claude/bin/super-board-pr-body.sh` (it refuses when the PR head moved since you read it).
`super-board-pr-body.sh --skeleton` prints an empty body with every marker.

| Block | Marker | Written by | When | Required |
|---|---|---|---|---|
| Red check | `<!-- sb:redcheck -->` | reviewer | merged with a failing check | when it applies |
| Status | `<!-- sb:status -->` | every lane | rewritten on every exit | yes |
| Problem | `<!-- sb:problem -->` | builder | PR open (from the ticket's Context) | yes |
| Solution | `<!-- sb:solution -->` | builder | PR open, each rebuild | yes |
| Acceptance criteria | `<!-- sb:ac -->` | builder writes, qa ticks + proof, reviewer unticks a disproved one | each lane | yes |
| Iteration history | `<!-- sb:history -->` | every lane appends one row | every exit | yes |
| Before \| After | `<!-- sb:visual -->` | qa, or ui-refine-loop `pr-shots.sh` | UI changes | UI only |
| Risk | `<!-- sb:risk -->` | builder writes, reviewer adjusts | PR open, review | yes |

Each block closes with `<!-- /sb:<name> -->`.

**Red check.** Shipped with a failing check? The first thing in the body says which and why:

```
> [!WARNING]
> 🔴 Merged with a failing check: `e2e-mobile` · CI budget block; local suite green 42/42, truth 91/100
```

**Status card** — a GitHub alert, one line:

| State | Alert | Line |
|---|---|---|
| building, in QA, in review | `> [!NOTE]` | `⏳ In review · round 1 · ✅ 2/3 AC · Closes #790 · head \`3f9c2a1\`` |
| merged | `> [!TIP]` | `✅ Merged · \`9c41e07\`` |
| blocked, red check | `> [!WARNING]` | `🛑 Blocked · needs Eric` |

A partial PR writes `Refs #N`, never `Closes #N`.

**Problem** — lettered steps under Where. GitHub has no lettered-list syntax, so type the letter:

```
## Problem
- **Where:** Receipts page, `/dashboard/receipts`
  - a. Sign in
  - b. Click **Receipts** in the sidebar
  - c. Drag a 12 MB PDF onto **Drop receipts here**
- **Who:** any signed-in user (free plan)
- **What happened:** the spinner never stops

![receipts · desktop](https://github.com/acme/app/raw/5a2363b/docs/super-board/runs/issue-790-qa-v1/desktop.png)
```

**Solution** — plain bullets, one change each. Docs consulted go last, as `Docs:` bullets.

```
## Solution
- 413 shows "File too large (max 10 MB)"
- Client checks size before upload
- One limit constant for client and server
- Docs: https://developer.mozilla.org/en-US/docs/Web/HTTP/Status/413 — 413 is the server refusing a payload over its limit
```

**Acceptance criteria** — a checklist, one proof line under each. Unchecked = not verified,
and the proof line says why in one line.

```
## Acceptance criteria
- [x] 12 MB file shows the size message in 1 s\
  ↳ `e2e/upload-size.spec.ts:14`
- [x] No request over 10 MB\
  ↳ spec asserts 0 calls · HAR in `runs/issue-790-qa-v2/`
- [ ] No new Sentry events after deploy\
  ↳ not verified: needs prod deploy · Eric
```

**Iteration history** — local time from config `timezone` (onboard sets it to the machine's
zone). Get the stamp with `super-board-pr-body.sh --time --config <cfg>`.

```
## Iteration history
| Lane | Done | Time | Details |
|---|---|---|---|
| 🔨 builder | ✅ | Oct 2, 10:02 EDT | draft · `3f9c2a1` |
| 🔍 qa | ❌ v1 | Oct 2, 10:40 EDT | mobile hidden · `runs/issue-790-qa-v1/` |
| 🔍 qa | ✅ v2 | Oct 2, 11:55 EDT | `runs/issue-790-qa-v2/` |
| 🧐 reviewer | ✅ merged | Oct 2, 12:20 EDT | squash `9c41e07` |
```

**Before | After** — two columns, one row per viewport, both shas in the header. Images are
committed on the branch; raw URLs are pinned to the commit that holds them.

```
## Before | After
| | Before `5a2363b` | After `3f9c2a1` |
|---|---|---|
| Desktop | <img src="https://github.com/acme/app/raw/3f9c2a1/docs/ui/before-desktop.png" width="480"> | <img src="https://github.com/acme/app/raw/3f9c2a1/docs/ui/after-desktop.png" width="480"> |
| Mobile | <img src="https://github.com/acme/app/raw/3f9c2a1/docs/ui/before-mobile.png" width="220"> | <img src="https://github.com/acme/app/raw/3f9c2a1/docs/ui/after-mobile.png" width="220"> |
```

**Risk** — level plus one line. If it merged red, name the check here too.

```
## Risk
🟢 **Low** · limit read from one constant; no plan differences.
```

Levels: 🟢 Low · 🟡 Medium · 🔴 High. A `needs-you: <command>` line (merge gate reads it) goes
under Risk.

## 3 · Ticket

**Title:** `<emoji> [<kind>] <scope>: <what is wrong or wanted>` · ≤ 70 chars, no ticket number.

| Kind | Title tag |
|---|---|
| bug | `🐛 [bug]` |
| feature | `✨ [feat]` |
| ux | `💄 [ui]` |
| tests | `🧪 [test]` |
| docs | `📝 [docs]` |
| tech-debt, refactor | `♻️ [refactor]` |
| security | `🔒 [security]` |

**Sections**, in order:

| Section | Content | Required |
|---|---|---|
| `## Problem` | 1–3 sentences: what is wrong or missing, from the user's side | yes |
| `## Context` | `- **Where:**` + lettered steps (one per line), `- **Who:**`, screenshot embedded | yes · screenshot for UI |
| `## Evidence` | the folded 12-row table below | bugs |
| `## Fix` | the intended change in 1–3 lines. No implementation plan | yes |
| `## Acceptance Criteria` | 2–5 `- [ ]` items, each checkable by a test | yes |
| `## Risk` | 🟢/🟡/🔴 level + one line | yes |
| `## Blocked by` | `- #N — why` bullets, or exactly `- None.` | yes |

Example:

```
🐛 [bug] receipts: spinner never stops over 10 MB

## Problem
A 12 MB PDF spins forever. The 413 is never handled.

## Context
- **Where:** `/dashboard/receipts`
  - a. Sign in as owner
  - b. Click **Receipts**
  - c. Drag `12mb.pdf` onto the drop zone
- **Who:** any signed-in user

![receipts · desktop](https://github.com/acme/app/raw/5a2363b/docs/super-board/runs/issue-790-qa-v1/desktop.png)

## Fix
Map 413 to the size message; check size before upload.

## Acceptance Criteria
- [ ] Size message within 1 s of the drop
- [ ] No request over 10 MB leaves the browser

## Risk
🟢 **Low** · limit lives in two places today; the fix makes it one constant.

## Blocked by
- None.
```

**Bug Evidence** — folded. All 12 rows, always; a missing one says `n/a — <why>`.

```
## Evidence
<details><summary>12 rows · Sentry BOOKZERO-3F1 · 14 users</summary>

| Row | Value |
|---|---|
| Error + stack | `PayloadTooLargeError` · `app/api/receipts/route.ts:48` |
| Request / trace ID | `req_01JB8…7QK` |
| Sentry | BOOKZERO-3F1 |
| PostHog replay | n/a — replay disabled on staging |
| Logs | `413 size=12.4MB` |
| Screenshots | ![desktop](https://github.com/acme/app/raw/5a2363b/docs/…/desktop.png) |
| HAR / API sample | `POST /api/receipts/upload → 413` |
| Env + release | staging · v1.42.0 · `5a2363b` |
| First / last seen | Sep 28 · Oct 2 |
| Users affected | 14 (7 days) |
| Steps | 1. sign in 2. Receipts 3. drop `12mb.pdf` |
| Expected / actual | size message / endless spinner |

</details>
```

The filers (`super-qa-file-bug.sh`, `super-collect-file.sh`, `super-review-file-refactor.sh`)
refuse a body that misses a required section.

## 4 · Comment

```
[<role>] [<label>] <status-emoji> <status> · <round or short context>
Did: <what this lane did, one line>
✅ Done: <what passed or landed>
❌ Not done: <what failed or was skipped, and why>   (omit when nothing)
Next: <owner>
```

| Field | Values |
|---|---|
| role (who writes it) | `builder` · `qa` · `reviewer` · `collect` · `orchestrator` |
| label | `blocker` · `issue` · `suggestion` · `nit` · `question` · `praise` · `report` |
| status emoji | ✅ pass/done · ❌ fail · ⏳ in progress · 🛑 blocked · 🙋 needs you · ↩️ moved back · ⚠️ warning |
| Next | `builder` · `qa` · `reviewer` · `Eric` · `none` |

Header regex: `^\[(builder|qa|reviewer|collect|orchestrator)\] \[(blocker|issue|suggestion|nit|question|praise|report)\] \S`

- ≤ 8 lines of prose. Evidence before adjectives: the command, the sha, the file:line.
- Machine lines (`Local tests:`, `gh-quota-on-exit:`, `blocked-by:`, `root-cause-hash:`) go
  last and do not count toward the 8.
- Screenshots (QA) go below, as an embedded table. They do not count either.
- The Block template (`block-template.md`) uses the same header and keeps its fields.

Example:

```
[qa] [report] ❌ failing · round 1
Did: ran AC1–AC2, desktop + mobile
✅ Done: AC2 no request over 10 MB
❌ Not done: AC1 mobile: message under the keyboard
Next: builder
Local tests: npx playwright test e2e/upload-size.spec.ts
```

**Review threads** (line-level, resolvable) start with the lane that owns the fix, then the
label: `[builder] [blocker] uses new Date() — replace with clock.now()`. Owners: `builder`,
`qa`, `reviewer`.

**Reviewer report** — ONE comment per PR, edited in place every round (find it by the
`<!-- super-review:report -->` marker, PATCH it; post a new one only on the first round).
R-ids never change; a new finding takes the next free id.

```
<!-- super-review:report -->
[reviewer] [report] ❌ bounced · round 2
Did: re-checked R1–R2, fresh pass skipped (R2 open)
✅ Done: R1 fixed `src/cart.py:12`
❌ Not done: R2 not fixed `src/cart.py:31`
Next: builder

| ID | Owner | Class | Where | Finding | Status |
|---|---|---|---|---|---|
| R1 | builder | Bug | `src/cart.py:12` | average_price divides by zero on an empty cart | ✅ fixed |
| R2 | builder | Bug | `src/cart.py:31` | discount_pct not clamped to 0–100 | ❌ not fixed |
```

Reviewer status words: `merge-ready` · `bounced` · `blocked` · `human-gated` · `unverified` ·
`merged`. Classes: Gap · Bug · Verification miss · Scope drift · Over-engineering.

## 5 · AGENTS.md section

Tables plus CAPS rules (NEVER / DON'T / ALWAYS). No prose paragraphs. The managed block is
`agents-md-block.md`, ≤ 40 lines.

## Plain-words rules (when `humanizer` is not installed)

- Short sentences. One idea each.
- Plain words: "use", not "leverage"; "check", not "validate the integrity of".
- Cut filler: successfully, comprehensive, robust, seamless, essentially, in order to.
- Numbers over adjectives: "1.2 s", not "fast".
- Active voice: "QA found", not "it was found".
- No em-dash chains. No rhetorical questions. No closing summary line.
