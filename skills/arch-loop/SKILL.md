---
name: arch-loop
description: Run an architecture review as an autonomous find-then-implement loop — one fresh sub-agent per pass, one finding implemented per pass — until two consecutive passes surface nothing new. Use when the user says arch-loop, loop the architecture improvements, keep refining the codebase automatically, or run improve-codebase-architecture until it runs dry.
---

# Arch Loop

An architecture review surfaces deepening opportunities and stops. This runs it as a
loop that also implements, one finding at a time, until it runs dry.

**Each pass is a fresh sub-agent.** Architecture findings are context-hungry. A session
that has already read forty files starts matching on what it saw instead of what is
there. A new sub-agent per pass gets an unbiased read.

## The finder

The pass sub-agent uses the first of these that exists in the project or user skills:

1. `/improve-codebase-architecture` (mattpocock/skills) — tell it to skip its HTML
   report and its grilling step and return findings only.
2. `/codebase-design` — scan with its vocabulary (module, interface, depth, seam,
   adapter, leverage, locality) and its deletion test.
3. Neither installed: scan for shallow modules — an interface nearly as complex as its
   implementation, a pass-through layer, logic for one concept spread across files,
   a seam with one adapter. Weight recently changed files higher (`git log --since`).

Whichever it uses, it reads `CONTEXT.md` and `docs/adr/` when present and does not
re-open a recorded decision.

## The ledger

`docs/arch-loop-ledger.md` is the loop's memory across passes (use the project's own
docs folder if it has one). Create it on the first finding.

```md
## <stable-key>
**Pass:** <n>
**Finding:** <the deepening opportunity, one sentence>
**Status:** implemented | rejected | deferred
**Commit:** <sha, or why not>
```

The key is `<file-or-module>-<one-word-problem>`, e.g. `receipt-store-leaky`. Keys are
how the loop knows what it has already seen.

## Verify commands

Use the project's own: `verify_commands` in the super-board config if there is one,
else the lint, typecheck and test commands named in `AGENTS.md` / `CLAUDE.md`. If none
are named, stop and ask before the first pass — a loop with no proof is not safe to run
unattended.

## One pass

1. **Spawn a fresh sub-agent.** Give it the ledger's keys and nothing else from earlier
   passes. Its job: run the finder, return findings as `{key, finding, files, severity}`.
2. **Drop anything already keyed in the ledger** — implemented, rejected or deferred
   alike. Dedup against the ledger, never only against this pass, or a rejected finding
   returns every pass and the loop never converges.
3. **Nothing new:** increment the dry counter and go to Termination. Otherwise reset it.
4. **Implement exactly one finding** — the highest severity. One per pass keeps each
   commit revertable and the next pass reading a settled codebase.
5. **Prove it** with the verify commands. A finding that changes behaviour a test
   covers must add or update that test.
6. **Commit or revert.** Green: commit `refactor: <finding>` and write the sha to the
   ledger. Red and not fixable in this pass: `git restore` the tree, mark it `deferred`
   with the reason, move on. A pass never leaves the tree broken.
7. **Loop.**

## Termination

Two consecutive passes with no new keys. That is the only clean exit — a finding count
is not a stopping condition, because deepening opportunities do not run out.

Stop before implementing, and report to the user, when:

- A finding needs a schema change, a public API or contract change, or a new dependency.
- A finding touches payments, auth, data deletion, or anything `AGENTS.md` marks as
  needing a human. Record it `deferred`; do not implement it unattended.
- The same finding has been deferred twice. It needs a human.

## Running it

```
/arch-loop
```

Resuming reads the ledger, so an interrupted loop is safe to restart. Stop it at any
time; every completed pass is its own commit.

Work on a branch in a worktree under `.claude/worktrees/`, never on the base branch. On
a super-board project, open one PR for the run and let the merge gate land it.

Adapted from BookKeepingApp's `arch-loop` (Eric Tech).
