## Problem
Date-only strings (`2026-09-01`) are parsed as UTC midnight and read back with local getters, so for users west of UTC the 1st of a month lands in the previous month. Two merged PRs hit it in 14 days.

## Context
- **Where:** date handling, `src/reports/monthly.ts`, `src/budgets/alerts.ts`
- **Boundary:** both callers convert a date-only value through UTC midnight and local month getters. Each PR fixed its own call site; the conversion remains available to the next caller.

## Evidence
- PR #21 · super-review R1 `src/reports/monthly.ts:42` · thread by eric (America/Vancouver)
- PR #24 · super-review R1 `src/budgets/alerts.ts:18` · coderabbitai thread

## Fix
Route both callers through one date-only owner that preserves the calendar month and closes the unsafe conversion path. Reuse an adequate existing owner when available.

## Acceptance Criteria
- [ ] Both month-bucketing features put date-only `2026-09-01` in September under `TZ=America/Vancouver`.
- [ ] Retain the cited prior bad witness: it fails old behavior for the month invariant, passes after correction and survives a behavior-preserving refactor. If the historical witness cannot be recovered, leave this proof unverified.

## Risk
🟡 **Medium** · touches two features' month logic.
