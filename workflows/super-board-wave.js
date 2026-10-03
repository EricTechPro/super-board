export const meta = {
  name: 'super-board-wave',
  description: 'Drain one super-board wave: classify, then build → qa → review per card (lifecycles per run.md)',
  whenToUse: 'Launched by the super-board run-workflow backend with args from super-board-wave-plan.sh. Not for direct ad-hoc use.',
  phases: [
    { title: 'Pre-flight', detail: 'per Ready card: already done? in progress? file overlap? unclear? (run.md → Builder pre-flight)' },
    { title: 'Classify', detail: 'haiku router: kind (feature | bug | qa) + complexity per Ready card' },
    { title: 'Build', detail: 'Builder lifecycle (run.md): worktree, branch, draft PR' },
    { title: 'QA', detail: 'Tester lifecycle (run.md): test plan, evidence, screenshots' },
    { title: 'Review', detail: 'Reviewer lifecycle (run.md): gates, rerun tests, merge' },
  ],
}

// args = {
//   configPath: '.claude/super-board/configs/<slug>.json',
//   cards: [{ number, status, title, lane, labels }],  // output of super-board-wave-plan.sh
//     lane: 'build' | 'qa' | 'review' — a Ready card labelled `qa` has lane 'qa'
//     and skips the Builder; every other Ready card is built first (v3.0.0).
//   tier: 'low' | 'medium' | 'high' (optional, default 'medium'),  // run model ladder
// }
// The harness can deliver `args` as a JSON-encoded string (the tool param is
// untyped) — normalize before validating.
const input = (() => {
  if (typeof args !== 'string') return args
  try { return JSON.parse(args) } catch { return args }
})()
if (!input || !Array.isArray(input.cards) || !input.configPath) {
  throw new Error('super-board-wave needs args {configPath, cards:[{number,status,title,lane}]}')
}
// `variant` was removed in v3.0.0; the planner refuses a "qa-only" config, so a
// wave launched with one is a stale caller. Refuse rather than guess.
if (input.variant && input.variant !== 'full') {
  throw new Error(`super-board-wave: variant "${input.variant}" was removed in v3.0.0 — labels route cards; run /super-board onboard to upgrade`)
}
// Lane for a card entering at Ready: the planner's `lane`, else its labels.
const labelsOf = (card) => (card.labels || []).map((l) => String(l).toLowerCase())
const readyLane = (card) => card.lane || (labelsOf(card).includes('qa') ? 'qa' : 'build')
if (input.tier && !['low', 'medium', 'high'].includes(input.tier)) {
  throw new Error(`super-board-wave: unknown tier "${input.tier}" — use low | medium | high`)
}

const CLASSIFY_SCHEMA = {
  type: 'object',
  properties: {
    kind: { type: 'string', enum: ['feature', 'bug', 'qa'] },
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
    // Review lane only, on a re-review: how round 1 graded the prior report.
    priorFindings: {
      type: 'object',
      properties: {
        fixed: { type: 'integer' },
        notFixed: { type: 'integer' },
        noLongerApplies: { type: 'integer' },
      },
    },
  },
  required: ['status', 'column', 'detail'],
}

const LANE = {
  build:  { skill: 'super-build',  section: 'Builder',  phase: 'Build' },
  qa:     { skill: 'super-qa',     section: 'Tester',   phase: 'QA' },
  review: { skill: 'super-review', section: 'Reviewer', phase: 'Review' },
}

// The merge-race guard used to live here, as a promise chain around the whole
// Review lane. It is gone on purpose (2026-08-20).
//
// It guarded the right thing in the wrong place. Squash-merges into one base
// branch do race — but serialising the entire lane also serialised reading the
// diff, rerunning the suite and the truth-check, none of which touch the base.
// On a wide wave that made Review the throughput ceiling for work that could
// have run in parallel. It was also invisible to the `claude-p` backend and to a
// second orchestrator on another machine, because a JS promise cannot be seen
// from another process.
//
// The mutex now sits at the merge step itself, in super-board-merge-gate.sh, as
// an atomic mkdir lock the Reviewer takes for the seconds it needs — and the
// freshness check runs INSIDE that lock, so nothing can move the base between
// the proof and the merge. See run.md → Reviewer lifecycle step 5.

