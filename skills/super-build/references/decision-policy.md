# Decision policy for super-board workers

Workers run unattended. When the issue forces a judgment call the issue body
does not settle, the worker resolves it with an **advisor panel** and records
the result in the commit — it never blocks on the user.

This file replaces the former `gstack-voting.md`. The `gstack` CLI and the
`superpowers` / `gsd` skill packs are no longer dependencies; everything below
runs with the skills listed in the skill map or with plain inline reasoning.

## Skill map

The vocabulary every super-board worker uses. Left column is the intent; right
column is the skill to invoke.

| Intent | Skill |
| --- | --- |
| Which skill / flow fits this situation | `mattpocock-skills:ask-matt` |
| Build a feature or fix a bug test-first | `mattpocock-skills:tdd` |
| Root-cause a hard bug or perf regression | `mattpocock-skills:diagnosing-bugs` |
| Review a diff before approving it | `mattpocock-skills:code-review` |
| Stress-test a plan, decision, or ambiguous issue | `mattpocock-skills:grilling` |
| Turn a settled discussion into a spec | `mattpocock-skills:to-spec` |
| Break a spec into tracer-bullet tickets | `mattpocock-skills:to-tickets` |
| Design a module interface / find deepening opportunities | `mattpocock-skills:codebase-design` |
| Pin domain terminology or record an ADR | `mattpocock-skills:domain-modeling` |
| Resolve an in-progress merge/rebase conflict | `mattpocock-skills:resolving-merge-conflicts` |
| Prove a claim before calling work done | `verification-before-completion` |
| Decide *which kind* of test a change needs | `testing-strategy` |
| Write a unit or integration test (TS/JS) | `vitest` |
| Write a browser e2e spec | `playwright-best-practices` |
| Feature ticket with undefined UX | `shape` |
| Copy / microcopy / error-message wording | `clarify` |

The last six have no equivalent in the Matt Pocock pack and are kept as-is.
Everything else routes through `mattpocock-skills:*`.

**Testing is three layers, not one skill.** They answer different questions:

- **Discipline** — `mattpocock-skills:tdd`. Seams, red-green order, assertion
  anti-patterns. Deliberately agnostic about the *kind* of test, which is why
  it is not enough alone.
- **Placement** — the localisation ladder. Walk down and stop at the first rung
  that still reproduces: (1) call the module directly → unit; (2) wire real
  collaborators → integration; (3) drive a browser → e2e; (4) needs a live
  third party → not a test, file a mock/contract gap. Write it at the rung you
  stopped on, not the rung you found it on.
- **Mechanics** — the repo decides the library, so read `package.json`. TS/JS
  unit and integration → `vitest`. Browser e2e → `playwright-best-practices`.

`testing-strategy` informs *coverage* (what a component type is worth testing,
what to skip) — it does not decide placement.

Two gates before a test counts as done: it must go **red for the right reason**
against the unfixed code (a timeout or missing selector means you pinned the
harness, not the bug), and it must **survive a refactor** that leaves behaviour
unchanged.

## When to convene the panel

Convene it when the issue body or the in-flight implementation forces a
non-obvious decision:

- **Scope ambiguity** — the fix has multiple plausible boundaries (fix one
  symptom vs. refactor the call site vs. rewrite the module).
- **Compatibility tradeoff** — a fix is correct but would break a public
  contract or a downstream consumer.
- **Security-adjacent change** — touching auth, secrets, permissions, or any
  data flow that crosses a trust boundary.
- **Design choice with no precedent** — the codebase has no existing pattern
  for what the issue asks for.

Do **not** convene it for routine work:

- Mechanical fixes (typo, lint, off-by-one, missing import).
- Bugs whose fix is dictated by an existing test or spec.
- Issues with explicit acceptance criteria that leave no judgment call.

## How to run it

1. **Sharpen the question first.** Invoke `mattpocock-skills:grilling` on the
   decision to force the real options out into the open. A panel voting on a
   badly-framed question produces a confident wrong answer.
2. **Poll the roles that apply.** Each returns one sentence and one option:
   - **Eng** — invoke `mattpocock-skills:code-review` against the working diff
     when one exists; otherwise reason inline about regression surface.
   - **Product / scope** — inline: which option delivers the issue's acceptance
     criteria with the least unasked-for scope?
   - **Security / risk** — inline: does either option move data across a trust
     boundary, widen a permission, or touch a secret?
   - **Design / UX** — inline: which option matches an existing pattern in this
     codebase?
   - **QA** — inline: which option is easier to pin with a deterministic test?
3. **Take the majority.** Tie → smallest blast radius (least irreversible,
   smallest scope, easiest to revert).
4. **Record the vote in the commit message** under a `--- decision-vote ---`
   trailer so the orchestrator and downstream reviewers can audit the choice:

```
fix(orders): use idempotency key from request header (closes #123)

<one-line summary>

--- decision-vote ---
- Product: B (ship the smaller change, revisit later)
- Eng: B (less surface area to regress)
- Security: B (no auth boundary touched)
- Design: A (matches existing pattern in /payments)
- QA: B (easier to write a deterministic test)
vote: B (4 of 5)
```

## When to escalate to human instead

The panel is a tiebreaker for **gray decisions**, not a replacement for explicit
policy. Escalate to human (print `HUMAN GATE TRIPPED: <reason>`, label the issue
`human-gated`, leave the worktree intact, exit non-zero) when:

- The fix would require a production deploy or a destructive DB change.
- The vote splits with no clear majority.
- Any role raises an explicit deal-breaker (security flags an auth bypass, etc.).
- The issue itself is unclear about what "fixed" means.

Halts here cost less than a regression in production.
