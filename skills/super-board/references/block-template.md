# Block & Skip exit template

Pointer: spec `docs/specs/2026-05-21-super-board-design.md` §4 "Cross-cutting: Block & Skip exits".

`Blocked` and `Skipped` sit AFTER `Done` on the board — they're not workflow steps, they're exit ramps.

## When / who moves cards there

| Column  | When                                       | Who moves cards there                        |
|---------|--------------------------------------------|----------------------------------------------|
| Blocked | Card needs human action                    | Any lane, from any workflow column           |
| Skipped | Card isn't actionable in this loop         | Any lane, from any workflow column           |

Once moved, the card waits. **A card blocked only on other cards no longer waits for a human:**
the wave planner sweeps `Blocked` at the start of every wave, and any card whose `## Blocked by`
issues have all closed is moved back to `Ready` automatically, with a comment saying what cleared
it. Everything else — credentials, permissions, product decisions — still waits for a person.

That sweep is why the `blocked-by:` line below is mandatory. Before it existed, `Blocked` was
terminal: on 2026-08-20 five cards sat there long after their blockers had merged, because the only
record of what they were waiting for was English prose in a comment nobody re-read.

## Required Block/Skip comment template (mandatory on every transition into Blocked or Skipped)

The bot must write a structured comment on **both the issue and the PR** (if a PR exists) explaining *why* it moved the card and *what it couldn't safely decide*. Format:

```
🛡 super-board · <lane> · BLOCKED
─────────────────────────────────────
Card:        #<N> <title>
PR:          #<P> (if exists)
Reason tag:  <emoji from table below>
Why blocked: <concrete; 1 line — name the specific thing that is missing or wrong>
Evidence:    <the command + output, file:line, or error that shows it — not a paraphrase>
Checked:     <what the bot verified before blocking, so nobody re-checks it — or "-">
What blocks: <what specific external action would change this — credentials, perms, decisions>
Why I (bot) cannot decide:
             <one line explaining the decision the bot refuses to make on its own —
              "involves billing config; this is a customer money decision",
              "requires choosing between two valid auth providers; ambiguous from spec",
              "would drop a Postgres table; destructive, needs human sign-off">
To unblock:  <concrete action the human can take, in their own checklist form>
             [ ] <step 1>
             [ ] <step 2>
Owner:       <who acts next — "Eric", "repo admin", "design" — never "someone">
Move back:   drag this card to Ready after the steps above are done
blocked-by:  <comma-separated issue numbers, or "-" if nothing on this board clears it>
```

One line per field. The reader is a human deciding in ten seconds whether this is theirs:
lead with the fact, show the evidence, name the owner. No narration of what the bot tried
in what order.

### The `blocked-by:` line is mandatory

Last line of the block, always present, machine-read. It sits alongside the other machine lines the
lanes already emit (`root-cause-hash:`, `gh-quota-on-exit:`, `move-mutation-result:`) and follows the
same rule: **prose above for the human, one parseable line below for the loop.**

- `blocked-by: 32, 91` — this card returns to `Ready` the moment both close. The sweep does it.
- `blocked-by: -` — nothing on this board clears it. It waits for a person, and the sweep leaves it
  alone. Use this for every `🔐`, `💳`, `🔑`, `🧑` and `🎨` block.

Write the numbers alone. **Never `blocked-by: none — but #26 must merge first`**: a line that says
none and then names an issue is read as *no blocker* by the sweep and as *one blocker* by a human,
and the sweep is the one that acts. That exact shape shipped on a real board and is the reason
`super-board-deps.sh` refuses to guess at it.

The same rule governs the issue body's `## Blocked by` section, which is where the sweep looks when
a card has no block comment yet. Bullets of the form `- #N — why`, or a single `- None.` — nothing
else parses.

Skipped comments use the same template with `🤷 super-board · <lane> · SKIPPED` and replace `Why blocked` with `Why parked`, `What blocks` with `Why out-of-scope for this loop`.

## Reason emoji vocabulary

| Emoji | Class                       | Examples                                                                 |
|-------|-----------------------------|--------------------------------------------------------------------------|
| 🔐    | Credentials / secrets       | missing API key, expired token, no test login                            |
| 💳    | Billing / quota             | paid API rate-limit hit, free tier exhausted, requires plan upgrade      |
| 🔑    | Permissions / access        | gh scope denied, org admin required, write access missing                |
| ❓    | Ambiguity / spec gap        | two valid interpretations, AC contradicts PROJECT.md, dependency unclear |
| 🛡    | Safety / destructive        | would drop a table, would push to prod, would rotate live secrets        |
| 🧑    | Human review needed         | unresolved human PR comment, design decision, branding choice            |
| 🤷    | Out-of-scope                | wrong project, deferred to other milestone, manual-only ticket           |
| 📦    | Wrong-place                 | belongs on a different board / repo                                      |
| 🎨    | Pure design                 | no measurable AC; needs design pass first                                |

## Hard rule

**The bot is forbidden from moving any card to Blocked/Skipped *without* this full template populated. A 1-line "needs creds" comment is a contract violation and fails Reviewer's thread gate.**
