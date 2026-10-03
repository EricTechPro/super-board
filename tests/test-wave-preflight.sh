#!/usr/bin/env bash
# Tests the Builder pre-flight wiring in workflows/super-board-wave.js. No gh
# calls: the script body runs under node with agent/pipeline/log stubbed, and the
# pre-flight agent's verdicts are scripted per card.
#
# The rule: no Ready card reaches runLane('build') without a pre-flight verdict
# that says go. A hold, a sequence-behind, or a missing verdict ends the card's
# chain for this wave and shows up in the summary — never silently dropped.
set -euo pipefail
cd "$(dirname "$0")"

node - ../workflows/super-board-wave.js <<'JS'
const fs = require('fs')
const src = fs.readFileSync(process.argv[2], 'utf8').replace(/^export const meta/m, 'const meta')
const AsyncFunction = (async () => {}).constructor
const run = (args, verdicts) => {
  const labels = []
  const agent = async (prompt, opts) => {
    labels.push(opts.label)
    if (opts.label.startsWith('preflight')) {
      const nums = opts.label.slice('preflight:'.length).split(',').map((s) => Number(s.slice(1)))
      return { verdicts: nums.filter((n) => verdicts[n]).map((n) => ({ number: n, ...verdicts[n] })) }
    }
    if (opts.label.startsWith('classify')) return { kind: 'feature', complexity: 'low' }
    return { status: 'advanced', column: opts.label.startsWith('review') ? 'Done' : 'next', detail: 'ok' }
  }
  const pipeline = async (items, ...stages) => Promise.all(items.map(async (it) => {
    let v = it
    for (const [i, st] of stages.entries()) v = i === 0 ? await st(it) : await st(v, it)
    return v
  }))
  return new AsyncFunction('args', 'agent', 'pipeline', 'log', src)(args, agent, pipeline, () => {})
    .then((out) => ({ out, labels }))
}
const fail = (m) => { console.error('FAIL: ' + m); process.exit(1) }
const card = (number, status = 'Ready') => ({ number, status, title: `t${number}` })
const by = (out, n) => out.cards.find((c) => c.number === n)

;(async () => {
  const { out, labels } = await run({ configPath: 'c.json', variant: 'full',
    cards: [card(1), card(2), card(3), card(4), card(5), card(6, 'Review')] }, {
      1: { verdict: 'proceed', detail: 'clean' },
      2: { verdict: 'hold', column: 'Blocked', detail: 'duplicate of merged PR #31' },
      3: { verdict: 'sequence', column: 'Blocked', detail: 'behind #50 (PR #41 touches login.ts)' },
      4: { verdict: 'sequence', column: 'Ready', detail: 'expected conflict with PR #44 — merge gate rebases' },
      // 5: no verdict at all
    })

  // 1 — proceed builds.
  labels.includes('build:#1') || fail('#1 proceed must build')
  // 2 — hold never builds, and is reported as a pre-flight block in Blocked.
  labels.includes('build:#2') && fail('#2 hold must not build')
  ;(by(out, 2).lastLane === 'preflight' && by(out, 2).finalStatus === 'blocked' && by(out, 2).column === 'Blocked')
    || fail('#2 must be reported preflight:blocked in Blocked: ' + JSON.stringify(by(out, 2)))
  ;/#31/.test(by(out, 2).detail) || fail('#2 detail must name the duplicate')
  // 3 — sequence behind an issue parks the card; 4 — sequence with only a conflict note builds.
  labels.includes('build:#3') && fail('#3 sequenced behind #50 must not build this wave')
  labels.includes('build:#4') || fail('#4 conflict-note sequence must build')
  // 5 — a missing verdict is never built unchecked; it stays Ready for the next wave.
  labels.includes('build:#5') && fail('#5 had no verdict and must not build')
  ;(by(out, 5).finalStatus === 'failed' && by(out, 5).column === 'Ready') || fail('#5 must be failed@Ready: ' + JSON.stringify(by(out, 5)))
  // 6 — cards already past Ready are not pre-flighted.
  labels.some((l) => l.startsWith('preflight') && /#6\b/.test(l)) && fail('#6 in Review must not be pre-flighted')
  labels.includes('review:#6') || fail('#6 review must still run')

  // 7 — batching: 5 Ready cards fit one pre-flight agent.
  labels.filter((l) => l.startsWith('preflight')).length === 1 || fail('5 Ready cards = 1 pre-flight agent, got ' + labels)
  const seven = await run({ configPath: 'c.json', variant: 'full', cards: [1, 2, 3, 4, 5, 6, 7].map((n) => card(n)) },
    Object.fromEntries([1, 2, 3, 4, 5, 6, 7].map((n) => [n, { verdict: 'proceed', detail: 'clean' }])))
  seven.labels.filter((l) => l.startsWith('preflight')).length === 2 || fail('7 Ready cards = 2 pre-flight agents')

  // 8 — qa-only boards have no Builder lane, so no pre-flight runs.
  const qa = await run({ configPath: 'c.json', variant: 'qa-only', cards: [card(1)] }, {})
  qa.labels.some((l) => l.startsWith('preflight')) && fail('qa-only must not pre-flight')
  qa.labels.includes('qa:#1') || fail('qa-only Ready still goes to QA')
})().catch((e) => fail(e.stack))
JS
echo "PASS: test-wave-preflight.sh (8 scenarios)"
