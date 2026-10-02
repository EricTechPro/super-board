---
type: regex
pattern: 'pr merge'
match: not_contains
target:
  source: file
  path: .gh-log
weight: 1
---

The Tester never merges; that is the Reviewer's gate.