// Review remembers: a card back in Review after a bounce is graded against the
// last Reviewer report first (run.md → Reviewer step 3b). The lookup is one gh
// call by marker, so the lane does it — this script never sees PR comments.
const REVIEW_MEMORY = [
  `Before reviewing, load prior_report: the newest PR comment containing "<!-- super-review:report -->" (run.md → Reviewer step 3b).`,
  `None → first review, behave as usual. Found → round 1 marks each prior finding fixed / not fixed / no longer applies;`,
  `any not fixed → bounce again listing them. Edit that report comment in place (keep R-ids), never post a second one. Report the counts as priorFindings.`,
  // Independent pass (run.md → Reviewer step 3): hypotheses before the builder's account.
  `Read the issue ACs and the diff before the builder's PR summary; form your own hypotheses, then check their claims.`,
  `Class every finding Gap / Bug / Verification miss / Scope drift / Over-engineering, and list what you verified correct.`,
  // Simplest-solution pass (super-review step 3): Should fix at most, never a bounce on its own.
  `Run ponytail:ponytail-review on the merge-base diff (inline ladder if the plugin is absent); Over-engineering never blocks merge alone.`,
  // Truth-check brief is fixed (super-review → Adversarial mode); a hand-written one once made over-building blocking.
  `Truth-check sub-agents get the fixed brief from super-review → "Adversarial mode", verbatim. After collecting, reclass any Over-engineering Blocker to Should fix; it never decides merge or bounce.`,
  // Merge policy + migrations live in the gate (run.md → Merge protocol step 5).
  `Merge only via super-board-merge-gate.sh. Exit 7 = merge_policy says a human merges (money/auth/schema/size): Blocked with the 🙋 template quoting its human-gate lines; To unblock = merge it yourself, or comment done to approve.`,
  `Exit 8 = 🙋 needs you (migration for a DB the robot may not touch, failed migrate, declared human step): Blocked with the 🙋 template, exact commands from its needs-you lines, label needs-you.`,
]

const lanePrompt = (lane, card) => [
  `Run ${LANE[lane].skill} on issue #${card.number} ("${card.title}") for a super-board workflow wave.`,
  `Read .claude/skills/super-board/references/run.md → "${LANE[lane].section}" lifecycle and follow it EXACTLY:`,
  `create your own worktree under .claude/worktrees/, work on the issue branch, post the required PR/issue comments,`,
  `move the project card yourself, clean up the worktree on exit. Config: ${input.configPath}.`,
  `Commits, PR title, PR body blocks, comments: .claude/skills/super-board/references/writing-standard.md. Rewrite only your own PR body blocks, with .claude/bin/super-board-pr-body.sh.`,
  ...(lane === 'review' ? REVIEW_MEMORY : []),
  ...(lane === 'qa' && card.status === 'Ready'
    ? [`This card is labelled qa: it skips Building. Move it Ready → QA yourself, create the issue branch from the base branch, and test what is already there (run.md → "qa cards").`]
    : []),
  ``,
  `Report your exit via structured output:`,
  `- status=advanced  → card moved forward (Building→QA, QA→Review, Review→Done/merged)`,
  `- status=bounced   → card moved backward (QA fail → Ready, Reviewer bounce → Ready/QA)`,
  `- status=blocked or human-gate → you wrote the Block template and moved the card to Blocked`,
  `- status=failed    → you could not complete the lifecycle (say why in detail)`,
  `column = the column the card is in when you exit. detail = one line. Include prUrl/branch when they exist.`,
].join('\n')

// Run-tier model ladders. Card complexity indexes into the active ladder;
// undefined = inherit the session model (the strongest available — e.g.
// Fable/Opus). Cards entering past Ready (cls null, never classified)
// always inherit the session model.
//   low    (run --low):  haiku / sonnet / opus
//   medium (default):    sonnet / opus / session
//   high   (run --high): opus / session / session
const LADDERS = {
  low: { low: 'haiku', medium: 'sonnet', high: 'opus' },
  medium: { low: 'sonnet', medium: 'opus', high: undefined },
  high: { low: 'opus', medium: undefined, high: undefined },
}
const ladder = LADDERS[input.tier || 'medium']
const tierFor = (cls) => (cls ? ladder[cls.complexity] : undefined)
// The classify router writes no code — haiku is fine except on --high runs.
const classifyModel = (input.tier || 'medium') === 'high' ? 'sonnet' : 'haiku'

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

