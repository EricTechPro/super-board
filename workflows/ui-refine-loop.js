export const meta = {
  name: 'ui-refine-loop',
  description: 'Check → fix loop on one UI target: each round a fresh design reviewer and a fresh detector (isolated, as Impeccable requires), a fresh checker that ranks typed problems, and a fresh fixer that chains the matching Impeccable commands; a fresh finish reviewer grades every fix at the end',
  whenToUse: 'Launched by the standalone /ui-refine-loop skill after it has read the target code, run the grill, built the worktree, started the dev server and taken round-0 shots. Not for direct ad-hoc use.',
  phases: [
    { title: 'Check', detail: 'design reviewer ‖ detector (isolated), then a checker: ranked, typed P0–P3 problems, visual score /40, before vs now' },
    { title: 'Fix', detail: 'fresh fixer: routes each problem type to an Impeccable command, chains them (polish last), keeps checks green or reverts, one commit, AFTER shots' },
    { title: 'Finish', detail: 'fresh finish reviewer: grades every claimed fix fixed / partial / not-fixed against round-0 vs final shots' },
  ],
}

// args = {
//   slug: 'dashboard-reports',
//   target: '/dashboard/reports',              // what the user named
//   scope: ['app/dashboard/reports/', 'components/reports/'],  // repo-relative paths the fixer may edit
//   prompt: 'the user\'s words verbatim',
//   rounds: 5,                                  // fix rounds; a closing check follows the last
//   worktree: '/abs/…/refine-<slug>',
//   runDir: '/abs/…/refine-<slug>.run',
//   skillDir: '/abs/…/skills/ui-refine-loop',
//   critic: 'impeccable' | 'rubric',            // rubric = loud fallback when Impeccable is missing
//   impeccable: { layout, skillDir, reference, detect, context, version },  // refine-setup.sh detect → .impeccable
//   tasteFile: '/abs/…/docs/design/taste.md',   // the grill's output; default the skill's neutral references/taste.md
//   checks: ['npm run typecheck', 'npm run lint'],        // must stay green; resolved by refine-setup.sh
//   shootCmd: 'node /abs/…/shoot.mjs --base http://localhost:PORT --route /x --out /abs/run/shots --states main',
//   baseUrl: 'http://localhost:PORT',
//   route: '/dashboard/reports',
//   context: 'one-paragraph design context',    // optional: code-area notes + Impeccable context
//   beforeShots: ['/abs/…/round-0-main-desktop-light.png', …],  // full shots and crops
//   extraShots: ['/abs/…/user-1.png'],          // optional
//   priorLedger: ['C1 …'],                      // optional, when resuming
//   warnings: ['Impeccable NOT FOUND …'],       // optional, from detect; echoed into the result
// }
// The harness can deliver `args` as a JSON-encoded string — normalize first.
const input = (() => {
  if (typeof args !== 'string') return args
  try { return JSON.parse(args) } catch { return args }
})()
for (const k of ['slug', 'target', 'scope', 'prompt', 'worktree', 'runDir', 'skillDir', 'checks', 'shootCmd', 'baseUrl', 'route', 'beforeShots']) {
  if (!input || input[k] == null) throw new Error(`ui-refine-loop needs args.${k} — see the header comment`)
}
// Standalone only: the board never runs this. An old `mode` arg other than manual is refused.
if (input.mode != null && input.mode !== 'manual') throw new Error(`ui-refine-loop: mode "${input.mode}" is gone — the loop is standalone (/ui-refine-loop) only`)
const IMP = input.impeccable && typeof input.impeccable === 'object' ? input.impeccable : null
const METHOD = input.critic ?? (IMP ? 'impeccable' : 'rubric')
if (METHOD === 'impeccable' && !(IMP && IMP.detect && IMP.skillDir)) {
  throw new Error('ui-refine-loop: critic "impeccable" needs args.impeccable = { skillDir, detect, … } from refine-setup.sh detect')
}
const ROUNDS = input.rounds ?? 5
const TASTE = input.tasteFile ?? `${input.skillDir}/references/taste.md`
const REF = `${input.skillDir}/references`
const DEGRADED = METHOD === 'rubric' ? 'Impeccable not installed: scored with the built-in rubric, not Impeccable' : null

