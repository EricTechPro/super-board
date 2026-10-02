---
type: regex
pattern: 'pr merge'
match: not_contains
target:
  source: file
  path: .gh-log
weight: 1
---

R2 is still unfixed, so the reviewer must not merge PR #12.
