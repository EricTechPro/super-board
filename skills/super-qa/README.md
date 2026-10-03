# /super-qa

The Tester: proves a card's acceptance criteria with tests and evidence, or sends it back to Build with a precise failure.

## What It Does

- **One observable test per AC**, written at the layer the defect lives (unit or integration in Vitest, e2e in Playwright only when the browser is what broke).
- **Test-gap check after build**: maps every AC to tests, hunts edge cases with exact values, names weak tests. High gaps are written red-first; Medium/Low are listed and never block.
- **Captures evidence**: screenshots at desktop, tablet and mobile, logs and HARs, committed to the branch and embedded inline in the PR comment.
- **Files what it finds** off-ticket as `source:qa` cards instead of fixing them silently.

## When To Use It

- Inside a super-board run (the QA lane). This is the normal path.
- Standalone, as `/super-qa`, to bug-bash an app: a browser crawl from `docs/super-qa/queue.md` that grows a Playwright suite and files fix-ready issues.

## Standalone flags

| Command | Does |
|---|---|
| `/super-qa` | 10 iterations |
| `/super-qa 5` | 5 iterations |
| `/super-qa --resume` | Continue from the last iteration |
| `/super-qa --continue-on-error` | Don't halt on one failed iteration |

## Install

Part of the super-board pack: `./install.sh /path/to/project`. Run it against staging, not production. Lane details: `skills/super-board/references/run.md` → Tester.