// Problem type → the Impeccable command that fixes it. The fixer makes the
// final call; this is the default route (references/routing.md).
const ROUTES = {
  cluttered: 'distill',
  bland: 'bolder',
  'too-loud': 'quieter',
  'dull-color': 'colorize',
  'spacing-hierarchy': 'layout',
  typography: 'typeset',
  responsive: 'adapt',
  performance: 'optimize',
  'first-run-empty': 'onboard',
  'confusing-copy': 'clarify',
  'edge-cases': 'harden',
  accessibility: 'harden',
  'needs-motion': 'animate',
  personality: 'delight',
  drift: 'extract',
  polish: 'polish',
}
const TYPES = Object.keys(ROUTES)
const SEV = ['P0', 'P1', 'P2', 'P3']
// Distinct routes in severity order, polish always last.
const chainFor = (problems) => {
  const seen = []
  for (const p of [...problems].sort((a, b) => SEV.indexOf(a.severity) - SEV.indexOf(b.severity))) {
    const c = ROUTES[p.type] ?? 'polish'
    if (c !== 'polish' && !seen.includes(c)) seen.push(c)
  }
  return [...seen, 'polish']
}

const PROBLEM = {
  type: 'object',
  properties: {
    id: { type: 'string', description: 'stable key <area>-<problem>, reused across rounds for the same issue' },
    severity: { type: 'string', enum: SEV },
    type: { type: 'string', enum: TYPES },
    title: { type: 'string' },
    location: { type: 'string', description: 'file:line (repo-relative)' },
    evidence: { type: 'string', description: 'screenshot path + what is visible (theme, viewport, section), or the detector rule' },
    fix: { type: 'string', description: 'what done looks like, inside the existing visual world' },
  },
  required: ['id', 'severity', 'type', 'title', 'location', 'evidence', 'fix'],
}
const DIMS = (names) => ({ type: 'object', properties: Object.fromEntries(names.map((n) => [n, { type: 'number' }])), required: names })

