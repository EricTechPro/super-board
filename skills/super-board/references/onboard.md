# super-board onboard — verb reference

Config schema and field notes: `config-schema.json`.

This file documents the interactive setup wizard. It is loaded by `SKILL.md`
when the user invokes `super-board onboard …`.

**Where it runs:** current Claude Code session, in user's CWD. Not headless.
Invoked as `/super-board onboard` (installed with install.sh / get.sh) or
`/super-board:super-board onboard` (plugin install — skill names carry the plugin prefix).

**Design rules**

| Rule | How |
|---|---|
| Detect first | ask only what detection cannot answer |
| Halt early | anything that can stop onboard (runtime, auth) runs before the questions it would waste |
| Recommended first | every question puts its recommended option FIRST, labelled `(Recommended)`, so Enter picks it; one short line says why |
| One tool | ask with `AskUserQuestion` (≤ 4 questions per call, `multiSelect` where noted). NEVER free-text a choice that has options |
| Save as you go | every answer is written to `.claude/super-board/onboard-answers.json` the moment it is given |
| Write once | nothing in the target repo changes until the review screen (step 15) is approved — drafts live in `.claude/super-board/onboard-staged/` |
| Secrets | NEVER read, grep, cat or source a dotenv file. Key names only, via `.claude/bin/super-board-env-check.sh` |

---

## Intro shown when onboard starts

```
super-board onboard
─────────────────────────────────────────────────────────
super-board = a GitHub Project pipeline that runs autonomously.
              It drains issues from Ready across columns
              (Building → QA → Review → Done) until the board
              is empty or only Blocked/Skipped cards remain.

What will need your OK along the way:
  • a GitHub browser sign-in, only if gh lacks the project scopes
  • edits to .claude/settings.json (permission lines, optional push guard) — shown as a diff first
  • AGENTS.md / CLAUDE.md, only if you say yes — shown as a diff first
  • one review screen before anything is written

Progress: 🛠 onboard (you are here)  →  🧹 lint  →  🤖 run
─────────────────────────────────────────────────────────
```

---

## The answers file

`.claude/super-board/onboard-answers.json` (gitignored — step 15 adds it). Shape:

```json
{ "version": 1, "updated": "<iso>", "last_step": "policies",
  "answers": { "goal": "B", "project": {"owner": "acme", "number": 7},
               "agents": "refine", "base_branch": "staging",
               "policies": {"merge_default": "auto", "protect_main": true,
                            "allowed_envs": ["test", "staging"]},
               "permissions": "approved", "collect": ["github", "prs"] } }
```

Write it (atomically: temp file + rename) after EVERY answer and after every step that
detects something worth keeping. A halt never loses work: re-running onboard resumes at
`last_step` with every earlier answer pre-filled.

---

## Step-by-step logic

