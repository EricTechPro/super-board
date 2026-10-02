#!/usr/bin/env bash
# Tests workflows/super-refine.js: it compiles as a workflow body, and its stop
# rules fire on the right round. agent/phase/log are stubbed; no browser, no git.
#
# The script is a workflow body (top-level await + return), not a module, so
# plain `node --check` rejects it. This test is also its syntax check.
set -euo pipefail
cd "$(dirname "$0")"

node - ../workflows/super-refine.js <<'JS'
const fs = require('fs')
const src = fs.readFileSync(process.argv[2], 'utf8').replace(/^export const meta/m, 'const meta')
const AsyncFunction = (async () => {}).constructor
// critics: array of critic replies by round (index 0 = r1); refiner: (n) => reply
const run = (args, critics, refiner) => {
  const calls = []
  const agent = async (prompt, opts) => {
    calls.push({ label: opts.label, prompt })
    const n = Number(opts.label.match(/r(\d+)$/)[1])
    if (opts.label.startsWith('critic')) return critics[n - 1] === undefined ? critics[critics.length - 1] : critics[n - 1]
    return refiner(n)
  }
  return new AsyncFunction('args', 'agent', 'phase', 'log', src)(args, agent, () => {}, () => {})
    .then((out) => ({ out, calls, labels: calls.map((c) => c.label) }))
}
const fail = (m) => { console.error('FAIL: ' + m); process.exit(1) }
const eq = (a, b, m) => { if (JSON.stringify(a) !== JSON.stringify(b)) fail(`${m}: expected ${JSON.stringify(b)}, got ${JSON.stringify(a)}`) }

const base = {
  slug: 'reports', target: '/reports', scope: ['src/reports/'], prompt: 'calmer', worktree: '/wt', runDir: '/wt.run',
  skillDir: '/skill', checks: ['npm run typecheck'], shootCmd: 'node shoot.mjs --base http://localhost:1 --route /reports',
  baseUrl: 'http://localhost:1', route: '/reports', beforeShots: ['/wt.run/shots/round-0-main-desktop.png'],
  impeccable: '/imp/scripts/impeccable', rounds: 10,
}
const f = (severity, id = `x-${severity}`) => ({ id, severity, title: id, location: 'a.tsx:1', evidence: 'e', fix: 'f', verb: 'polish' })
const critic = (verdict, total, findings = [], extra = {}) => ({ verdict, heuristicsTotal: total, heuristicsMax: 40, detectorCount: 0, findings, summary: 's', ...extra })
const committed = (n) => ({ status: 'committed', commit: `c${n}`, verbs: ['polish'], fixed: [], skipped: [], outOfScope: [], checks: 'green', afterShots: [`/wt.run/shots/round-${n}-main-desktop.png`] })
const reverted = () => ({ status: 'reverted', commit: '', verbs: [], fixed: [], skipped: [], outOfScope: [], checks: 'tsc red', afterShots: [] })

