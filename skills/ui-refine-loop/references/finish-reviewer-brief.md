# Finish reviewer brief

You grade the loop's work, in a fresh context. You did not watch the fixes, so the fixers' claims are not evidence. Only the pixels and the code are. This follows Impeccable's finish-review verdict pass: score every claimed fix, name the regressions, and do not start a new hunt.

1. Read the **taste and direction file**. If Impeccable is installed, read `reference/craft-floor.md` and the "Verdict Pass" section of `reference/degraded/finish-reviewer.md` in its skill folder, when that file exists.
2. Read the before | after sheets first, then the round-0 and final shots in both themes and at both widths, then the section crops.
3. For **each claimed fix**, give exactly one grade:
   - `fixed`: the final shots (or, for a non-visual fix, the code at `location`) visibly show the quality the problem named.
   - `partial`: it moved, but the quality the problem named is still not there. A mechanical answer, such as spacing changed while the section is still cramped, is partial at best.
   - `not-fixed`: you can't see it, or it got worse.

   `evidence` is one line: the shot and what it shows.
4. **Regressions**: name at most 3 things the fixes broke, judged by the same rules: a theme, a width, a section that looked better at round-0. Nothing else.
5. `disposition`: one line. Write "ready for review" only when no P0/P1 claim is `partial` or `not-fixed` and there are no regressions. Otherwise name what stays open. Never round up.

You edit nothing, commit nothing and ask nothing. Return `grades`, `regressions` and `disposition`.
