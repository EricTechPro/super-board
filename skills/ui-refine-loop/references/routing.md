# Routing: problem type → Impeccable command

The checker gives every problem one `type`. The workflow attaches this table's default `route` to each problem and suggests a chain. The **fixer** makes the final call: it can merge, reorder or swap commands when the code shows a better fit, and records what it actually ran in `commands`.

| `type` | Signal | Command |
|---|---|---|
| `cluttered` | too much on screen, duplicate actions, chrome competing with the task | `distill` |
| `bland` | safe, generic, forgettable; the brief asks for more presence | `bolder` |
| `too-loud` | too many colors, weights, borders, shadows or badges; shouting | `quieter` |
| `dull-color` | gray, flat, monochrome where color should carry meaning | `colorize` |
| `spacing-hierarchy` | cramped or loose spacing, weak hierarchy, poor grouping or alignment | `layout` |
| `typography` | fonts, type scale, weights, line length, figures | `typeset` |
| `responsive` | breaks at 390, breakpoints, touch targets, sideways scroll | `adapt` |
| `performance` | slow, janky, layout shift, heavy images or bundles | `optimize` |
| `first-run-empty` | empty state or first-run that does not point to the next action | `onboard` |
| `confusing-copy` | labels, errors, status words or instructions that confuse | `clarify` |
| `edge-cases` | long content, errors, loading, i18n, overflow | `harden` |
| `accessibility` | contrast, focus, names, keyboard, headings | `harden` |
| `needs-motion` | state changes with no feedback; the brief asks for motion | `animate` |
| `personality` | correct but lifeless; the brief asks for character | `delight` |
| `drift` | the same pattern copied 3+ times, raw values next to tokens, one-off components | `extract` |
| `polish` | small misalignments and inconsistencies, no structural change | `polish` |

## Chaining

1. Run the commands in severity order of the problems they fix. When severities tie, run structural commands before surface ones: `distill` / `extract` → `layout` / `adapt` → `typeset` / `colorize` / `quieter` / `bolder` → `clarify` / `harden` / `onboard` → `animate` / `delight` / `optimize`.
2. **`polish` always runs last**, once, over everything the round touched, even when no problem was typed `polish`.
3. One round is one coherent batch. If two commands pull against each other (`bolder` and `quieter` on the same element), keep the higher-severity one and skip the other with a reason.
4. `bolder`, `colorize`, `animate` and `delight` add things. Run them only when the brief or the taste file's direction asks for more. Otherwise skip with the reason "direction says calmer" or similar.

Without Impeccable (rubric method), the same commands apply, using the notes in [`rubric.md`](rubric.md) §4 instead of the playbooks.