```
0. SILENT DETECT (no questions)
   ├─ CWD: git repo? commits? remote URL? manifests? empty folder?
   ├─ .claude/super-board/configs/*.json, active pointer, onboard-answers.json
   ├─ PROJECT.md, docs/agents/issue-tracker.md
   ├─ Instruction files: python3 .claude/bin/super-board-agents-md.py detect
   │    (AGENTS.md / CLAUDE.md / CLAUDE.local.md / .claude/CLAUDE.md / GEMINI.md / …,
   │     pointer or not, managed block or not)
   ├─ Production signals for step 11 (deploy workflow on push to base, vercel.json /
   │    netlify.toml, branch protection requiring review, live URL in README)
   ├─ Migration dirs (supabase/migrations, prisma/migrations, drizzle, **/migrations/*.sql,
   │    db/migrate, alembic/versions) and migrate scripts in the manifest (db:migrate, …)
   ├─ Collect sources (step 14 detection list) + key names:
   │    bash .claude/bin/super-board-env-check.sh SENTRY_AUTH_TOKEN POSTHOG_PERSONAL_API_KEY
   ├─ Guard hooks: .claude/hooks/guard-protected-push.py present? wired in settings.json?
   ├─ Machine time zone (IANA name) for config `timezone`: $TZ if set, else
   │    readlink /etc/localtime | sed 's#.*zoneinfo/##' (macOS, most Linux), else
   │    timedatectl show -p Timezone --value, else "UTC". No question — shown on the review screen.
   └─ settings.json permissions.allow (for the step 13 diff)

1. RE-RUN CHECK (only when a config or answers file exists)
   ├─ Show current values in one table (config + answers).
   ├─ AskUserQuestion "Onboard found an existing setup. What now?"
   │    • Keep all — check and repair (Recommended)   ← = option D below
   │    • Edit which?   → multiSelect of the steps (goal, project, AGENTS.md, base branch,
   │                      policies, permissions, collect sources); walk only those, every
   │                      other value kept; then step 15
   │    • Start over    → answers file renamed .bak, full flow
   ├─ Interrupted run (answers.last_step set, no config yet) → "Resume at <step>? (Recommended)"
   └─ ALWAYS, on every re-run and after every install/update: if detect says
      `offer_merge: true` (a CLAUDE.md that is not the `@AGENTS.md` pointer), offer step 9
      again even under "Keep all".

2. INSTALL CHECKS + WORKFLOW RUNTIME (before the first real question — halt early, not late)
   2a. What is installed? A plugin install (`/plugin install super-board@super-board`) ships
       ONLY the 7 skills — invoked with the plugin prefix, `/super-board:super-board onboard`.
       It lacks everything below, so check each:
       ├─ .claude/bin/super-board-*.sh|py      (merge gate, wave plan, env-check, helpers)
       ├─ .claude/workflows/super-board-wave.js, ui-refine-loop.js
       ├─ .claude/hooks/guard-*.py, cleanup-wt.py + their entries in .claude/settings.json
       └─ Matt Pocock's helper skills the lanes load (code-review, codebase-design,
          resolving-merge-conflicts, tdd …) under .claude/skills/ or ~/.claude/skills/
       Anything missing → say what, then AskUserQuestion "Install the missing pieces?"
         • Install everything, guard hooks included (Recommended)
         • Install without guard hooks (--no-hooks)
         • Stop — I'll install by hand
       Install = run the pack's own install.sh from the PLUGIN's copy (outside the project),
       never a copy inside the repo:
         PACK=$(dirname "$(find ~/.claude/plugins -path '*super-board*' -name install.sh \
                -not -path '*/node_modules/*' 2>/dev/null | head -1)")
         bash "$PACK/install.sh" [--no-hooks] "$PWD"
         npx -y skills@latest add mattpocock/skills --skill '*' -a claude-code -y
       ($PACK empty → "🛑 Can't find the super-board plugin files. Run the one-line installer
        (get.sh) or `./install.sh <this-dir>` from a checkout, then re-run onboard.")
       Protect main is NOT a flag here — step 12 asks it once.
       After installing, the unprefixed `/super-board onboard` also works (project skills).
   2b. Workflow runtime. (Skip only when an existing config sets worker_backend: "claude-p".)
   The default backend launches .claude/workflows/super-board-wave.js. That file IS the
   dynamic workflow; without it `run` dies at its precondition #4.
   ├─ Present? → syntax-check it (same command run.md uses):
   │    { echo '(async function(){'; \
   │      sed 's/^export const meta/const meta/' .claude/workflows/super-board-wave.js; \
   │      echo '})'; } | node --check --input-type=module
   ├─ Missing → self-heal, first hit nearest first:
   │    a. <git-root>/.claude/workflows/super-board-wave.js
   │    b. find <up to 4 parents> -maxdepth 6 -path '*/super-board/workflows/super-board-wave.js' -print -quit
   │    → mkdir -p .claude/workflows && cp <hit> .claude/workflows/ → syntax-check the copy
   ├─ No hit / check fails → HALT now (nothing asked yet, nothing lost):
   │    "🛑 Missing or corrupt .claude/workflows/super-board-wave.js. Run `./install.sh <this-dir>`
   │     from your super-board checkout, then re-run super-board onboard."
   └─ Remind once: dynamic workflows must be ON in /config (the run will refuse otherwise).

3. ONE BIG QUESTION — "What do you want to run in a loop?"
   ├─ B) Build features for a local repo (Recommended when CWD is a repo)
   │       → variant = full, target = repo (+ optional URL)
   ├─ C) QA a local repo (already built)          → variant = qa-only, target = repo (+ URL)
   ├─ A) Test a live URL (no code access)         → variant = qa-only, target = url
   └─ D) Use an existing config — check and repair (Recommended when a config exists)
           → pick the config → run the five self-checks (bottom of this file), repair what is
             missing (columns, PROJECT.md, runtime, active pointer, collect pings), ask
             NOTHING else, then step 16. Offers step 9 only when offer_merge is true.
   (Order the options so the recommended one is first for THIS folder.)

4. GITHUB AUTH (always)
   ├─ `gh auth status` — must be authenticated; scopes `project`, `read:project`, `repo`
   ├─ Missing scope → say first: "This opens a browser to approve the project scopes —
   │    needed to move cards and create the board for you." Then
   │    `gh auth refresh -s project,read:project,repo`
   └─ Record bot_identity: `super-board-bot[bot]` when a GitHub App is installed on the repo,
      else the user's login.

5. GIT REPO (skip for A — a URL-only board needs no repo; say so in one line)
   ├─ B/C and CWD is not a repo → AskUserQuestion "Init git here? — worktrees, branches and
   │    merges need it" [Init git (Recommended) / Stop]
   └─ No remote → offer `gh repo create` [Create private repo (Recommended) / Pick existing /
      Local only]

6. TARGET / SCAFFOLD
   ├─ A: ask for the URL → target.url; repo = null
   ├─ B: no commits → "Scaffold from a template?" [Blank + README (Recommended) / Next.js /
   │      Vite / NestJS]. Optional target.url.
   └─ C: ask only for a target URL, if any

7. GITHUB PROJECT
   ├─ List projects under the repo owner (or @me)
   ├─ [Create "<repo> board" (Recommended when none fits) / <existing projects…>]
   └─ Picked → validate columns (step 8). Created → `gh project create --title <name>`

8. COLUMNS (idempotent, no question)
   ├─ Full (7):    Ready · Building · QA · Review · Done · Blocked · Skipped
   ├─ QA-only (6): Ready ·            QA · Review · Done · Blocked · Skipped
   ├─ Add missing Status options, re-read to confirm.
   └─ There is NO "Needs you" column. A card waiting on a person goes to Blocked with the
      🙋 reason tag, the `needs-you` label and the exact command in the comment
      (block-template.md → "🙋 Needs you"). Say this once here.

9. AGENTS.md — SOURCE OF TRUTH (any flow with a local repo)
   See "AGENTS.md source of truth" below for the merge rules.
   ├─ AskUserQuestion "Refine AGENTS.md and make it the source of truth?"
   │    • Yes — merge CLAUDE.md into AGENTS.md, CLAUDE.md becomes @AGENTS.md (Recommended)
   │    • Only add the super-board section
   │    • Skip
   ├─ Yes → draft the merged AGENTS.md + CLAUDE.md into onboard-staged/, resolve conflicts one
   │    question at a time, show the unit→line mapping + diff, approve. Written in step 15.
   ├─ Only section → stage `block --create`; if only CLAUDE.md exists, stage `@AGENTS.md`
   │    prepended to it (nothing else changes).
   └─ Writing standard (no question, no opt-out — super-board's writing standard is always
      applied; never ask about writing style): stage docs/agents/issue-tracker.md with a
      `## Ticket format` section from references/ticket-format.md (create the file, or add /
      replace only that section). The AGENTS.md block's "Writing (super-board)" table links
      there and to .claude/skills/super-board/references/writing-standard.md — one copy, no drift.

