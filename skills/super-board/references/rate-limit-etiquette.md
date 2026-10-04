# Worker rate-limit etiquette

The dispatcher's `gh_rate_guard` only protects the dispatcher's own ticks. Workers (Builder / Tester / Reviewer) run as independent `claude -p` sessions and **share the same gh-auth token bucket** — 5000 GraphQL points/hr for a PAT, 15000/hr for a GitHub App. The #381 worker storm (2026-05-21) drained the bucket because nothing in the worker contract told workers to watch the quota.

This file is the worker-side contract. Every worker MUST follow it.

## Price list

GraphQL is charged in points, not requests: a query's cost is the nodes it
*could* return, so one nested connection multiplies. Measured 2026-10-04 with
`rateLimit(dryRun:true){cost}` on gh 2.101 and a 131-card board, when a 3-card
wave spent ~2,850 of 5,000 points (~950 a card) and the board stalled an hour:

| Call | GraphQL points |
|---|---|
| `gh project item-list` | 101 per 100 cards — **~203** on this board |
| `gh project field-list` | **101** (it fetches 100 items it never prints) |
| `gh project view` | 2 |
| `gh issue view` · `gh pr view` · `gh pr list` · review-thread query | 1 |
| `gh issue comment` · `gh pr comment` · `gh issue edit` · `gh pr ready` | ~2 (lookup + mutation) |
| `super-board-card.sh move` | 1 (3 the first time an issue is seen) |
| `super-board-card.sh status` · `items` | 1 · ~1 per 100 cards |
| `gh api repos/...` (REST) | 0 — the separate 5,000/hr core bucket |

The rules that follow from it:

- **Cards go through `.claude/bin/super-board-card.sh`** — `move <issue> <Status>`,
  `status <issue>`, `items`. It caches the project, Status field and option ids
  and each issue's item id, shared across worktrees. `gh project item-list`,
  `field-list` and `view` belong to onboarding.
- **REST for everything REST can do** (`{owner}/{repo}` fills from the checkout):

  | Need | REST call |
  |---|---|
  | comment on an issue or PR | `gh api repos/{owner}/{repo}/issues/<N>/comments -F body=@<file>` |
  | edit a comment | `gh api -X PATCH repos/{owner}/{repo}/issues/comments/<id> -F body=@<file>` |
  | read comments | `gh api repos/{owner}/{repo}/issues/<N>/comments --paginate` |
  | add / remove a label | `gh api repos/{owner}/{repo}/issues/<N>/labels -f 'labels[]=<l>'` · `gh api -X DELETE repos/{owner}/{repo}/issues/<N>/labels/<l>` |
  | read an issue | `gh api repos/{owner}/{repo}/issues/<N>` |
  | read a PR (head sha, body, draft, mergeable) | `gh api repos/{owner}/{repo}/pulls/<N>` |
  | PR files · CI | `gh api repos/{owner}/{repo}/pulls/<N>/files` · `gh api repos/{owner}/{repo}/commits/<sha>/check-runs` |
  | find a PR by branch | `gh api 'repos/{owner}/{repo}/pulls?head=<owner>:<branch>&state=all'` |
  | close an issue | `gh api -X PATCH repos/{owner}/{repo}/issues/<N> -f state=closed -f state_reason=completed` |

  Review threads (`isResolved`) and draft → ready have no REST form; they stay
  GraphQL at 1–2 points each.
- **One read per decision.** Read a thing when a step needs it; a `sleep` loop
  around `gh` spends a point every turn of the loop.

## 1. Source the guard at worker start

```bash
source scripts/super-board-gh-guard.sh
sb_gh_budget_init 150      # per-worker soft cap on gh calls
sb_gh_guard_check 200      # sleep if GraphQL remaining < 200
sb_gh_guard_summary        # log starting quota for the run manifest
```

## 2. Use `sb_gh_guard_check` before any burst

Call it before:

- Reading or resolving PR review threads (Builder rebuild, Tester rebuild, Reviewer).
- Spawning adversarial sub-agents.
- Final self-check verification on exit.

It's a no-op if quota is healthy. It sleeps to reset only if remaining is below threshold. Cheap to call.

## 3. Trust the move's exit code

The Worker self-check item "Card column move re-read and verified" previously required `gh project item-list --limit 500` on every worker exit — ~200 points per worker per lane transition, for very little signal. **Rule:**

- Trust the exit code of `super-board-card.sh move` (it already re-reads stale ids and retries once).
- If it returned non-zero, re-try once with `sb_gh_guard_check 200` first.
- If still non-zero, write the halt comment and exit. Do not re-query the whole board.

## 4. Adversarial mode — sub-agent gh-call cap

When `truth_gate` triggers adversarial mode, each sub-agent (Code-grounder, Historian) MUST stay within `SB_GH_GUARD_SUBAGENT_BUDGET` (default 50) gh calls. The Reviewer passes this budget to each sub-agent via prompt:

> Adversarial sub-agent budget: ≤50 gh calls total. Prefer `git blame` (local) over `gh api graphql` (remote). If you need more than 50 calls to reach a confidence score, return `confidence: "insufficient_data"` and let the Reviewer flag the card as 🛡 truth-check inconclusive — do NOT burn through quota.

## 5. Backoff on 403 / secondary rate limit

If a `gh` call returns 403 or a body containing `secondary rate limit`, do NOT retry immediately. Sleep 60s, then re-check with `sb_gh_guard_check 500` (stricter threshold) before resuming.

## 6. Log remaining quota in your exit handoff comment

Every worker's PR handoff comment MUST include a final line:

```
gh-quota-on-exit: graphql=<n>/5000 rest=<n>/5000
```

Use `sb_gh_guard_summary` to grab the snapshot. This gives the run manifest visibility into which lane is the heaviest consumer over time.

## 7. Per-worker hard cap

`sb_gh_budget_spend` decrements a per-worker call counter. Default 150. If exhausted, the helper returns non-zero — the worker should write a halt comment ("worker-budget exhausted, releasing claim") and exit gracefully. The orphan-scan and reaper will recover the lock; the dispatcher re-tries on next tick when quota has recovered.

---

Pointer: dispatcher-side guard lives in `super-board-run.sh::gh_rate_guard`. The two together are defense in depth — dispatcher pauses before the next tick, worker pauses before its next burst.
