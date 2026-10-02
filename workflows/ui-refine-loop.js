export const meta = {
  name: 'ui-refine-loop',
  description: 'Critique → refine loop on one UI target: a fresh critic and a fresh refiner each round, a two-line ledger between them',
  whenToUse: 'Launched by the ui-refine-loop skill (manual or qa-hook mode) after it has built the worktree, started the dev server and taken BEFORE shots. Not for direct ad-hoc use.',
  phases: [
    { title: 'Critique', detail: 'fresh critic: Impeccable critique/detect/audit (or the built-in rubric), ranked P0–P3, DONE/CONTINUE' },
    { title: 'Refine', detail: 'fresh refiner: fixes the findings, keeps checks green or reverts, one commit, AFTER shots' },
  ],
}

// args = {
//   mode: 'manual' | 'qa-hook',                // qa-hook: runs on the issue branch inside the QA lane
//   slug: 'dashboard-reports',
//   target: '/dashboard/reports',              // what the user named
//   scope: ['app/dashboard/reports/', 'components/reports/'],  // repo-relative paths the refiner may edit
//   prompt: 'what is wrong / what we want',     // the user's words verbatim, or the issue's UI ACs in qa-hook mode
//   rounds: 10,                                 // qa-hook default 3
//   worktree: '/abs/…/refine-<slug>',           // qa-hook: the QA lane's worktree
//   runDir: '/abs/…/refine-<slug>.run',
//   skillDir: '/abs/…/skills/ui-refine-loop',
//   critic: 'impeccable' | 'rubric',            // rubric = built-in fallback when Impeccable is not installed
//   impeccable: '/abs/…/impeccable/scripts/impeccable',   // required when critic = impeccable
//   tasteFile: '/abs/…/taste.md',               // project taste file, or the skill's references/taste.md
//   checks: ['npm run typecheck', 'npm run lint'],        // must stay green; resolved by refine-setup.sh
//   shootCmd: 'node /abs/…/shoot.mjs --base http://localhost:PORT --route /x --out /abs/run/shots --states main,empty',
//   baseUrl: 'http://localhost:PORT',
//   route: '/dashboard/reports',
//   context: 'one-paragraph design context',    // optional
//   beforeShots: ['/abs/…/round-0-main-desktop.png', …],
//   extraShots: ['/abs/…/user-1.png'],          // optional
//   priorLedger: ['R1 …'],                      // optional, when resuming
//   issue: 42,                                  // qa-hook only
// }
// The harness can deliver `args` as a JSON-encoded string — normalize first.
const input = (() => {
  if (typeof args !== 'string') return args
  try { return JSON.parse(args) } catch { return args }
})()
for (const k of ['slug', 'target', 'scope', 'prompt', 'worktree', 'runDir', 'skillDir', 'checks', 'shootCmd', 'baseUrl', 'route', 'beforeShots']) {
  if (!input || input[k] == null) throw new Error(`ui-refine-loop needs args.${k} — see the header comment`)
}
const MODE = input.mode ?? 'manual'
if (!['manual', 'qa-hook'].includes(MODE)) throw new Error(`ui-refine-loop: unknown mode "${MODE}" — use manual | qa-hook`)
const CRITIC_KIND = input.critic ?? (input.impeccable ? 'impeccable' : 'rubric')
if (CRITIC_KIND === 'impeccable' && !input.impeccable) throw new Error('ui-refine-loop: critic "impeccable" needs args.impeccable')
const ROUNDS = input.rounds ?? (MODE === 'qa-hook' ? 3 : 10)
const TASTE = input.tasteFile ?? `${input.skillDir}/references/taste.md`

const FINDING = {
  type: 'object',
  properties: {
    id: { type: 'string', description: 'stable key <area>-<problem>, reused across rounds for the same issue' },
    severity: { type: 'string', enum: ['P0', 'P1', 'P2', 'P3'] },
    title: { type: 'string' },
    location: { type: 'string', description: 'file:line (repo-relative)' },
    evidence: { type: 'string', description: 'screenshot path + what is visible, or detector rule' },
    fix: { type: 'string' },
    verb: { type: 'string', description: 'polish, distill, layout, typeset, clarify, adapt, harden, onboard, quieter, optimize (colorize, bolder, animate, delight only when the prompt asks for more)' },
  },
  required: ['id', 'severity', 'title', 'location', 'evidence', 'fix', 'verb'],
}

