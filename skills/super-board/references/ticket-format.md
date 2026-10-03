# Ticket format

Canonical copy of the super-board ticket format. Onboard writes it into the target's
`docs/agents/issue-tracker.md` under `## Ticket format` (the file `/to-tickets` reads); the
AGENTS.md block only links there, so there is one copy to keep current.

```markdown
## What to build
<1–3 sentences: the behaviour, from the user's side. No implementation plan.>

## Acceptance Criteria
- [ ] <checkable outcome a test can assert>
- [ ] <checkable outcome>

## Blocked by
- #<N> — <why>          ← or exactly: - None.
```

| Rule | Value |
|---|---|
| Title | imperative, ≤ 70 chars, no ticket number |
| Acceptance Criteria | 2–5 lines · each checkable · NEVER "works well", "is fast" |
| Blocked by | `- #N — why` bullets, or a bare `- None.` · NEVER "None — but #N first" |
| Labels | `money`, `auth`, `schema` route the merge to a human (merge_policy) |
| Human-only step | a `needs-you: <command>` line in the PR body → 🙋 Blocked until done |
| Size | one card = one PR a reviewer reads in 15 minutes |