const DESIGN = {
  type: 'object',
  properties: {
    dims: DIMS(['specificity', 'hierarchy', 'typography', 'color', 'composition']),
    designTotal: { type: 'number', description: 'sum of dims, out of 20' },
    problems: { type: 'array', items: PROBLEM },
    strengths: { type: 'array', items: { type: 'string' } },
    openQuestions: { type: 'array', items: { type: 'string' } },
  },
  required: ['dims', 'designTotal', 'problems'],
}
const DETECT = {
  type: 'object',
  properties: {
    dims: DIMS(['accessibility', 'performance', 'responsive', 'theming', 'integrity']),
    auditTotal: { type: 'number', description: 'sum of dims, out of 20' },
    detectorCount: { type: 'number', description: 'verified detector hits (false positives dropped)' },
    detectorRan: { type: 'boolean' },
    problems: { type: 'array', items: PROBLEM },
  },
  required: ['dims', 'auditTotal', 'detectorCount', 'detectorRan', 'problems'],
}
const CHECK = {
  type: 'object',
  properties: {
    problems: { type: 'array', items: PROBLEM, description: 'merged and ranked, P0 first; at most 8' },
    vsBefore: { type: 'string', enum: ['baseline', 'better', 'same', 'worse'], description: 'baseline on the first check' },
    vsBeforeNote: { type: 'string', description: 'one line: what changed against round-0, by section' },
    summary: { type: 'string', description: 'two sentences: overall state and the single biggest remaining problem' },
    openQuestions: { type: 'array', items: { type: 'string' } },
  },
  required: ['problems', 'vsBefore', 'summary'],
}
const FIX = {
  type: 'object',
  properties: {
    status: { type: 'string', enum: ['committed', 'reverted', 'nothing-to-do'] },
    commit: { type: 'string', description: 'short sha, or empty' },
    commands: { type: 'array', items: { type: 'string' }, description: 'Impeccable commands run, in order (polish last)' },
    fixed: { type: 'array', items: { type: 'string' }, description: 'problem ids fixed' },
    skipped: { type: 'array', items: { type: 'object', properties: { id: { type: 'string' }, reason: { type: 'string' } }, required: ['id', 'reason'] } },
    outOfScope: { type: 'array', items: { type: 'object', properties: { file: { type: 'string' }, why: { type: 'string' } }, required: ['file', 'why'] } },
    checks: { type: 'string', description: 'check command results, one line' },
    afterShots: { type: 'array', items: { type: 'string' }, description: 'every path the screenshot command printed' },
    openQuestions: { type: 'array', items: { type: 'string' } },
  },
  required: ['status', 'commit', 'commands', 'fixed', 'skipped', 'outOfScope', 'checks', 'afterShots'],
}
const FINISH = {
  type: 'object',
  properties: {
    grades: {
      type: 'array',
      items: { type: 'object', properties: { id: { type: 'string' }, grade: { type: 'string', enum: ['fixed', 'partial', 'not-fixed'] }, evidence: { type: 'string' } }, required: ['id', 'grade', 'evidence'] },
    },
    regressions: { type: 'array', items: { type: 'string' }, description: 'at most 3, introduced by the fixes' },
    disposition: { type: 'string', description: 'one line: ready for review, or what stays open' },
  },
  required: ['grades', 'regressions', 'disposition'],
}

const method = METHOD === 'impeccable'
  ? `Method: impeccable v${IMP.version ?? '?'} (${IMP.layout} layout). Skill folder: ${IMP.skillDir}. Playbooks: ${IMP.reference ?? IMP.skillDir + '/reference'}/. Detector: \`${IMP.detect} <paths>\`.`
  : `Method: rubric. ${DEGRADED}. Use ${REF}/rubric.md in place of Impeccable's playbooks and detector.`

const common = () => [
  `Target: ${input.target} (route ${input.route} at ${input.baseUrl}).`,
  `Scope (repo-relative): ${input.scope.join(', ')}.`,
  `Worktree: ${input.worktree} — run every command there and edit files only under that path. The main checkout is another session's; never touch it.`,
  `Run dir (shots, auth, logs): ${input.runDir}.`,
  method,
  `Taste and direction file (read first; cite its ids): ${TASTE}.`,
  `Design context: ${input.context ?? 'no PRODUCT.md / DESIGN.md; the incumbent implementation is the design authority.'}`,
  `The brief, verbatim: """${input.prompt}"""`,
].join('\n')

const isSheet = (f) => /(^|\/)cmp-[^/]*\.png$/.test(f)
const isCrop = (f) => /-s\d+\.png$/.test(f)
const shotBlock = (current, n) => {
  const before = input.beforeShots
  const lines = [
    `Round-0 (before) shots: ${before.filter((f) => !isCrop(f)).join(', ')}`,
    `Round-0 section crops: ${before.filter(isCrop).join(', ') || '(none)'}`,
  ]
  if (current !== before) {
    lines.push(
      `Current shots (light and dark, desktop 1440 and mobile 390): ${current.filter((f) => !isSheet(f) && !isCrop(f)).join(', ')}`,
      `Current section crops: ${current.filter(isCrop).join(', ') || '(none)'}`,
      `Before | after sheets (read these first): ${current.filter(isSheet).join(', ') || '(none — compare the pairs above)'}`,
    )
  } else {
    lines.push(`Check ${n} is on the untouched surface: current = round-0.`)
  }
  if (input.extraShots?.length) lines.push(`The user's screenshots: ${input.extraShots.join(', ')}`)
  return lines.join('\n')
}
const ledgerText = (ledger) => (ledger.length ? ledger.join('\n') : '(first check — no ledger yet)')
const counts = (ps) => SEV.map((s) => `${s}×${ps.filter((p) => p.severity === s).length}`).join(' ')