const CRITIC = {
  type: 'object',
  properties: {
    verdict: { type: 'string', enum: ['DONE', 'CONTINUE'] },
    heuristicsTotal: { type: 'number' },
    heuristicsMax: { type: 'number', description: '40, or less when heuristics were n/a' },
    auditTotal: { type: 'number', description: 'audit score out of 20; omit when this round skips the audit' },
    detectorCount: { type: 'number' },
    findings: { type: 'array', items: FINDING, description: 'ranked, P0 first; at most 8' },
    summary: { type: 'string', description: 'two sentences: overall state and the single biggest remaining problem' },
    openQuestions: { type: 'array', items: { type: 'string' } },
  },
  required: ['verdict', 'heuristicsTotal', 'heuristicsMax', 'detectorCount', 'findings', 'summary'],
}

const REFINER = {
  type: 'object',
  properties: {
    status: { type: 'string', enum: ['committed', 'reverted', 'nothing-to-do'] },
    commit: { type: 'string', description: 'short sha, or empty' },
    verbs: { type: 'array', items: { type: 'string' } },
    fixed: { type: 'array', items: { type: 'string' }, description: 'finding ids fixed' },
    skipped: { type: 'array', items: { type: 'object', properties: { id: { type: 'string' }, reason: { type: 'string' } }, required: ['id', 'reason'] } },
    outOfScope: { type: 'array', items: { type: 'object', properties: { file: { type: 'string' }, why: { type: 'string' } }, required: ['file', 'why'] } },
    checks: { type: 'string', description: 'check command results, one line' },
    afterShots: { type: 'array', items: { type: 'string' } },
    openQuestions: { type: 'array', items: { type: 'string' } },
  },
  required: ['status', 'commit', 'verbs', 'fixed', 'skipped', 'outOfScope', 'checks', 'afterShots'],
}

const criticTools = CRITIC_KIND === 'impeccable'
  ? `Critic method: impeccable. Launcher: ${input.impeccable} (playbooks in its skill folder's reference/).`
  : `Critic method: rubric. Impeccable is not installed — score with ${input.skillDir}/references/rubric.md instead; there is no detector, so detectorCount is the rubric's mechanical-check hits.`

const common = () => [
  `Target: ${input.target} (route ${input.route} at ${input.baseUrl}).`,
  `Scope (repo-relative): ${input.scope.join(', ')}.`,
  MODE === 'qa-hook'
    ? `Worktree: ${input.worktree} — the QA lane's checkout of issue #${input.issue ?? '?'}'s branch. Edit only there; never push, never switch branches.`
    : `Worktree: ${input.worktree} — run every command there and edit files only under that path. The main checkout is another session's; never touch it.`,
  `Run dir (shots, auth, logs): ${input.runDir}.`,
  criticTools,
  `Taste file (read first; cite its ids): ${TASTE}.`,
  `Checks that must stay green: ${input.checks.length ? input.checks.join(' && ') : '(none detected — say so in checks)'}.`,
  `Screenshot command (append --label <label>): ${input.shootCmd}`,
  `Design context: ${input.context ?? 'no PRODUCT.md / DESIGN.md; the incumbent implementation is the design authority; refinement preserves it.'}`,
  `The brief, verbatim: """${input.prompt}"""`,
].join('\n')

const ledgerText = (ledger) => (ledger.length ? ledger.join('\n') : '(first round — no ledger yet)')

const ledger = [...(input.priorLedger ?? [])]
const rounds = []
let shots = [...input.beforeShots, ...(input.extraShots ?? [])]
let doneStreak = 0
let best = -1
let sinceBest = 0
let refineFails = 0
let stopReason = `ran all ${ROUNDS} rounds`
let lastAudit = null
let prevCleanDone = false
const openQuestions = []

