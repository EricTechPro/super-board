# Ledger format

The ledger is the loop's only memory across rounds. Each checker receives it in place of the history, so it stays short: one entry per check, one or two lines, ids not prose. The workflow builds it. In the fallback loop the orchestrator writes each entry itself. Either way, write the final ledger to `<runDir>/ledger.md` when the loop ends.

```
C<n> · visual <v>/40 (design <d>/20 · audit <a>/20 · detector <k>) · <baseline|better|same|worse> · P0×… P1×… P2×… P3×… · <committed <sha> | reverted | nothing-to-do> [<command> → … → polish]
  fixed: <ids> · skipped: <ids> · out-of-scope: <file (why)>
```

- **Check n** runs on the state fix n−1 left behind. Check 1 scores the untouched surface (`baseline`). After the last fix round, a **closing check** scores the final state, so the score line always has a real before and after.
- **visual**: the design reviewer's five visual dimensions (/20) plus the detector's audit (/20). No Nielsen.
- **better / same / worse**: the checker's read of the before | after sheets against round-0.
- **ids**: the checker's stable `<area>-<problem>` keys. An id still open after three checks is one the fixers can't land; the finish step lists it as an open question.

Example:

```
C1 · visual 22/40 (design 11/20 · audit 11/20 · detector 6) · baseline · P0×0 P1×2 P2×3 P3×1 · committed 4f2a9c1 [distill → layout → polish]
  fixed: summary-strip-cramped, header-duplicate-actions · skipped: export-menu-copy (needs Eric: wording)
C2 · visual 27/40 (design 14/20 · audit 13/20 · detector 2) · better · P0×0 P1×1 P2×2 P3×0 · committed 9b03e7d [harden → polish]
  fixed: dark-table-contrast · skipped: —
C3 · visual 29/40 (design 15/20 · audit 14/20 · detector 1) · better · P0×0 P1×0 P2×2 P3×0 · committed 1c77d20 [typeset → polish]
  fixed: table-figures-proportional · skipped: —
C4 · visual 30/40 (design 16/20 · audit 14/20 · detector 1) · better · clean (2nd in a row) · P0×0 P1×0 P2×1 P3×0
```
