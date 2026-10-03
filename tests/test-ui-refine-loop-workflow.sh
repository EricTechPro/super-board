#!/usr/bin/env bash
# Tests workflows/ui-refine-loop.js: it compiles as a workflow body, its stop
# rules fire on the right check, problem types route to the right Impeccable
# command (polish last), design review and detector stay isolated, and the
# finish reviewer grades the claimed fixes. agent/phase/log are stubbed.
#
# The script is a workflow body (top-level await + return), not a module, so
# plain `node --check` rejects it. This test is also its syntax check.
set -euo pipefail
cd "$(dirname "$0")"

node - ../workflows/ui-refine-loop.js <<'JS'
const fs = require('fs')
const src = fs.readFileSync(process.argv[2], 'utf8').replace(/^export const meta/m, 'const meta')
const AsyncFunction = (async () => {}).constructor
// checks: array of checker replies by check (index 0 = check 1; the last repeats).
// fixer: (n) => reply. design/detect: (n) => reply (defaults below).
const run = (args, checks, fixer, { design, detect, finish } = {}) => {
  const calls = []
  const agent = async (prompt, opts) => {
    calls.push({ label: opts.label, prompt })
    if (opts.label === 'finish') return finish === undefined ? { grades: [{ id: 'x', grade: 'fixed', evidence: 'e' }], regressions: [], disposition: 'ready for review' } : finish
    const n = Number(opts.label.match(/r(\d+)$/)[1])
    if (opts.label.startsWith('design')) return design ? design(n) : { dims: {}, designTotal: 10 + n, problems: [] }
    if (opts.label.startsWith('detector')) return detect ? detect(n) : { dims: {}, auditTotal: 10, detectorCount: 3, detectorRan: true, problems: [] }
    if (opts.label.startsWith('check')) return checks[n - 1] === undefined ? checks[checks.length - 1] : checks[n - 1]
    return fixer(n)
  }
  return new AsyncFunction('args', 'agent', 'phase', 'log', src)(args, agent, () => {}, () => {})
    .then((out) => ({ out, calls, labels: calls.map((c) => c.label) }))
}
const fail = (m) => { console.error('FAIL: ' + m); process.exit(1) }
const eq = (a, b, m) => { if (JSON.stringify(a) !== JSON.stringify(b)) fail(`${m}: expected ${JSON.stringify(b)}, got ${JSON.stringify(a)}`) }
const has = (s, sub, m) => { if (!s.includes(sub)) fail(`${m}: missing ${JSON.stringify(sub)}`) }

const IMP = { layout: 'node', skillDir: '/imp', reference: '/imp/reference', detect: 'node /imp/scripts/detect.mjs --json', context: 'node /imp/scripts/context.mjs', version: '4.0.4' }
const base = {
  slug: 'reports', target: '/reports', scope: ['src/reports/'], prompt: 'calmer', worktree: '/wt', runDir: '/wt.run',
  skillDir: '/skill', checks: ['npm run typecheck'], shootCmd: 'node shoot.mjs --base http://localhost:1 --route /reports',
  baseUrl: 'http://localhost:1', route: '/reports',
  beforeShots: ['/wt.run/shots/round-0-main-desktop-light.png', '/wt.run/shots/round-0-main-desktop-dark.png', '/wt.run/shots/round-0-main-desktop-light-s1.png'],
  impeccable: IMP,
}
const p = (severity, type = 'polish', id = `${type}-${severity}`) => ({ id, severity, type, title: id, location: 'a.tsx:1', evidence: 'e', fix: 'f' })
const check = (problems = [], extra = {}) => ({ problems, vsBefore: 'better', summary: 's', ...extra })
const committed = (fixed = []) => (n) => ({
  status: 'committed', commit: `c${n}`, commands: ['layout', 'polish'], fixed, skipped: [], outOfScope: [], checks: 'green',
  afterShots: [`/wt.run/shots/round-${n}-main-desktop-light.png`, `/wt.run/shots/round-${n}-main-desktop-light-s1.png`, `/wt.run/shots/cmp-round-${n}-main-desktop-light.png`],
})
const reverted = () => ({ status: 'reverted', commit: '', commands: [], fixed: [], skipped: [], outOfScope: [], checks: 'tsc red', afterShots: [] })
const checkLabels = (r) => r.labels.filter((l) => l.startsWith('check '))

