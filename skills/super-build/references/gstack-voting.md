# GStack voting for Super Build workers

Per the PDF guide ("Stop Using /goal"), Super Build workers should consult
GStack (the multi-role AI advisory plan by Gary Tan / Y Combinator) on
ambiguous fix decisions. GStack polls CEO, eng manager, security, design,
and QA roles, takes the majority vote, and breaks ties via smallest blast
radius.

## When to invoke

Use GStack inside a worker session when the issue body or in-flight
implementation forces a non-obvious decision:

- **Scope ambiguity** — the bug fix has multiple plausible boundaries
  (fix one symptom vs. refactor the call site vs. rewrite the module).
- **Compatibility tradeoff** — a fix is correct but would break a public
  contract or downstream consumer.
- **Security-adjacent change** — touching auth, secrets, permissions, or
  any data flow that crosses a trust boundary.
- **Design choice with no precedent** — the codebase has no existing
  pattern for what the issue asks for.

Do **not** invoke for routine work:

- Mechanical fixes (typo, lint, off-by-one, missing import).
- Bugs whose fix is dictated by an existing test or spec.
- Issues with explicit acceptance criteria that leave no judgment call.

## How to invoke

If the user has the `gstack` CLI installed:

```bash
gstack vote --topic "<one-line decision>" \
  --context "<file path or short summary>" \
  --options "A: <option>" "B: <option>" "C: <option>"
```

If `gstack` is not installed, fall back to inline role-play in the worker:
synthesize one sentence per role (CEO, eng manager, security, design, QA)
weighing the options, then take majority vote. Document the vote in the
commit message under a `--- gstack-vote ---` trailer:

```
fix(orders): use idempotency key from request header (closes #123)

<one-line summary>

--- gstack-vote ---
- CEO: B (ship the smaller change, revisit later)
- Eng: B (less surface area to regress)
- Security: B (no auth boundary touched)
- Design: A (matches existing pattern in /payments)
- QA: B (easier to write a deterministic test)
vote: B (4 of 5)
```

The vote stays attached to the commit so the orchestrator and downstream
reviewers can audit why a non-obvious choice was made.

## When to escalate to human instead

GStack is a tiebreaker for **gray decisions**, not a replacement for
explicit policy. Escalate to human (label issue `human-gated`, leave
worktree intact, stop) when:

- The fix would require production deploy or destructive DB change.
- The vote is split 2-2-1 with no clear majority.
- Any role explicitly raises a "this is a deal-breaker" signal (security
  reviewer flags an auth bypass, etc.).
- The issue itself is unclear about what "fixed" means.

Halts here cost less than a regression in production.