10. PROJECT.md (skip for A, or if the user opts out)
    ├─ Sub-agent drafts it from manifests (package.json, pyproject.toml / requirements.txt,
    │    Cargo.toml, go.mod, Gemfile) + README + top-level tree. No manifest → ask
    │    "What does this project do? (one short paragraph)" and seed from the answer.
    ├─ Show draft → [Looks right (Recommended) / Edit]. Staged → docs/super-board/PROJECT.md
    └─ New or empty repo → offer "Turn this into your first tickets with /to-tickets?"
       [Yes, draft first tickets (Recommended) / Later]. Tickets use references/ticket-format.md
       and are created after step 15, straight into Ready.

11. BASE BRANCH (any flow with a local repo)
    ├─ Detect current + remote default branch; production signals from step 0
    ├─ "Which branch should super-board cut feature branches from and merge back into?"
    │    No production signal → [main (Recommended) / staging / develop]
    │    Production signal    → [Create staging from main (Recommended) / main — every merge
    │                            lands in production / develop]
    └─ Production base kept → policies step recommends "human" and target_env "live".

12. POLICIES — "What may the robot do?" (any flow with a local repo; ONE screen)
    First AskUserQuestion: "Accept the recommended policies?" showing the three picks
    (merge line reads "Recommended: auto-merge up to 400 changed lines"):
       [Accept all recommended (Recommended) / Review each]
    Review each → ONE AskUserQuestion call with three questions:
    a. Merge policy (header "Merge")
       Non-production base:
         • Auto-merge up to 400 changed lines; bigger PRs, money, auth and
           destructive schema (DROP/TRUNCATE/RENAME) wait for you (Recommended)
         • A human merges everything
       Production base kept:
         • A human merges everything (Recommended)
         • Auto-merge up to 400 changed lines; bigger PRs, money, auth and destructive schema
           wait for you → sets merge_policy.allow_auto_on_production: true (run.md's guard needs it)
       → merge_policy.default "auto" | "human"; auto_max_lines 400 (lockfiles, generated,
         snapshots, migration SQL not counted — size_exclude); always_human = schema defaults
         (labels / path globs / added-line keywords — config-schema.json). A matching PR is
         parked in Blocked with 🙋: you merge it, or comment `done` to approve. A PR over the cap
         shows as "big PR — please review".
    b. Protect the base branch (header "Push guard") — asked ONLY here, once
       Skip entirely if settings.json already wires guard-protected-push.py.
         • Block direct and force pushes to main/master/<base> (Recommended for existing apps)
         • No (fine for a brand-new repo)
       Yes + `.claude/hooks/guard-protected-push.py` present → staged settings merge (step 15).
       Yes + script MISSING (installed with --no-hooks) → do NOT wire a missing script; record
       the answer and tell the user: "Run `./install.sh --no-hooks --protect-main <this-dir>`
       from your super-board checkout — it installs only this guard."
    c. Databases the robot may migrate at merge (header "Migrations", multiSelect)
       Skip when step 0 found no migration dirs (write the defaults anyway).
         • test (Recommended) • staging (Recommended) • live
       → migrations.allowed_envs; target_env = "live" on a production base, else "staging";
         commands from the manifest's migrate scripts (ask only for a missing one, one line
         each; "-" = the deploy pipeline applies it). Secrets stay in env vars — check the
         names with super-board-env-check.sh, never the values.
    Say in ONE line, always: "The robot runs additive migrations on the databases you picked to
    test its work; a live database, or a destructive schema change (DROP/TRUNCATE/RENAME), always
    waits for you — 🙋 in Blocked with the exact command."