;(async () => {
  let r

  // 1 — default is 5 fix rounds, then a closing check scores the final state.
  r = await run(base, [check([p('P1', 'cluttered')])], committed())
  eq(r.out.stopReason, 'ran all 5 rounds', '5-round default')
  eq(r.labels.filter((l) => l.startsWith('fixer')).length, 5, 'five fixers')
  eq(checkLabels(r).length, 6, 'five checks + a closing check')
  eq(r.labels.slice(0, 4), ['design r1', 'detector r1', 'check r1', 'fixer r1'], 'round order')
  eq(r.out.finalLabel, 'round-5', 'final label is the last committed round')

  // 2 — two consecutive checks with no P0/P1 stop early (P2s still get a fixer once).
  r = await run(base, [check([p('P1', 'too-loud')]), check([p('P2', 'typography')]), check([p('P3')])], committed())
  eq(r.out.stopReason, 'two consecutive checks found no P0/P1', 'clean-streak stop')
  eq(r.labels.filter((l) => l.startsWith('fixer')), ['fixer r1', 'fixer r2'], 'fixer runs on P2 before the confirming check')
  eq(checkLabels(r).length, 3, 'stops at check 3')

  // 3 — a P1 breaks the streak.
  r = await run({ ...base, rounds: 3 }, [check([p('P2')]), check([p('P1')]), check([p('P2')]), check([p('P1')])], committed())
  eq(r.out.stopReason, 'ran all 3 rounds', 'P1 resets the clean streak')

  // 4 — a clean check with zero problems skips the fixer; the next clean check stops.
  r = await run(base, [check([])], committed())
  eq(r.labels.filter((l) => l.startsWith('fixer')).length, 0, 'nothing to fix → no fixer')
  eq(r.out.stopReason, 'two consecutive checks found no P0/P1', 'two empty checks stop')
  eq(r.out.disposition, 'no fixes landed', 'no finish review without fixes')
  eq(r.labels.includes('finish'), false, 'finish reviewer skipped')

  // 5 — two reverts in a row stop; a commit in between resets the count.
  r = await run(base, [check([p('P0', 'responsive')])], (n) => (n === 2 ? committed()(n) : reverted()))
  eq(r.out.stopReason, 'two fix rounds in a row went red and were reverted', 'revert stop')
  eq(r.labels.at(-1), 'fixer r4', 'r3+r4 reverts stop after r4 (r1 was reset by r2)')

  // 6 — dead agents stop with their role.
  r = await run(base, [check([p('P1')])], committed(), { design: () => null })
  eq(r.out.stopReason, 'design reviewer r1 died', 'dead design reviewer')
  r = await run(base, [check([p('P1')])], committed(), { detect: () => null })
  eq(r.out.stopReason, 'detector r1 died', 'dead detector')
  r = await run(base, [null], committed())
  eq(r.out.stopReason, 'checker r1 died', 'dead checker')
  r = await run(base, [check([p('P1')])], () => null)
  eq(r.out.stopReason, 'fixer r1 died', 'dead fixer')

  // 7 — routing: each type gets its command; the chain is severity-ordered, deduped, polish last.
  const routes = { cluttered: 'distill', bland: 'bolder', 'too-loud': 'quieter', 'dull-color': 'colorize', 'spacing-hierarchy': 'layout',
    typography: 'typeset', responsive: 'adapt', performance: 'optimize', 'first-run-empty': 'onboard', 'confusing-copy': 'clarify',
    'edge-cases': 'harden', accessibility: 'harden', 'needs-motion': 'animate', personality: 'delight', drift: 'extract', polish: 'polish' }
  const all = Object.keys(routes).map((t) => p('P2', t))
  r = await run({ ...base, rounds: 1 }, [check(all), check([])], committed())
  const fx = r.calls.find((c) => c.label === 'fixer r1').prompt
  const routed = JSON.parse(fx.slice(fx.indexOf('[', fx.indexOf('Problems from check'))))
  for (const q of routed) eq(q.route, routes[q.type], `route for ${q.type}`)
  r = await run({ ...base, rounds: 1 }, [check([p('P3', 'polish'), p('P2', 'typography'), p('P0', 'cluttered'), p('P1', 'spacing-hierarchy'), p('P2', 'cluttered', 'dup')]), check([])], committed())
  has(r.calls.find((c) => c.label === 'fixer r1').prompt, 'Suggested chain (routing.md defaults; you choose the final chain, polish always last): distill → layout → typeset → polish', 'chain order')
  has(r.calls.find((c) => c.label === 'fixer r1').prompt, '/skill/references/routing.md', 'fixer reads routing.md')

  // 8 — isolation: the detector never gets screenshots; the design reviewer never gets detector output.
  r = await run({ ...base, rounds: 1 }, [check([p('P1')]), check([])], committed())
  const det = r.calls.find((c) => c.label === 'detector r1').prompt
  const des = r.calls.find((c) => c.label === 'design r1').prompt
  if (/\.png/.test(det)) fail('detector prompt must not carry screenshots')
  if (/auditTotal|detectorCount/.test(des)) fail('design reviewer must not see detector output')
  has(det, 'node /imp/scripts/detect.mjs --json', 'detector gets the detect command')
  has(r.calls.find((c) => c.label === 'check r1').prompt, '"auditTotal": 10', 'checker gets assessment B')

  // 9 — shots: check 1 sees round-0 only; check 2 sees round-0 + current, crops and before|after sheets.
  const c1 = r.calls.find((c) => c.label === 'design r1').prompt
  has(c1, 'current = round-0', 'first check on the untouched surface')
  has(c1, 'round-0-main-desktop-dark.png', 'round-0 dark shot')
  has(c1, 'Round-0 section crops: /wt.run/shots/round-0-main-desktop-light-s1.png', 'round-0 crops')
  const c2 = r.calls.find((c) => c.label === 'design r2').prompt
  has(c2, 'Round-0 (before) shots: /wt.run/shots/round-0-main-desktop-light.png', 'before shots every round')
  has(c2, 'Current shots (light and dark, desktop 1440 and mobile 390): /wt.run/shots/round-1-main-desktop-light.png', 'current shots')
  has(c2, 'Current section crops: /wt.run/shots/round-1-main-desktop-light-s1.png', 'current crops')
  has(c2, 'Before | after sheets (read these first): /wt.run/shots/cmp-round-1-main-desktop-light.png', 'compare sheets')
  has(r.calls.find((c) => c.label === 'fixer r1').prompt, '--label round-1 --compare round-0', 'fixer shoots with compare')

  // 10 — score: design /20 + audit /20, before → after, vsBefore; no Nielsen.
  r = await run({ ...base, rounds: 2 }, [check([p('P1')]), check([p('P1')], { vsBefore: 'worse' }), check([p('P1')])], committed())
  eq(r.out.scoreLine, 'C1 21/40 → C2 22/40 (worse) → C3 23/40 (better)', 'score line')
  eq([r.out.before, r.out.after], [21, 23], 'before → after')
  eq(r.out.rounds[0].vsBefore, 'baseline', 'first check is the baseline')
  if (/heuristic|Nielsen|\/40 ·.*heur/i.test(JSON.stringify(r.out))) fail('no Nielsen scoring in the result')
  ;/^C1 · visual 21\/40 \(design 11\/20 · audit 10\/20 · detector 3\) · baseline · P0×0 P1×1 P2×0 P3×0 · committed c1 \[layout → polish\]/.test(r.out.ledger[0]) || fail(`ledger line shape: ${r.out.ledger[0]}`)

  // 11 — finish reviewer grades every claimed fix, once, after the loop.
  r = await run({ ...base, rounds: 2 }, [check([p('P1', 'cluttered', 'a'), p('P2', 'typography', 'b')]), check([p('P1', 'cluttered', 'a')]), check([])], committed(['a', 'b']),
    { finish: { grades: [{ id: 'a', grade: 'partial', evidence: 'e' }, { id: 'b', grade: 'fixed', evidence: 'e' }], regressions: ['dark footer'], disposition: 'a stays open' } })
  eq(r.labels.at(-1), 'finish', 'finish runs last')
  const claims = JSON.parse(r.calls.at(-1).prompt.slice(r.calls.at(-1).prompt.indexOf('[', r.calls.at(-1).prompt.indexOf('Claimed fixes'))))
  eq(claims.map((c) => [c.id, c.round]), [['b', 1], ['a', 2]], 'claims deduped, latest round wins')
  has(r.calls.at(-1).prompt, '/skill/references/finish-reviewer-brief.md', 'finish brief')
  eq(r.out.grades.map((g) => g.grade), ['partial', 'fixed'], 'grades returned')
  eq(r.out.regressions, ['dark footer'], 'regressions returned')

  // 12 — standalone only: an old qa-hook mode is refused; commits are refine(<slug>).
  try { await run({ ...base, mode: 'qa-hook', issue: 42 }, [], committed()); fail('qa-hook mode must throw') } catch (e) { if (!/standalone/.test(e.message)) throw e }
  r = await run({ ...base, rounds: 1 }, [check([p('P1')]), check([])], committed())
  has(r.calls.find((c) => c.label === 'fixer r1').prompt, 'refine(reports) round 1', 'commit message names the slug')
  if (/issue #|QA lane/.test(r.calls.find((c) => c.label === 'fixer r1').prompt)) fail('no board/QA wording in prompts')

  // 13 — no Impeccable → rubric, flagged degraded; neutral taste default; impeccable without detect throws.
  const { impeccable: _i, ...noImp } = base
  r = await run({ ...noImp, rounds: 1, warnings: ['Impeccable NOT FOUND'] }, [check([p('P1')]), check([])], committed())
  has(r.calls[0].prompt, '/skill/references/rubric.md', 'rubric fallback')
  has(r.calls[0].prompt, '/skill/references/taste.md', 'default taste file')
  eq(r.out.method, 'rubric', 'method echoed')
  if (!r.out.degraded) fail('rubric run must be flagged degraded')
  eq(r.out.warnings, ['Impeccable NOT FOUND'], 'warnings echoed')
  r = await run({ ...base, rounds: 1 }, [check([])], committed())
  eq(r.out.degraded, null, 'impeccable run not degraded')
  has(r.calls[0].prompt, 'impeccable v4.0.4 (node layout)', 'impeccable layout in prompt')
  try { await run({ ...base, critic: 'impeccable', impeccable: '/imp/scripts/impeccable' }, [], committed()); fail('a bare impeccable string must throw') } catch (e) { if (!/needs args.impeccable/.test(e.message)) throw e }

  // 14 — args validation, and JSON-string args are accepted.
  try { await run({ ...base, shootCmd: undefined }, [], committed()); fail('missing shootCmd must throw') } catch (e) { if (!/args.shootCmd/.test(e.message)) throw e }
  r = await run(JSON.stringify({ ...base, rounds: 1 }), [check([])], committed())
  eq(r.out.stopReason, 'two consecutive checks found no P0/P1', 'string args')
})().catch((e) => fail(e.stack))
JS
echo "PASS: test-ui-refine-loop-workflow.sh (14 scenarios)"
