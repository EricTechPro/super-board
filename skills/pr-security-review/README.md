# /pr-security-review

A security pass on one PR: only high-confidence, exploitable vulnerabilities the diff adds.

## What It Does

- **Reviews the PR's diff against its base branch**, not the whole repo: injection, auth and authorization bypass, crypto and secrets, code execution, data exposure.
- **Filters false positives.** One sub-task finds candidates; a parallel sub-task per candidate re-checks it, and anything under 8/10 confidence is dropped.
- **Returns a markdown report**: file:line, severity, category, exploit scenario and fix for each finding.

## When It Runs

- **On every PR, in the QA lane.** `super-qa` runs it as its one security check; each finding fails QA and sends the card back to Super Build.
- Standalone, as `/pr-security-review`, on any branch with a base.

For a deep audit of the whole repository, run `security-audit` (installed alongside, never run by the board).

## Credits

Ported from [anthropics/claude-code-security-review](https://github.com/anthropics/claude-code-security-review) (`.claude/commands/security-review.md`, commit `0c6a49f`). MIT © 2025 Anthropic, see [LICENSE](LICENSE). Only the diff target changed: the PR's base branch instead of `origin/HEAD`.

## Install

Part of the super-board pack: `./install.sh /path/to/project`, or the plugin. Not the same as Claude Code's built-in `/security-review`, which it leaves alone.