13. PERMISSIONS (after policies, before any run can stall on a prompt)
    Build the allowlist from the answers and show it as a diff:
      python3 .claude/bin/super-board-settings.py allow .claude/settings.json <rules…> --dry-run
    Rules: the base list in run-workflow.md → "Mid-run permission prompts", plus
      • merge_policy.default "auto": "Bash(bash .claude/bin/super-board-merge-gate.sh:*)",
        "Bash(gh pr merge:*)"
      • one "Bash(<command>)" per migrate command of an allowed env
      • "Bash(bash .claude/bin/super-board-env-check.sh:*)"
      • the project's test runner (from the manifest, e.g. "Bash(npm test:*)")
    AskUserQuestion [Add these lines (Recommended) / Skip — every merge will ask you].
    Approved → staged; written in step 15 (same helper, no --dry-run).

14. COLLECT SOURCES (any flow with a local repo; this config only)
    Sets up the `collect` block `/super-collect` reads.
    ├─ Detected in step 0:
    │    • Sentry:  @sentry/* / sentry-sdk / sentry_sdk in manifests, Sentry.init(,
    │               .sentryclirc, sentry.*.config.*; org/project from those or the DSN
    │    • PostHog: posthog-js / posthog-node / posthog in manifests, posthog.init(,
    │               NEXT_PUBLIC_POSTHOG_* / POSTHOG_HOST / POSTHOG_PROJECT_ID key names
    │    • Keys:    super-board-env-check.sh output (present / empty / missing) — NEVER values
    ├─ AskUserQuestion multiSelect "Enable which collect sources?" — detected ones first and
    │    marked (Recommended); github, prs, architecture need nothing extra
    ├─ Ask only what detection missed: Sentry org/project/region host, PostHog host/project_id.
    │    Missing key → the exact .env line to add (name only) + scopes: Sentry
    │    `event:read project:read`; PostHog personal key `query:read error_tracking:read`.
    ├─ PostHog failure events: grep the app's capture() calls for *_failed / *_error /
    │    status 'failed'; propose them for collect.posthog.failure_events, user confirms.
    └─ Test each enabled source now, read-only, BEFORE the review screen:
         python3 .claude/skills/super-collect/scripts/collect_sentry.py  --config <staged cfg> ping
         python3 .claude/skills/super-collect/scripts/collect_posthog.py --config <staged cfg> ping
         gh api graphql -f query='{viewer{login}}'          (github, prs)
       ✅/❌ per source. PostHog `silent` signals get a one-line suggestion (never edit the
       app). A failed ping leaves that source out of collect.sources and says how to re-test;
       it never halts onboard.

15. REVIEW SCREEN → WRITE ONCE
    Show ONE table: every answer + every file that will change (config path, active pointer,
    .gitignore lines, settings.json allow/hook additions, AGENTS.md, CLAUDE.md,
    docs/agents/issue-tracker.md, PROJECT.md). AskUserQuestion
      [Write everything (Recommended) / Change one thing → back to that step / Cancel].
    Write, in order (each atomic; stop and report on the first failure — answers are kept):
    ├─ .claude/super-board/configs/<slug>.json (committed): description, variant, project,
    │    target, repo, base_branch, timezone (the machine zone from step 0), columns, paths,
    │    merge_policy, migrations, collect, notifications {channel: "session", bot_identity},
    │    worker_backend "workflow"
    ├─ .claude/super-board/active ← <slug>
    ├─ .gitignore += .claude/super-board/active, .claude/super-board/onboard-answers.json,
    │    .claude/super-board/onboard-staged/, .claude/super-board/backup/, .claude/super-board/inflight/
    ├─ settings.json: super-board-settings.py allow … ; protect main →
    │    super-board-settings.py hooks .claude/settings.json <protect-main snippet>
    │    (snippet = the pack's hooks/settings-protect-main.json: PreToolUse Bash →
    │     python3 "$CLAUDE_PROJECT_DIR"/.claude/hooks/guard-protected-push.py)
    ├─ AGENTS.md / CLAUDE.md: super-board-agents-md.py backup, then write --src staged
    │    --dest AGENTS.md, pointer --tail <staged tail> --force, block, check
    ├─ docs/agents/issue-tracker.md, docs/super-board/PROJECT.md
    └─ Then: first tickets (step 10) if accepted; delete onboard-staged/; keep the answers file
       (re-runs use it).

16. SELF-CHECK + SUMMARY — the summary is the ONE place that names the next command.
    "✅ Onboard complete.
     📋 Board: <project URL>
     🧹 Next: run `/super-board lint` — it checks every ticket has clear success criteria.
     🤖 Then: `/super-board run`."
```

---

## AGENTS.md source of truth

Goal: one instruction file every agent reads (AGENTS.md); CLAUDE.md is the single line
`@AGENTS.md` plus any Claude-only rules below it. Use the import, not a symlink and not a
deletion: older Claude Code versions, `CLAUDE.local.md` and some settings only load CLAUDE.md,
and a committed symlink breaks on Windows.

**Deterministic — always via the script** (`.claude/bin/super-board-agents-md.py`):

| Need | Command |
|---|---|
| What exists, pointer or not | `detect` |
| Back up every instruction file first | `backup` → `.claude/super-board/backup/<ts>/` |
| Rule units to map | `units --file AGENTS.md --file CLAUDE.md [--file …]` |
| Lossless gate | `coverage --units mapped.json --target <staged AGENTS.md> --target <staged CLAUDE.md>` |
| Size + markers | `check --file <staged AGENTS.md>` (≤ 200 lines, one marker pair) |
| Write | `write --src <staged> --dest AGENTS.md` (atomic) |
| CLAUDE.md pointer | `pointer --tail <claude-only.md> --force` (only after backup + approval) |
| super-board section | `block` (`--create` when AGENTS.md is new) |

**Semantic — the agent, by these rules:**

1. **Split** every source (AGENTS.md, CLAUDE.md, `@imports` expanded, CLAUDE.local.md,
   .claude/CLAUDE.md) into rule units with `units`.
2. **Classify each unit**:
   - Duplicate (same directive in both) → keep ONE, the more specific wording.
   - Tool-agnostic CLAUDE-only rule → move into the matching AGENTS.md section.
   - Claude-specific (hooks, slash commands, subagents, model choice, Claude tool names) →
     stays in CLAUDE.md below `@AGENTS.md`.
   - Conflict (same subject, different directive — npm vs pnpm) → NEVER auto-resolve. One
     AskUserQuestion per conflict, quoting BOTH lines verbatim, with file:line.
   - Stale (names a path or script that no longer exists) → ask keep or drop.
3. **Every unit maps to a line.** Write `mapped.json` (the `units` output plus `maps_to`: the
   exact target line, or `dropped`: the user's reason) and run `coverage`. Exit 1 → fix before
   showing anything. A unit is gone only when the user dropped it on purpose.
4. **Format** — wording only, meaning unchanged:
   - Sections in order: overview (1 line) · Commands · Where things live · Conventions ·
     Boundaries (Always / Ask first / Never) · super-board block · Commits and PRs.
   - Structured tables wherever rules share a shape; caveman-terse cells (no articles, no
     filler, no "please").
   - Negations explicit and loud: `NEVER`, `DON'T`, `ALWAYS` in caps. NEVER soften a
     prohibition into a suggestion.
   - ≤ 200 lines. Overflow → `docs/agents/<topic>.md` with a one-line pointer in AGENTS.md
     (a pointer, not an `@import` — imports do not cut context cost).
5. **Show** the unit → line mapping and the diff of AGENTS.md and CLAUDE.md;
   [Approve (Recommended) / Change something / Skip the merge]. Nothing is written before
   step 15.

**The super-board section** sits between `<!-- super-board:begin vX.Y.Z … -->` and
`<!-- super-board:end -->`, rendered from `references/agents-md-block.md`. It tells the agent
which super-board skill to use when, the merge/migration rule, the 🙋 tag, and links the ticket
format. Re-install (`install.sh`) and re-onboard rewrite ONLY that block; text outside the
markers is never touched. Re-install also prints a hint when CLAUDE.md is no longer a pointer,
and the next onboard offers the merge again (step 1).

---

## Error recovery during onboard

The user never sees a raw `gh` stack trace — they get a diagnosis and the exact next command.
Every halt says (a) what was tried, (b) what failed, (c) the exact fix, (d) "re-run
`super-board onboard` — your answers are kept and it resumes at <step>".

| Step | Failure | What the user sees |
|---|---|---|
| 2a install | Plugin files not found under ~/.claude/plugins | `🛑 Can't find the super-board plugin files. Run the one-line installer (get.sh) or \`./install.sh <this-dir>\` from a checkout, then re-run onboard.` |
| 2a install | `npx skills add mattpocock/skills` fails (offline, npm missing) | `⚠️ Couldn't install Matt Pocock's skills — lanes fall back to inline checklists. Re-run later: \`npx -y skills@latest add mattpocock/skills --skill '*' -a claude-code -y\`.` Onboard continues. |
| 2 runtime | `super-board-wave.js` missing, no copy to self-heal from | `🛑 Missing .claude/workflows/super-board-wave.js — the dynamic workflow itself. Run \`./install.sh <this-dir>\` from your super-board checkout, then re-run super-board onboard.` |
| 2 runtime | `node --check` fails | `🛑 .claude/workflows/super-board-wave.js is corrupt or truncated. Re-copy it (\`./install.sh <this-dir>\`) — don't hand-edit it.` |
| 4 auth | Not logged in | `🔑 You're not signed in to GitHub. Run: \`gh auth login\` — then re-run super-board onboard.` |
| 4 auth | Scope refused in the browser | `🔑 GitHub asked for project,read:project,repo and you said no. Without them I can't read or move cards. Re-run: \`gh auth refresh -s project,read:project,repo\`.` |
| 5 git | User declined git init | `🛑 A build or QA board needs a git repo (worktrees, branches, merges). Pick "Test a live URL" for a no-repo board, or re-run when ready.` |
| 5 repo create | Quota / permission denied | `📦 GitHub refused to create the repo (org admin required, or the free-repo quota). Options: (a) pick an existing repo, (b) create one in the web UI then re-run, (c) run URL-only.` |
| 7 project create | Org project denied | `🔑 You can't create projects under <org>. Ask an org admin, or use your account: \`gh project create --owner @me\`.` |
| 7 project pick | Deleted between list and pick | `📋 That project was deleted after I listed it. Reloading…` then auto-retry. |
| 8 columns | Read-only project | `🔑 Project is read-only for your account. Get write access, or pick a different project.` |
| 9 AGENTS.md | `coverage` exits 1 | Not shown as an error: fix the mapping, re-run `coverage`, then show the diff. |
| 9 AGENTS.md | Two managed blocks / dangling marker | `✋ AGENTS.md has <n> super-board markers. Leave one begin/end pair (or none) and re-run.` |
| 10 PROJECT.md | Sub-agent timeout / empty draft | `📝 Couldn't auto-draft PROJECT.md. Skip for now, or write one paragraph and I'll seed from that.` |
| 11 base | Rate limit on the protection lookup | Soft-fail detection, warn, ask the question without a production default. |
| 12 protect main | Guard script missing (`--no-hooks` install) | `ℹ️ The push guard isn't installed. Run \`./install.sh --no-hooks --protect-main <this-dir>\` — it installs only that guard. Nothing was wired.` |
| 14 collect | A `ping` returns `unavailable` | `❌ posthog: HTTP 401. Check POSTHOG_PERSONAL_API_KEY (scopes query:read, error_tracking:read), then re-test: \`python3 .claude/skills/super-collect/scripts/collect_posthog.py ping\`.` Source left out; onboard continues. |
| 15 write | File not writable | `🛑 Can't write <path> — check permissions.` Answers kept; re-run resumes at the review screen. |
| 15 write | settings.json invalid JSON | `✋ .claude/settings.json is not valid JSON; I left it untouched. Fix it, then re-run — only the settings step repeats.` |

---

## Re-running onboard

- Step 1 decides: **Keep all — check and repair** (Recommended), **Edit which?** (multiSelect;
  only the picked steps run, everything else kept), or **Start over**.
- An interrupted run resumes at `last_step` from the answers file.
- Variant switches (Full ↔ QA-only) warn that column shape changes.
- A CLAUDE.md that is no longer the `@AGENTS.md` pointer → step 9 is offered again.
- A config with no `timezone` → check and repair adds the machine zone from step 0 (no question).

---

## Worker self-check (mandatory before exit)

Before printing the step-16 summary, verify:

1. **Config file exists and validates** — `.claude/super-board/configs/<slug>.json` parses as
   JSON and has every required field from `config-schema.json` (incl.
   `notifications.bot_identity`; `merge_policy` and `migrations` when a local repo exists).
2. **Active pointer is updated** — `.claude/super-board/active` holds exactly the slug + `\n`.
3. **Project columns are present on GitHub** —
   `gh project field-list <number> --owner <owner>` returns all options for the variant:
   Full `Ready, Building, QA, Review, Done, Blocked, Skipped`; QA-only
   `Ready, QA, Review, Done, Blocked, Skipped`.
4. **PROJECT.md exists** — when `paths.project_md` is non-null, the file exists and is non-empty.
5. **Workflow runtime is installed** — unless `worker_backend` is `"claude-p"`,
   `.claude/workflows/super-board-wave.js` exists and passes the step-2 `node --check`.

Also, when step 9 wrote files: `super-board-agents-md.py check --file AGENTS.md` passes and
`detect` reports CLAUDE.md as a pointer (unless the user chose "Only add the super-board section").

If any check fails, do NOT print the summary: name the failed check and say "re-run
`super-board onboard` — it resumes there". Option D runs these same checks and repairs what it
can before asking anything.