const ledger = [...(input.priorLedger ?? [])]
const rounds = []
const claims = [] // problems a fixer said it fixed, for the finish review
const openQuestions = []
let shots = input.beforeShots
let finalLabel = 'round-0'
let cleanStreak = 0
let fixFails = 0
let stopReason = `ran all ${ROUNDS} rounds`

// Check n runs on the state left by fix n-1; check ROUNDS+1 is the closing
// check that scores the final state. Fix rounds never exceed ROUNDS.
for (let n = 1; n <= ROUNDS + 1; n++) {
  phase('Check')
  const shotsNow = shotBlock(shots, n)
  // Assessment A and B in isolated contexts, in parallel: neither sees the other.
  const [design, detect] = await Promise.all([
    agent(
      [`You are the check-${n} design reviewer. Read ${REF}/checker-brief.md, section "Design reviewer", and follow it exactly.`, common(), shotsNow, `Extra states only (a dialog open, a tab switched): \`${input.shootCmd} --label review-r${n} --sections none\``].join('\n\n'),
      { phase: 'Check', label: `design r${n}`, schema: DESIGN },
    ),
    agent(
      [`You are the check-${n} detector. Read ${REF}/checker-brief.md, section "Detector", and follow it exactly.`, common()].join('\n\n'),
      { phase: 'Check', label: `detector r${n}`, schema: DETECT },
    ),
  ])
  if (!design) { stopReason = `design reviewer r${n} died`; break }
  if (!detect) { stopReason = `detector r${n} died`; break }

  const checker = await agent(
    [
      `You are the check-${n} checker. Read ${REF}/checker-brief.md, section "Checker", and follow it exactly.`,
      common(),
      shotsNow,
      `Design review (assessment A):\n${JSON.stringify(design, null, 2)}`,
      `Detector and audit (assessment B):\n${JSON.stringify(detect, null, 2)}`,
      `Ledger of earlier checks:\n${ledgerText(ledger)}`,
    ].join('\n\n'),
    { phase: 'Check', label: `check r${n}`, schema: CHECK },
  )
  if (!checker) { stopReason = `checker r${n} died`; break }
  openQuestions.push(...(design.openQuestions ?? []), ...(checker.openQuestions ?? []))

  const problems = checker.problems.slice(0, 8)
  const visual = Math.round((design.designTotal + detect.auditTotal) * 10) / 10
  const blocking = problems.filter((p) => p.severity === 'P0' || p.severity === 'P1')
  const vsBefore = n === 1 ? 'baseline' : checker.vsBefore
  const round = { n, visual, design: design.designTotal, audit: detect.auditTotal, detectorCount: detect.detectorCount, detectorRan: detect.detectorRan, vsBefore, vsBeforeNote: checker.vsBeforeNote ?? '', counts: counts(problems), problems, summary: checker.summary }
  rounds.push(round)
  const head = `C${n} · visual ${visual}/40 (design ${design.designTotal}/20 · audit ${detect.auditTotal}/20 · detector ${detect.detectorCount}) · ${vsBefore}`

  cleanStreak = blocking.length === 0 ? cleanStreak + 1 : 0
  if (cleanStreak >= 2) {
    ledger.push(`${head} · clean (2nd in a row) · ${round.counts}`)
    stopReason = 'two consecutive checks found no P0/P1'
    break
  }
  if (n === ROUNDS + 1) {
    ledger.push(`${head} · closing check · ${round.counts}`)
    break
  }
  if (problems.length === 0) {
    ledger.push(`${head} · clean, nothing to fix; next check confirms`)
    continue
  }

  phase('Fix')
  const plan = chainFor(problems)
  const routed = problems.map((p) => ({ ...p, route: ROUTES[p.type] ?? 'polish' }))
  // writing-standard.md § 1: `💄 [ui] <scope>: <subject>`; the fixer adds the bullets.
  const commitMsg = `💄 [ui] ${input.slug}: round ${n} — <what changed>`
  const fixer = await agent(
    [
      `You are the round-${n} fixer. Read ${REF}/fixer-brief.md and ${REF}/routing.md, and follow them exactly.`,
      common(),
      `Checks that must stay green: ${input.checks.length ? input.checks.join(' && ') : '(none detected — say so in checks)'}.`,
      `Commit message: "${commitMsg}".`,
      `AFTER shots: \`${input.shootCmd} --label round-${n} --compare round-0\` — return every path it prints.`,
      `Suggested chain (routing.md defaults; you choose the final chain, polish always last): ${plan.join(' → ')}`,
      `Problems from check ${n}, ranked, each with its default route (fix P0 → P1 → P2; P3 only in files you already touch):\n${JSON.stringify(routed, null, 2)}`,
    ].join('\n\n'),
    { phase: 'Fix', label: `fixer r${n}`, schema: FIX },
  )
  if (!fixer) { stopReason = `fixer r${n} died`; break }
  openQuestions.push(...(fixer.openQuestions ?? []))
  round.fix = fixer

  const oos = fixer.outOfScope.length ? ` · out-of-scope: ${fixer.outOfScope.map((o) => `${o.file} (${o.why})`).join('; ')}` : ''
  ledger.push(
    `${head} · ${round.counts} · ${fixer.status} ${fixer.commit || ''} [${fixer.commands.join(' → ')}]` +
      `\n  fixed: ${fixer.fixed.join(', ') || '—'} · skipped: ${fixer.skipped.map((s) => s.id).join(', ') || '—'}${oos}`,
  )
  log(ledger[ledger.length - 1].split('\n')[0])

  if (fixer.status === 'reverted') {
    fixFails++
    if (fixFails >= 2) { stopReason = 'two fix rounds in a row went red and were reverted'; break }
    continue
  }
  fixFails = 0
  if (fixer.status === 'committed') {
    for (const id of fixer.fixed) {
      const p = problems.find((x) => x.id === id)
      if (p) { const i = claims.findIndex((c) => c.id === id); if (i >= 0) claims.splice(i, 1); claims.push({ ...p, round: n }) }
    }
    if (fixer.afterShots.length) { shots = fixer.afterShots; finalLabel = `round-${n}` }
  }
}

