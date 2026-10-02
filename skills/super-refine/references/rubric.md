# Built-in critique rubric

This is the fallback for when Impeccable is not installed. It keeps the loop's scores comparable to an Impeccable run: ten heuristics out of 40, five audit dimensions out of 20, and a mechanical check count in place of the detector.

## 1. Heuristics: score each 0–4 (total out of 40)

Score 4 when nothing is wrong, 3 for minor friction, 2 when a real user stumbles, 1 when the task is hard, and 0 when it is broken. Mark a heuristic n/a only when the surface truly has nothing to judge for it, and drop it from `heuristicsMax`.

| # | Heuristic | Look for |
|---|---|---|
| H1 | Visibility of system status | loading, saving and empty states; feedback after an action |
| H2 | Match with the real world | domain words, not internal jargon; natural order |
| H3 | User control and freedom | undo, cancel, back, escape from dialogs |
| H4 | Consistency and standards | one name and one style per concept; platform conventions |
| H5 | Error prevention | constraints, confirmations on destructive actions, sane defaults |
| H6 | Recognition over recall | labels on controls, visible options, context kept on screen |
| H7 | Flexibility and efficiency | shortcuts, bulk actions, density that fits repeat use |
| H8 | Aesthetic and minimalist design | no chrome competing with the task; clear hierarchy |
| H9 | Error recovery | errors say what failed and how to fix it, near the cause |
| H10 | Help and documentation | inline hints where a task is not obvious |

## 2. Audit dimensions: score each 0–4 (total out of 20, audit rounds only)

| Dimension | Pass means |
|---|---|
| Accessibility | text contrast ≥ 4.5:1, focus visible, every control has a name, touch targets ≥ 24px, headings in order |
| Performance | no layout shift once data loads, images sized, no huge client bundles for this surface |
| Responsive | nothing clips or scrolls sideways at 390, tap targets reachable, tables collapse or scroll inside themselves |
| Theming | colors and spacing come from tokens or variables, not raw values; dark mode does not break if the app has one |
| Implementation integrity | reuses shared components, no copy-pasted forks, no dead props, markup is semantic |

## 3. Mechanical checks (stand-in for `impeccable detect`)

Grep the scope paths for each item below and count the hits that survive checking against the source. The total is `detectorCount`.

- Raw palette colors where the repo has tokens (`#[0-9a-f]{3,6}`, `rgb(`, Tailwind `-(red|amber|blue|…)-[0-9]{3}` when a token layer exists).
- `<img` without `alt`, `<button` or `<a` with no text and no `aria-label`, `onClick` on a `div`/`span` with no role.
- Inline `style=` holding layout values the design system already covers.
- Fixed pixel widths above 390 on containers without a responsive override.
- Text sizes or paddings outside the repo's scale (find the scale in the Tailwind config or theme file).
- Duplicated component bodies: two files in scope with near-identical JSX.

## 4. Verb notes (used by the refiner when there are no Impeccable playbooks)

| Verb | Means |
|---|---|
| polish | align, even out spacing, fix small inconsistencies; no structural change |
| distill | remove: duplicate actions, decoration, extra wrappers, redundant copy |
| layout | fix structure: hierarchy, grouping, reading order, responsive breakpoints |
| typeset | type scale, weight, line length, tabular figures, truncation |
| clarify | labels, empty and error copy, status wording; meaning never changes |
| adapt | mobile and responsive behaviour |
| harden | a11y, focus, error and loading states, long-content edge cases |
| onboard | first-run and empty states that point to the next action |
| quieter | lower visual volume: fewer colors, weights, borders and shadows |
| optimize | render cost: image sizing, layout shift, needless client work |
