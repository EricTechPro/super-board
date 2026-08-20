# Decision policy for super-board workers

Workers run unattended. When the issue forces a judgment call the issue body
does not settle, the worker resolves it with the **decision ladder** below and
records the choice in the commit — it never blocks on the user.

This file replaces the former `gstack-voting.md`. The `gstack` CLI and the
`superpowers` / `gsd` skill packs are no longer dependencies; everything below
runs with the skills listed in the skill map or with plain inline reasoning.

**The advisor panel is gone as of 2.2.0.** It convened `grilling` inside a
worker that is forbidden to ask the user anything — and `grilling`'s own
contract is "put each question to them and wait." A worker either stalled on
it or answered its own questions, which is inline reasoning wearing a costume.
Ticket ambiguity is now caught upstream, where a human is actually present:
`super-board lint` routes vague and multi-interpretation issues through
`mattpocock-skills:grilling` before the loop ever starts. See `../../super-board/references/lint.md`.

## Skill map

The vocabulary every super-board worker uses. Left column is the intent; right
column is the skill to invoke.

| Intent | Skill |
| --- | --- |
| Which skill / flow fits this situation | `mattpocock-skills:ask-matt` |
| Build a feature or fix a bug test-first | `mattpocock-skills:tdd` |
| Root-cause a hard bug or perf regression | `mattpocock-skills:diagnosing-bugs` |
| Review a diff before approving it | `mattpocock-skills:code-review` |
| Turn a settled discussion into a spec | `mattpocock-skills:to-spec` |
| Break a spec into tracer-bullet tickets | `mattpocock-skills:to-tickets` |
| Design a module interface / find deepening opportunities | `mattpocock-skills:codebase-design` |
| Pin domain terminology or record an ADR | `mattpocock-skills:domain-modeling` |
| Resolve an in-progress merge/rebase conflict | `mattpocock-skills:resolving-merge-conflicts` |
| Prove a claim before calling work done | `verification-before-completion` |
| Decide *which kind* of test a change needs | `testing-strategy` |
| Write a unit or integration test (TS/JS) | `vitest` |
| Write a browser e2e spec | `playwright-best-practices` |

The last four have no equivalent in the Matt Pocock pack and are kept as-is.
Everything else routes through `mattpocock-skills:*`.

**Interactive-only, never inside a worker.** These need a human at the keyboard
and belong to the `lint` verb, not to a lane:

| Intent | Skill | Runs in |
| --- | --- | --- |
| Stress-test a vague or ambiguous ticket | `mattpocock-skills:grilling` | `super-board lint` |
| Feature ticket with undefined UX | `shape` | `super-board lint` |
| Copy / microcopy / error-message wording | `clarify` | `super-board lint` |

If a worker reaches for one of these, that is the signal the ticket should have
been caught by `lint`. Take the human gate instead — see below.

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

## The decision ladder

Most forks in a worker run are not gray at all — they are already settled by
something written down. Walk the ladder and **stop at the first rung that
answers the question**. Do not climb past a rung that gave you an answer.

```
  1  acceptance criteria   the issue body says which behaviour is correct
  2  repo precedent        an existing pattern in this codebase already does this
  3  smallest blast radius  neither settles it → least irreversible, smallest
                            scope, easiest to revert
  4  human gate            the fork is not yours to make → stop, exit non-zero
```

Rung 3 is the default resolution, not a coin flip: prefer the change that
touches fewer files, adds no public surface, and can be reverted by dropping
one commit. When two options tie on blast radius, take the one an existing test
already constrains.

**One technical check is still mandatory before the final commit:** run
`mattpocock-skills:code-review` against your own working diff, passing the
merge-base as the fixed point (`git merge-base HEAD origin/<base>`). It never
asks the user anything when the fixed point is supplied. Findings on its
Standards axis are yours to fix before you commit; findings on its Spec axis
that contradict the issue's acceptance criteria are a rung-4 human gate.

## Recording the decision

Any fork you resolved at **rung 3** goes in the commit message under a
`--- decision ---` trailer, so the orchestrator and downstream reviewers can
audit it. Rungs 1 and 2 need no trailer — the AC or the precedent is the record.

```
fix(orders): use idempotency key from request header (closes #123)

<one-line summary>

--- decision ---
question: reuse the request header key, or mint a server-side key per order?
chose: request header — the client already retries with a stable key
rung: 3 (blast radius — no schema change, revertable in one commit)
```

## Hard human gates

The ladder resolves gray decisions. It is not a licence to guess at decisions
that were never the worker's to make. Print `HUMAN GATE TRIPPED: <reason>`,
label the issue `human-gated`, leave the worktree intact, and exit non-zero when:

- The fix would require a production deploy or a destructive DB change.
- The change touches auth, secrets, permissions, or moves data across a trust
  boundary — and the issue body does not explicitly authorise it.
- The issue itself is unclear about what "fixed" means.
- The fix is correct but would break a public contract or a downstream consumer.
- `code-review`'s Spec axis says the diff does not implement the stated AC and
  you cannot close the gap within the issue's scope.
- You find yourself wanting `grilling`, `shape`, or `clarify` — the ticket
  needed a human before the loop started.

Halts here cost less than a regression in production. When the work so far is
salvageable but the gate blocks completion, prefer `WIP-PARTIAL` over a halt —
see `worker-preamble.md` §6.