// Finish review: a fresh context grades every claimed fix against the pixels.
let finish = null
if (claims.length && finalLabel !== 'round-0') {
  phase('Finish')
  finish = await agent(
    [
      `You are the finish reviewer. Read ${REF}/finish-reviewer-brief.md and follow it exactly.`,
      common(),
      shotBlock(shots, 'final'),
      `Claimed fixes to grade (one grade each):\n${JSON.stringify(claims, null, 2)}`,
    ].join('\n\n'),
    { phase: 'Finish', label: 'finish', schema: FINISH },
  )
}

const first = rounds[0]
const last = rounds[rounds.length - 1]
const scoreLine = rounds.map((r) => `C${r.n} ${r.visual}/40${r.n > 1 ? ` (${r.vsBefore})` : ''}`).join(' → ')
return {
  method: METHOD,
  degraded: DEGRADED,
  warnings: input.warnings ?? [],
  stopReason,
  scoreLine,
  before: first ? first.visual : null,
  after: last ? last.visual : null,
  ledger,
  rounds,
  finalLabel,
  finalShots: shots,
  grades: finish ? finish.grades : [],
  regressions: finish ? finish.regressions : [],
  disposition: finish ? finish.disposition : claims.length ? 'finish reviewer died — fixes ungraded' : 'no fixes landed',
  openQuestions,
}
