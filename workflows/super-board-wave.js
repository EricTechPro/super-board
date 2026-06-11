export const meta = {
  name: 'super-board-wave',
  description: 'Drain one super-board wave: classify, then build → qa → review per card (lifecycles per run.md)',
  whenToUse: 'Launched by the super-board run-workflow backend with args from super-board-wave-plan.sh. Not for direct ad-hoc use.',
  phases: [
    { title: 'Classify', detail: 'haiku router: kind + complexity per Ready card' },
    { title: 'Build', detail: 'Builder lifecycle (run.md): worktree, branch, draft PR' },
    { title: 'QA', detail: 'Tester lifecycle (run.md): test plan, evidence, screenshots' },
    { title: 'Review', detail: 'Reviewer lifecycle (run.md): gates, rerun tests, merge' },
  ],
}

// args = {
//   configPath: '.claude/super-board/configs/<slug>.json',
//   variant: 'full' | 'qa-only',
//   cards: [{ number, status, title }],     // output of super-board-wave-plan.sh
//   humanApprovesMerge: boolean (optional, default false),
// }
if (!args || !Array.isArray(args.cards) || !args.configPath || !args.variant) {
  throw new Error('super-board-wave needs args {configPath, variant, cards:[{number,status,title}]}')
}

const CLASSIFY_SCHEMA = {
  type: 'object',
  properties: {
    kind: { type: 'string', enum: ['feature', 'bug', 'docs', 'chore'] },
    complexity: { type: 'string', enum: ['low', 'medium', 'high'] },
  },
  required: ['kind', 'complexity'],
}

const STAGE_SCHEMA = {
  type: 'object',
  properties: {
    status: { type: 'string', enum: ['advanced', 'bounced', 'blocked', 'human-gate', 'failed'] },
    column: { type: 'string' },
    detail: { type: 'string' },
    prUrl: { type: 'string' },
    branch: { type: 'string' },
  },
  required: ['status', 'column', 'detail'],
}

const LANE = {
  build:  { skill: 'super-build',  section: 'Builder',  phase: 'Build' },
  qa:     { skill: 'super-qa',     section: 'Tester',   phase: 'QA' },
  review: { skill: 'super-review', section: 'Reviewer', phase: 'Review' },
}

// Merge-race guard, execution side: on auto-merge boards (humanApprovesMerge
// false) Reviewer agents squash-merge into the same base branch, so Review
// lanes must run one at a time even when card chains reach Review in the
// same wave. Promise-chain mutex; the catch keeps one failed review from
// poisoning the chain.
let reviewLock = Promise.resolve()
const withReviewLock = (fn) => {
  const run = reviewLock.then(fn)
  reviewLock = run.then(() => undefined, () => undefined)
  return run
}

const lanePrompt = (lane, card) => [
  `Run ${LANE[lane].skill} on issue #${card.number} ("${card.title}") for a super-board workflow wave.`,
  `Read .claude/skills/super-board/references/run.md → "${LANE[lane].section}" lifecycle and follow it EXACTLY:`,
  `create your own worktree under .worktrees/, work on the issue branch, post the required PR/issue comments,`,
  `move the project card yourself, clean up the worktree on exit. Config: ${args.configPath}.`,
  ``,
  `Report your exit via structured output:`,
  `- status=advanced  → card moved forward (Building→QA, QA→Review, Review→Done/merged)`,
  `- status=bounced   → card moved backward (QA fail → Ready, Reviewer bounce → Ready/QA)`,
  `- status=blocked or human-gate → you wrote the Block template and moved the card to Blocked`,
  `- status=failed    → you could not complete the lifecycle (say why in detail)`,
  `column = the column the card is in when you exit. detail = one line. Include prUrl/branch when they exist.`,
].join('\n')

// Cheap cards run on cheaper models; 'high' — and cards entering past
// Ready (cls null, never classified) — inherit the session model.
const tierFor = (cls) => {
  if (!cls) return undefined
  if (cls.complexity === 'low') return 'haiku'
  if (cls.complexity === 'medium') return 'sonnet'
  return undefined
}

const runLane = async (lane, card, model, history) => {
  const r = await agent(lanePrompt(lane, card), {
    label: `${lane}:#${card.number}`,
    phase: LANE[lane].phase,
    schema: STAGE_SCHEMA,
    ...(model ? { model } : {}),
  })
  const result = r || { status: 'failed', column: 'unknown', detail: `${lane} agent returned no result` }
  history.push({ lane, ...result })
  return result
}

const results = await pipeline(
  args.cards,
  // Stage 1: classify cards entering at Ready (router for model tiering)
  async (card) => {
    if (card.status !== 'Ready') return { card, cls: null }
    const cls = await agent(
      `Read GitHub issue #${card.number} ("${card.title}") — body and all comments — using gh issue view. ` +
      `Classify it: kind (feature|bug|docs|chore) and complexity (low|medium|high) judged by the scope of code change required.`,
      { label: `classify:#${card.number}`, phase: 'Classify', model: 'haiku', schema: CLASSIFY_SCHEMA }
    )
    return { card, cls }
  },
  // Stage 2: lane chain — entry point depends on the card's current column.
  // A non-'advanced' exit ends the chain; the next wave re-selects the card
  // from wherever it landed (the board is the loop state, not this script).
  async (prev, card) => {
    const history = []
    const model = tierFor(prev && prev.cls)
    let at = card.status

    if (at === 'Ready' && args.variant === 'full') {
      const b = await runLane('build', card, model, history)
      if (b.status !== 'advanced') return { number: card.number, history }
      at = 'QA'
    }
    // By design: qa-only boards have no Builder lane — Ready cards go
    // straight to the Tester (run.md "Lane mapping by variant").
    if (at === 'Ready' && args.variant === 'qa-only') at = 'QA'
    if (at === 'QA') {
      const q = await runLane('qa', card, model, history)
      if (q.status !== 'advanced') return { number: card.number, history }
      at = 'Review'
    }
    if (at === 'Review') {
      // Reviewer always on session model; serialized unless a human merges.
      const review = () => runLane('review', card, undefined, history)
      if (args.humanApprovesMerge) { await review() } else { await withReviewLock(review) }
    }
    return { number: card.number, history }
  }
)

const summary = results.filter(Boolean).map((r) => {
  const last = r.history[r.history.length - 1] ||
    { lane: 'none', status: 'failed', column: 'unknown', detail: 'no lane ran' }
  return {
    number: r.number,
    finalStatus: last.status,
    lastLane: last.lane,
    column: last.column,
    detail: last.detail,
    prUrl: last.prUrl || null,
    lanesRun: r.history.map((h) => `${h.lane}:${h.status}`).join(' → ') || 'none',
  }
})
log(`wave complete: ${summary.length} cards — ` +
    summary.map((s) => `#${s.number}=${s.finalStatus}@${s.column}`).join(', '))
return { cards: summary }
