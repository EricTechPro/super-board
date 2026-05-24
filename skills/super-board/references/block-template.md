# Block & Skip exit template

Pointer: spec `docs/superpowers/specs/2026-05-21-super-board-design.md` §4 "Cross-cutting: Block & Skip exits".

`Blocked` and `Skipped` sit AFTER `Done` on the board — they're not workflow steps, they're exit ramps.

## When / who moves cards there

| Column  | When                                       | Who moves cards there                        |
|---------|--------------------------------------------|----------------------------------------------|
| Blocked | Card needs human action                    | Any lane, from any workflow column           |
| Skipped | Card isn't actionable in this loop         | Any lane, from any workflow column           |

Once moved, the card is out of the loop. Human drags it back to `Ready` when unblocked.

## Required Block/Skip comment template (mandatory on every transition into Blocked or Skipped)

The bot must write a structured comment on **both the issue and the PR** (if a PR exists) explaining *why* it moved the card and *what it couldn't safely decide*. Format:

```
🛡 super-board · <lane> · BLOCKED
─────────────────────────────────────
Card:        #<N> <title>
PR:          #<P> (if exists)
Reason tag:  <emoji from table below>
Why blocked: <concrete; 1 line — name the specific thing that is missing or wrong>
What blocks: <what specific external action would change this — credentials, perms, decisions>
Why I (bot) cannot decide:
             <one line explaining the decision the bot refuses to make on its own —
              "involves billing config; this is a customer money decision",
              "requires choosing between two valid auth providers; ambiguous from spec",
              "would drop a Postgres table; destructive, needs human sign-off">
To unblock:  <concrete action the human can take, in their own checklist form>
             [ ] <step 1>
             [ ] <step 2>
Move back:   drag this card to Ready after the steps above are done
```

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
