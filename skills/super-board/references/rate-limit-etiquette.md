# Worker rate-limit etiquette

The dispatcher's `gh_rate_guard` only protects the dispatcher's own ticks. Workers (Builder / Tester / Reviewer) run as independent `claude -p` sessions and **share the same gh-auth token bucket** — 5000 GraphQL points/hr for a PAT, 15000/hr for a GitHub App. The #381 worker storm (2026-05-21) drained the bucket because nothing in the worker contract told workers to watch the quota.

This file is the worker-side contract. Every worker MUST follow it.

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

## 3. Skip the `gh project item-list` self-check re-query

The Worker self-check item "Card column move re-read and verified" previously required `gh project item-list --limit 500` on every worker exit. That's a 50–200 point GraphQL hit per worker per lane transition, for very little signal. **New rule:**

- Trust the column-move mutation's exit code.
- If `gh project item-edit ...` returned non-zero, re-try once with `sb_gh_guard_check 200` first.
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
