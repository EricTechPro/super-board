# Design preflight

Compare two designs before an unsettled choice creates a new ownership boundary,
new/changed public interface, or architecture expensive to reverse. Labels alone do not
trigger this step. Ordinary bugs and mechanical refactors keep the normal path.

## Establish the decision

1. Read the current flow and its owners/callers, `PROJECT.md` and `CONTEXT.md` when present,
   and applicable specs/ADRs. Name the question and the constraints with source references.
2. Follow an applicable recorded decision when it answers the question. Finish here rather
   than reopening it to produce options.
3. Confirm who may choose. Interactive lint proposes a choice to the user in the existing
   per-issue loop. Workers compare only authorized technical forks at rung 3 of the
   [decision policy](../../super-build/references/decision-policy.md). Ambiguous product
   intent, an unauthorized auth/trust change or a public-contract break takes its human gate.

## Compare and choose

Use `mattpocock-skills:codebase-design` for module depth and interfaces. Reach
`mattpocock-skills:domain-modeling` only when terminology or an ADR needs work. Workers
recheck [conditional skill readiness](skills-readiness.md) before activating either helper.

Sketch two genuinely different arrangements of callers and modules. For each, record:

- **Owner and interface:** who owns state/behavior, which callers use it, and what they pass/get.
- **Constraints:** how it satisfies the recorded requirements and existing contracts.
- **Module depth:** what useful work it hides behind how much caller knowledge.
- **Blast radius:** which callers, data or contracts change.
- **Migration and reversal:** how existing callers move and what undoing the choice costs.
- **Verification:** the observable behavior and project checks that would prove it.
- **Deletion test:** what capability or complexity vanishes if the module is removed.

Renaming the same arrangement is not a second design. Sketches are enough; build only the
chosen design unless the ticket already authorizes a prototype. Choose the minimal design
that meets the constraints, then state why it wins and the main tradeoff.

## Retain the choice

Interactive lint shows the comparison and proposed choice, then saves only the exact issue
edit approved in its existing loop. Put a compact decision and rationale in Context, or
link an applicable spec/ADR. Its local-write boundary remains unchanged. A worker records
its rung-3 choice in the existing commit decision trailer, with the evidence reference.
Keep existing ticket sections, lanes and human gates.

Done means the applicable recorded design was followed, or both sketches and a justified
choice are available to the next worker/reviewer. An unresolved human choice stays blocked.
Design quality remains agent judgment; format and installer checks do not prove the sketches
are distinct or the selected design is good.
