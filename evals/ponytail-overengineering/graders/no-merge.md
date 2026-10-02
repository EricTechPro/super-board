---
type: regex
pattern: 'pr merge'
match: not_contains
target:
  source: file
  path: .gh-log
weight: 1
---

A standalone review reports; it does not merge.