;(async () => {
  let r

  // 1 — two clean DONEs in a row stop the loop; no refiner runs; the confirming round audits.
  r = await run(base, [critic('DONE', 30, [f('P2')]), critic('DONE', 30)], committed)
  eq(r.out.stopReason, 'two consecutive clean DONE verdicts', 'clean DONE stop')
  eq(r.labels, ['critic r1', 'critic r2'], 'no refiner on clean DONE')
  r.calls[1].prompt.includes('Audit: RUN') || fail('round after a clean DONE must run the audit')

  // 2 — DONE with a P1 is not clean: the refiner still runs and the streak does not start.
  r = await run({ ...base, rounds: 2 }, [critic('DONE', 20, [f('P1')]), critic('DONE', 22, [f('P1')])], committed)
  eq(r.labels, ['critic r1', 'refiner r1', 'critic r2', 'refiner r2'], 'DONE+P1 refines')
  eq(r.out.stopReason, 'ran all 2 rounds', 'DONE+P1 never stops early')

  // 3 — score plateau: best never beaten for 3 rounds → stop on round 4, before its refiner.
  r = await run(base, [critic('CONTINUE', 24, [f('P1')]), critic('CONTINUE', 24, [f('P1')]), critic('CONTINUE', 23, [f('P1')]), critic('CONTINUE', 24, [f('P1')])], committed)
  eq(r.out.stopReason, 'score plateaued at 24/40 for 3 rounds', 'plateau stop')
  eq(r.labels.at(-1), 'critic r4', 'plateau stops before refining round 4')

  // 4 — two reverts in a row stop; a commit in between resets the count.
  r = await run(base, [critic('CONTINUE', 20, [f('P0')]), critic('CONTINUE', 21, [f('P0')]), critic('CONTINUE', 22, [f('P0')]), critic('CONTINUE', 23, [f('P0')])],
    (n) => (n === 2 ? committed(n) : reverted()))
  eq(r.out.stopReason, 'two refiner rounds in a row went red and were reverted', 'revert stop')
  eq(r.labels.at(-1), 'refiner r4', 'reverts r3+r4 stop after r4 (r1 revert was reset by r2 commit)')

  // 5 — N rounds; audit on r1, every 3rd, and the last; score line and AFTER shots carry forward.
  r = await run({ ...base, rounds: 4 }, [20, 22, 24, 26].map((s) => critic('CONTINUE', s, [f('P1')])), committed)
  eq(r.out.stopReason, 'ran all 4 rounds', 'round cap')
  const audits = r.calls.filter((c) => c.label.startsWith('critic')).map((c) => c.prompt.includes('Audit: RUN'))
  eq(audits, [true, false, true, true], 'audit schedule')
  eq(r.out.scoreLine, 'R1 20 → R2 22 → R3 24 → R4 26', 'score line')
  r.calls[2].prompt.includes('round-1-main-desktop.png') || fail('round 2 critic must see round 1 AFTER shots')
  eq(r.out.ledger.length, 4, 'one ledger entry per round')
  ;/^R1 · 20\/40 · audit –\/20 \(carried\) · committed c1/.test(r.out.ledger[0]) || fail(`ledger line shape: ${r.out.ledger[0]}`)

  // 6 — heuristics normalised to /40 when some were n/a.
  r = await run({ ...base, rounds: 1 }, [critic('CONTINUE', 18, [f('P1')], { heuristicsMax: 32 })], committed)
  eq(r.out.rounds[0].score, 22.5, 'normalised score')

  // 7 — a dead sub-agent stops the loop with its name.
  r = await run(base, [null], committed)
  eq(r.out.stopReason, 'critic r1 died', 'dead critic')
  r = await run(base, [critic('CONTINUE', 20, [f('P0')])], () => null)
  eq(r.out.stopReason, 'refiner r1 died', 'dead refiner')

  // 8 — qa-hook defaults to 3 rounds, commits as refine(#N), stays on the issue branch.
  const { rounds: _drop, ...noRounds } = base
  r = await run({ ...noRounds, mode: 'qa-hook', issue: 42 }, [20, 21, 22, 23].map((s) => critic('CONTINUE', s, [f('P1')])), committed)
  eq(r.out.stopReason, 'ran all 3 rounds', 'qa-hook round default')
  r.calls[1].prompt.includes('refine(#42) round 1') || fail('qa-hook commit message must name the issue')
  r.calls[1].prompt.includes('issue #42') || fail('qa-hook prompt must name the issue branch')
  eq(r.out.mode, 'qa-hook', 'mode echoed')

  // 9 — no Impeccable → built-in rubric; taste file defaults to the skill's.
  const { impeccable: _i, ...noImp } = base
  r = await run({ ...noImp, rounds: 1 }, [critic('CONTINUE', 20, [f('P1')])], committed)
  r.calls[0].prompt.includes('/skill/references/rubric.md') || fail('rubric fallback must point at rubric.md')
  r.calls[0].prompt.includes('/skill/references/taste.md') || fail('default taste file')
  try { await run({ ...base, critic: 'impeccable', impeccable: undefined }, [], committed); fail('impeccable without launcher must throw') } catch (e) { if (!/needs args.impeccable/.test(e.message)) throw e }

  // 10 — args validation, and JSON-string args are accepted.
  try { await run({ ...base, shootCmd: undefined }, [], committed); fail('missing shootCmd must throw') } catch (e) { if (!/args.shootCmd/.test(e.message)) throw e }
  try { await run({ ...base, mode: 'auto' }, [], committed); fail('bad mode must throw') } catch (e) { if (!/unknown mode/.test(e.message)) throw e }
  r = await run(JSON.stringify({ ...base, rounds: 1 }), [critic('DONE', 30)], committed)
  eq(r.out.stopReason, 'ran all 1 rounds', 'string args')
})().catch((e) => fail(e.stack))
JS
echo "PASS: test-refine-workflow.sh (10 scenarios)"
