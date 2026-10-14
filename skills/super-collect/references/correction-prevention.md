# Prevent a recurring mistake

For `prs` candidates, the finder and fresh verifier use the cited prior findings to name
one shared boundary, the actual failing input/action and what allowed it. Group by that
cause. A one-off finding remains outside recurrence intake.

## Choose the correction

Prefer the strongest appropriate correction:

1. Remove the invalid path/operation, or route callers through an already adequate owner.
2. Express the invariant in a type/schema when it fits.
3. Guard the boundary with lint/runtime checks and an actionable error when static expression
   cannot cover it.
4. Cover the remaining possible mistake with a behavior regression witness.
5. Reserve prose for judgment that cannot appropriately be enforced.

Stop where the correction fits. These are preferences, not five required mechanisms.
Choose an existing owner before inventing a helper; add no dependency, abstraction or custom
linter solely to climb the list. The proposed correction must address the permitting boundary,
not merely repeat a reminder or patch another call site.

## Propose proof, then verify delivery

Keep the [ticket sections](../../super-board/references/ticket-format.md). Context names the
boundary and failing input/action; Evidence cites the prior PR/comment/finding and retained
witness source. Fix states intended prevention in 1–3 lines. A behavioral AC requires:

- The actual prior bad witness fails against old behavior for the reported invariant.
- That same witness passes after correction.
- A behavior-preserving refactor still passes, without asserting filenames or helper names.

Use the worker's [test gates](../../super-build/references/decision-policy.md#skill-map)
for placement and correct red. Missing dependencies, selectors, setup errors and unrelated
timeouts do not prove the incident. If the actual witness cannot be reconstructed, say so
and leave its proof/AC unverified. An invented sample cannot replace historical proof.

Collect proposes this AC; it does not implement or execute the product regression. The fresh
verifier checks the source and current applicability, then normal dedupe and user curation
file only into Backlog. Canned fixtures demonstrate intake behavior, not a live incident.

## Calibration authority

Apply the same correction preference to a completed run's bounded lessons. Product changes
in ownership, types, schemas, guards or tests remain proposals for ordinary verified,
curated Backlog intake. Calibration may edit only its explicit existing canonical SKILL.md
allowlist using current-run evidence. Follow the host's
[calibration scope](../../super-board/references/calibration.md#delegate-the-installed-skill)
and diff inspection; a stronger product mechanism does not expand edit authority.
