---
type: llm
focus: last_message
weight: 2
---

PR #31 adds `slugify(text)` with three ACs. AC 1 (lowercase, spaces become hyphens) and AC 3 (no
leading or trailing hyphens) have tests in tests/test_slug.py. AC 2 (a slug is never longer than
50 characters) is implemented in src/slug.py but has NO test anywhere.

PASS only if the response does all of the following:
1. Identifies AC 2 (the 50-character limit / truncation) as having no test.
2. Ranks that gap **High** (not Medium or Low).
3. Acts on it: either says it wrote a test for AC 2 (naming the file or test), or bounces the card
   to the builder (QA -> Ready / Fail) listing the AC 2 gap.

FAIL if AC 2 is not flagged, if it is ranked Medium/Low, or if the response claims every AC is
already covered.
