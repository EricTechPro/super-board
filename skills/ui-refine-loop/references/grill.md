# Grill: goal, taste and direction

It runs after you have read the target's code area (SKILL.md step 1) and before setup. It follows the `grilling` skill's pattern: number each question, give your recommended answer under it, and ask the whole current frontier in one message. The difference is a hard budget, because this loop runs unattended afterwards.

## Rules

- **At most 10 questions in total**, across all waves.
- **Waves.** Wave 1 asks 3 questions. Ask a second wave (at most 4) only when the answers leave a decision open that would change what the fixers do. Ask a third (whatever is left of the 10) only when wave 2 opens something new. Most runs stop after wave 1 or 2.
- **Every question accepts "you pick".** Each one ends with `➡️ <your recommended answer>`, grounded in what you read in the code. "You pick", "fine" or silence on a question means your recommendation stands.
- **Facts are yours, decisions are Eric's.** Never ask what the code, `PRODUCT.md`, `DESIGN.md` or an existing taste file already answers. Look it up instead.
- **Taste file exists?** Ask only about this target's goal and direction, and anything the file leaves open. Don't re-ask its rules.

## Question bank (pick, don't recite)

Wave 1, almost always:

1. **Goal.** What should someone be able to do or see on this surface that they can't now? Or what bothers you most?
2. **Direction.** Calmer, bolder, denser or more spacious? Or "same look, just cleaner"?
3. **Keep.** What must not change (brand color, a layout, a component, the copy)?

Wave 2 and later, only when needed:

- Who uses it, and how often? (A first-timer and a daily power user want different density.)
- A reference you like: a product, a page or a screenshot.
- Color: add meaning, or strip it back?
- Type: keep the fonts and scale, or may they change?
- Motion: none, subtle, or expressive?
- Dark mode: must it be first-class, or only not broken?
- Mobile: is the 390 view a priority or an afterthought?
- Anything off-limits for the fixers (files, shared components, copy)?

## Output: the taste and direction file

Write the answers to the path `refine-setup.sh detect` printed as `tasteFile` (`refine.taste_file`, default `docs/design/taste.md`, one per project). If it doesn't exist yet, start from [`taste.md`](taste.md) (the neutral default) and fill in its **Direction** section. If it exists, add or replace this target's `### <target>` block under **Direction** and leave the rest alone. Record "you pick" answers as your recommendation, marked `(picked)`. The file is written inside the refine worktree and committed as the branch's first commit, `💄 [ui] <slug>: taste and direction`, so it reaches the PR for review.