for (let n = 1; n <= ROUNDS; n++) {
  phase('Critique')
  // The audit is the expensive half: round 1, every 3rd round, the last round,
  // and any round that may end the loop (the one after a clean DONE).
  const runAudit = n === 1 || n % 3 === 0 || n === ROUNDS || prevCleanDone
  const critic = await agent(
    [
      `You are the round-${n} critic of a refine loop. Read ${input.skillDir}/references/critic-brief.md and follow it exactly.`,
      common(),
      runAudit
        ? 'Audit: RUN it this round (all five dimensions) and return auditTotal.'
        : `Audit: SKIP it this round — critique and detect only, omit auditTotal. Last audit: ${lastAudit ?? 'none'}/20.`,
      `Latest screenshots (Read each one): ${shots.join(', ')}`,
      `Ledger of earlier rounds:\n${ledgerText(ledger)}`,
    ].join('\n\n'),
    { phase: 'Critique', label: `critic r${n}`, schema: CRITIC },
  )
  if (!critic) { stopReason = `critic r${n} died`; break }
  openQuestions.push(...(critic.openQuestions ?? []))

  if (critic.auditTotal != null) lastAudit = critic.auditTotal
  const audit = critic.auditTotal != null ? `audit ${critic.auditTotal}/20` : `audit ${lastAudit ?? '–'}/20 (carried)`
  const score = Math.round((critic.heuristicsTotal / (critic.heuristicsMax || 40)) * 400) / 10
  const blocking = critic.findings.filter((f) => f.severity === 'P0' || f.severity === 'P1')
  const counts = ['P0', 'P1', 'P2', 'P3'].map((s) => `${s}×${critic.findings.filter((f) => f.severity === s).length}`).join(' ')
  const round = { n, score, audit: critic.auditTotal ?? null, auditRun: runAudit, verdict: critic.verdict, counts, findings: critic.findings, summary: critic.summary }
  rounds.push(round)

  if (score > best) { best = score; sinceBest = 0 } else { sinceBest++ }
  const cleanDone = critic.verdict === 'DONE' && blocking.length === 0
  doneStreak = cleanDone ? doneStreak + 1 : 0
  prevCleanDone = cleanDone

  if (doneStreak >= 2) {
    ledger.push(`R${n} · ${score}/40 · ${audit} · DONE (2nd in a row) · remaining ${counts}`)
    stopReason = 'two consecutive clean DONE verdicts'
    break
  }
  if (sinceBest >= 3) {
    ledger.push(`R${n} · ${score}/40 · ${audit} · ${critic.verdict} · remaining ${counts}`)
    stopReason = `score plateaued at ${best}/40 for 3 rounds`
    break
  }
  if (cleanDone) {
    ledger.push(`R${n} · ${score}/40 · ${audit} · DONE · no refine; next critic confirms · remaining ${counts}`)
    continue
  }

  phase('Refine')
  const commitMsg = MODE === 'qa-hook'
    ? `refine(#${input.issue ?? input.slug}) round ${n}: <what changed>`
    : `refine(${input.slug}) round ${n}: <what changed>`
  const refiner = await agent(
    [
      `You are the round-${n} refiner of a refine loop. Read ${input.skillDir}/references/refiner-brief.md and follow it exactly.`,
      common(),
      `Commit message: "${commitMsg}". Screenshot label: round-${n}.`,
      `Findings from this round's critic (fix P0 → P1 → P2; P3 only if trivial and in the same files):\n${JSON.stringify(critic.findings, null, 2)}`,
    ].join('\n\n'),
    { phase: 'Refine', label: `refiner r${n}`, schema: REFINER },
  )
  if (!refiner) { stopReason = `refiner r${n} died`; break }
  openQuestions.push(...(refiner.openQuestions ?? []))
  round.refine = refiner

  const oos = refiner.outOfScope.length ? ` · out-of-scope: ${refiner.outOfScope.map((o) => `${o.file} (${o.why})`).join('; ')}` : ''
  ledger.push(
    `R${n} · ${score}/40 · ${audit} · ${refiner.status} ${refiner.commit || ''} [${refiner.verbs.join(', ')}]` +
      `\n  fixed: ${refiner.fixed.join(', ') || '—'} · skipped: ${refiner.skipped.map((s) => s.id).join(', ') || '—'}${oos}` +
      `\n  remaining after: ${critic.findings.filter((f) => !refiner.fixed.includes(f.id)).map((f) => `${f.severity} ${f.id}`).join(', ') || 'none'}`,
  )
  log(ledger[ledger.length - 1].split('\n')[0])

  if (refiner.status === 'reverted') {
    refineFails++
    if (refineFails >= 2) { stopReason = 'two refiner rounds in a row went red and were reverted'; break }
  } else {
    refineFails = 0
  }
  if (refiner.afterShots.length) shots = refiner.afterShots
}

const scoreLine = rounds.map((r) => `R${r.n} ${r.score}`).join(' → ')
return { mode: MODE, stopReason, best, scoreLine, ledger, rounds, finalShots: shots, openQuestions }
