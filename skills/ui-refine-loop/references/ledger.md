# Ledger format

The ledger is the loop's only memory across rounds. Each critic receives it in place of the history, so it stays short: one entry per round, two or three lines, ids not prose. The workflow builds it; in the fallback loop the orchestrator writes each entry itself. Either way, write the final ledger to `<runDir>/ledger.md` when the loop ends.

```
R<n> · <score>/40 · audit <a>/20 · <committed <sha> | reverted | DONE> [<verbs>]
  fixed: <finding ids> · skipped: <ids> · out-of-scope: <file (why)>
  remaining after: <severity id>, <severity id>, …
```

- **audit** — the audit runs only on round 1, every third round and the rounds that may end the loop; other rounds carry the last value forward, marked `(carried)`.
- **score** — the critic's heuristics total normalised to /40 (`total / max × 40`, one decimal), so rounds that marked heuristics n/a stay comparable.
- **ids** — the critic's stable `<area>-<problem>` keys. An id that stays in "remaining" for three or more rounds is a finding the refiner cannot land; the finish step lists it for Eric as an open question.

Example:

```
R1 · 23/40 · audit 13/20 · committed 4f2a9c1 [layout, typeset]
  fixed: summary-strip-cramped, chart-axis-illegible · skipped: export-menu-copy (needs Eric: wording)
  remaining after: P2 export-menu-copy, P3 table-status-pill-contrast
R2 · 27.5/40 · audit 15/20 · committed 9b03e7d [clarify, polish]
  fixed: table-status-pill-contrast · skipped: —
  remaining after: P2 export-menu-copy
R3 · 28/40 · audit 16/20 · DONE · no refine; next critic confirms · remaining P0×0 P1×0 P2×1 P3×0
```
