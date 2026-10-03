# Built-in rubric (fallback, loud)

This is used only when `refine-setup.sh detect` finds no Impeccable install. Detect prints a warning banner and the result carries `degraded`, so the PR says the scores are not Impeccable scores. The rubric keeps the same shape as an Impeccable run: design /20, audit /20, a mechanical check count in place of the detector, and the same command names.

## 1. Visual quality: score each 0–4 (design /20)

4 is genuinely excellent, 3 minor issues, 2 a real visitor notices, 1 hurts the task, 0 broken.

| Dimension | Look for |
|---|---|
| `specificity` | looks like this product; not a template any product could ship |
| `hierarchy` | the eye lands on the primary task or figure first; clear grouping |
| `typography` | one scale, sensible weights, line length, tabular figures, no bad truncation |
| `color` | one meaning per color, from tokens; contrast ≥ 4.5:1; dark mode holds |
| `composition` | one spacing scale, aligned edges, density that fits the use, both widths |

## 2. Audit: score each 0–4 (audit /20)

| Dimension | Pass means |
|---|---|
| `accessibility` | contrast, visible focus, every control named, targets ≥ 24px, headings in order |
| `performance` | no layout shift once data loads, sized images, no heavy client work for this surface |
| `responsive` | nothing clips or scrolls sideways at 390; tables scroll or collapse inside themselves |
| `theming` | values come from tokens or variables; dark mode doesn't break |
| `integrity` | reuses shared components, no copy-pasted forks, no dead props, semantic markup |

## 3. Mechanical checks (stand-in for the detector)

Grep the scope paths for each item, check every hit against the source, and count what survives. The total is `detectorCount`.

- Raw palette colors where the repo has tokens (`#[0-9a-f]{3,6}`, `rgb(`, Tailwind `-(red|amber|blue|…)-[0-9]{3}` when a token layer exists).
- `<img` without `alt`; `<button>` or `<a>` with no text and no `aria-label`; `onClick` on a `div` or `span` with no role.
- Inline `style=` holding layout values the design system already covers.
- Fixed pixel widths above 390 on containers with no responsive override.
- Text sizes or paddings outside the repo's scale (find it in the Tailwind config or theme file).
- Duplicated component bodies: two files in scope with near-identical JSX.
- Gradient text, `animate-pulse` or `animate-ping` used as decoration, or emoji used as icons.

## 4. Command notes (when there are no Impeccable playbooks)

| Command | Means |
|---|---|
| distill | remove duplicate actions, decoration, extra wrappers and redundant copy |
| bolder | raise contrast of scale and weight on the one thing that matters; stronger primary action |
| quieter | fewer colors, weights, borders and shadows; badges become plain text |
| colorize | add color that carries meaning (status, category, the key figure), from tokens |
| layout | fix spacing rhythm, grouping, alignment and reading order |
| typeset | type scale, weights, line length, tabular figures, truncation |
| adapt | mobile and breakpoint behaviour; tap targets; overflow |
| optimize | image sizing, layout shift, needless client work |
| onboard | empty and first-run states that point to the next action |
| clarify | labels, empty and error copy, status words; meaning never changes |
| harden | a11y, focus, error and loading states, long content, i18n |
| animate | short transitions on state change; respect reduced motion |
| delight | one small product-specific touch; never decoration for its own sake |
| extract | pull the repeated pattern into a shared component or token |
| polish | final pass: align, even out spacing, fix small inconsistencies; always last |