// Builder pre-flight (run.md → "Builder pre-flight"). Before ANY Ready card
// reaches runLane('build'), a fresh cheap agent asks: already merged? already
// being built (open PR or another card)? same files as an open PR? unclear?
// One agent per batch of PREFLIGHT_BATCH cards, so the three gh list calls in
// super-board-preflight.sh are paid once per batch, not once per card.
// Outcomes: proceed · hold (agent wrote the Block template, card → Blocked) ·
// sequence (card → Blocked with `blocked-by:` the overlapping PR's issue, so the
// wave-start sweep frees it; or proceed with a conflict note when that PR closes
// no issue) · skipped (pre-flight blind — card stays Ready for the next wave).
// A card the agent did not answer for is skipped, never built unchecked.
const PREFLIGHT_SCHEMA = {
  type: 'object',
  properties: {
    verdicts: {
      type: 'array',
      items: {
        type: 'object',
        properties: {
          number: { type: 'integer' },
          verdict: { type: 'string', enum: ['proceed', 'hold', 'sequence', 'skipped'] },
          column: { type: 'string' },
          detail: { type: 'string' },
        },
        required: ['number', 'verdict', 'detail'],
      },
    },
  },
  required: ['verdicts'],
}
const PREFLIGHT_BATCH = 5
const preflightModel = (input.tier || 'medium') === 'low' ? 'haiku' : 'sonnet'
const preflightPrompt = (batch) => [
  `Builder pre-flight for issues ${batch.map((c) => `#${c.number} ("${c.title}")`).join(', ')}. Config: ${input.configPath}.`,
  `Read .claude/skills/super-board/references/run.md → "Builder pre-flight" and follow it EXACTLY. You write no code.`,
  `Other cards in this wave: ${JSON.stringify(input.cards.map(({ number, status, title }) => ({ number, status, title })))}`,
  `Run .claude/bin/super-board-preflight.sh once for the whole batch, then judge its candidates semantically.`,
  `hold / sequence-behind → post the Block template (block-template.md) and move the card to Blocked yourself.`,
  `Return one verdict per issue: proceed | hold | sequence | skipped (pre-flight blind). Never drop a card silently.`,
].join('\n')

// Only cards the Builder will take are pre-flighted; `qa` cards skip Building.
const ready = input.cards.filter((c) => c.status === 'Ready' && readyLane(c) === 'build')
const verdicts = new Map()
const batches = []
for (let i = 0; i < ready.length; i += PREFLIGHT_BATCH) batches.push(ready.slice(i, i + PREFLIGHT_BATCH))
await Promise.all(batches.map(async (batch) => {
  const r = await agent(preflightPrompt(batch), {
    label: `preflight:${batch.map((c) => '#' + c.number).join(',')}`,
    phase: 'Pre-flight',
    model: preflightModel,
    schema: PREFLIGHT_SCHEMA,
  })
  for (const v of (r && r.verdicts) || []) verdicts.set(v.number, v)
}))
// sequence with nothing to wait on = proceed with a conflict note (the agent posted it).
const preflightGo = (card) => {
  const v = verdicts.get(card.number)
  return !!v && (v.verdict === 'proceed' || (v.verdict === 'sequence' && v.column === 'Ready'))
}
const preflightExit = (card) => {
  const v = verdicts.get(card.number) ||
    { verdict: 'skipped', detail: 'pre-flight returned no verdict — not built unchecked; retried next wave' }
  return {
    lane: 'preflight',
    status: v.verdict === 'skipped' ? 'failed' : 'blocked',
    column: v.column || (v.verdict === 'skipped' ? 'Ready' : 'Blocked'),
    detail: `${v.verdict}: ${v.detail}`,
  }
}

const results = await pipeline(
  input.cards,
  // Stage 1: classify cards entering at Ready (router for model tiering)
  async (card) => {
    if (card.status !== 'Ready') return { card, cls: null }
    const labels = labelsOf(card)
    const typed = ['qa', 'bug', 'feature'].find((l) => labels.includes(l))
    const cls = await agent(
      `Read GitHub issue #${card.number} ("${card.title}") — body and all comments — using gh issue view. ` +
      `Classify it: kind (feature|bug|qa) and complexity (low|medium|high) judged by the scope of change required. ` +
      (typed
        ? `Its label says "${typed}": return kind "${typed}" — the label routes the card, you never override it.`
        : `It has no type label, so it is built (no label = Building). Return feature or bug — never qa, ` +
          `which only a person sets — and add that label: gh issue edit ${card.number} --add-label <kind>.`),
      { label: `classify:#${card.number}`, phase: 'Classify', model: classifyModel, schema: CLASSIFY_SCHEMA }
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

    if (at === 'Ready' && readyLane(card) === 'build') {
      if (!preflightGo(card)) {
        history.push(preflightExit(card))
        return { number: card.number, history }
      }
      const b = await runLane('build', card, model, history)
      if (b.status !== 'advanced') return { number: card.number, history }
      at = 'QA'
    }
    // A `qa`-labelled card skips Building: Ready → QA, Tester first
    // (run.md "Lanes and label routing").
    if (at === 'Ready' && readyLane(card) === 'qa') at = 'QA'
    if (at === 'QA') {
      const q = await runLane('qa', card, model, history)
      if (q.status !== 'advanced') return { number: card.number, history }
      at = 'Review'
    }
    if (at === 'Review') {
      // Reviewer always on session model. No lane-level serialisation: the merge
      // gate holds the mutex for the merge alone (see the note above).
      await runLane('review', card, undefined, history)
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
    priorFindings: last.priorFindings || null,
    lanesRun: r.history.map((h) => `${h.lane}:${h.status}`).join(' → ') || 'none',
  }
})
log(`wave complete: ${summary.length} cards — ` +
    summary.map((s) => `#${s.number}=${s.finalStatus}@${s.column}`).join(', '))
return { cards: summary }
