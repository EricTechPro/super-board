# Default taste file

The critic and the refiner read this before any playbook, and findings cite rules by id (`T3`, `S5`). A project replaces it by setting `refine.taste_file` in its super-board config. The best replacement is built from the UI commits the owner kept: each rule paired with a commit SHA or `file:line` as evidence. These defaults are the project-neutral core of Eric's BookKeepingApp calibration.

## Taste

| id | Rule |
|---|---|
| T1 | **Compact controls.** Buttons are content-width, about 32–36px tall, with no shadow. No full-width buttons outside a phone form. Primary is solid; secondary is outline or ghost. |
| T2 | **No icon-tile section headers.** A section gets a plain semibold heading, not an icon in a tile plus a title plus a subtitle. |
| T3 | **Small muted icons are fine.** 14–16px muted icons in front of tabs, row labels and options help scanning. Stripping every icon is also wrong. |
| T4 | **No washes, banners or badges for state.** Colored banners, gradients, pulsing halos and decorative badges go. State shows on the number or as a small quiet mark. |
| T5 | **One color per meaning, from tokens.** Two shades for one meaning is a bug. Raw palette values give way to semantic tokens. Color goes on the figure, never on the whole tile. |
| T6 | **Flat, hairline, aligned.** 1px borders, divided rows, label on the left and control on the right, tabular figures. Rows don't shift on hover or select. Big-radius, big-padding, shadowed card scaffolds go. |
| T7 | **Lead with the one fact that changes.** The headline is the number the visitor came for. Identity and price drop a line. |
| T8 | **A page, not a card above a void.** If the page reads as one small box over empty space, fix the page structure rather than restyling the box. A permanently empty section becomes one line. |
| T9 | **Cut duplicates and chrome.** Remove redundant buttons, a second way to do the same thing, refresh buttons, and "explore more" blocks that the nav or footer already covers. |
| T10 | **Honest, sentence-case copy.** Use sentence case everywhere. Claims match what the product does. Errors say what failed. |
| T11 | **Gated is not greyed.** A plan-gated control stays full color, with a short upgrade hint or a quiet lock after the label. |
| T12 | **Reuse, then extend.** Use the repo's shared components and extend them by prop. A one-off copy is a finding even when it looks good. |

## AI-slop tells

Check every screenshot for these. Each hit becomes a finding that cites the tell and the T-rule it breaks.

- **S1** A grid of 3–4 equal tiles, each with an icon or emoji on top, a bold title and two lines of text. (T6)
- **S2** Numbered step circles for a "how it works" section nobody needs. (T9)
- **S3** A big solid CTA with a leading icon, glow, shimmer or pulse ring, or full width on desktop. (T1)
- **S4** Icon-in-tile section headers, or emoji used as icons. (T2, T3)
- **S5** Pastel banner washes, gradient-tinted alerts, colored badges on everything, animated attention rings. (T4)
- **S6** A gradient or colored keyword in a headline as decoration, or Title Case headlines. (T10)
- **S7** Everything centered, with no left edge to read along. A centered hero line is fine; centered body sections are not.
- **S8** A decorative background (blur blobs, mesh gradients, animated fields) competing with the task.
- **S9** Fake-precise or unverifiable stats ("10,000+ happy users"). A real counter drawn from data is fine.
- **S10** Oversized padding and type on app pages. (T1, T6)
- **S11** Repeated chrome: two headers, a card inside a card, a second CTA saying the same thing as the first. (T9)
- **S12** Empty hero chrome: eyebrow pill, headline, subhead and two buttons with no product visible.

## Page-type intents

- **Marketing or tool page.** The visitor wants the thing *now*. Above the fold: a plain headline, the working tool or product, and one next step. Cut feature-card grids, step circles and anything between the headline and the tool.
- **App or dashboard page.** A signed-in user doing a task many times. Above the fold: one toolbar holding the primary action, then the content, then real data or a proper empty state. Keep it dense, aligned and scannable at 1, 10 and hundreds of rows.
- **Billing or settings page.** The visitor wants what they have, when it renews, and what a change buys. Lead with that fact (T7), with compact actions on the right.

## When the brief is open-ended

For briefs like "make it better", "less AI slop" or "calmer", the critic picks the direction itself, in this order:

1. **Name the page type** and write the visitor's job in one sentence.
2. **Check the slop tells** (S1–S12) against every screenshot. Each hit is a candidate finding.
3. **Rank by what blocks the job.** Anything that pushes the task or the key figure below the fold is P1. Off-taste chrome that does not block the job is P2. Polish is P3.
4. **Prefer cutting over adding.** Remove, merge or shrink before you add a section, a color or an animation. A finding that adds something must say which visitor job it serves.
5. **Stay in the visual world.** Tokens, fonts and shared components stay, unless the brief names them.
