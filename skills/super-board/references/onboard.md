# super-board onboard — verb reference

Config schema and field notes: `config-schema.json`. Loaded by `SKILL.md` for `super-board onboard`.

**Where it runs:** the current Claude Code session, in the user's folder. Not headless.
Invoked as `/super-board onboard` (get.sh / install.sh) or `/super-board:super-board onboard`
(plugin install — skill names carry the plugin prefix).

## Design rules

| Rule | How |
|---|---|
| Wizard | 8 numbered steps. Each opens with the agenda strip and `N of 8 · <emoji> <Name> — <one short why>`, then one `AskUserQuestion` |
| Minimal text | what it found in one line, then the question. Details go in an option's description or one dim line under it — never a paragraph |
| Recommended first | every question puts its recommended option FIRST, labelled `(Recommended)`, so Enter takes it |
| One tool | ask with `AskUserQuestion` (≤ 4 questions per call, ≤ 4 options per question; the built-in "Other" box is the free-text option). NEVER free-text a choice that has options |
| Fix, don't ask | a must-have (skills, scripts, workflows, guard hooks, settings entries, old folders, config keys, labels, columns) is fixed with NO question and listed under "Fixed for you". Only system tools and sign-ins are asked — through Claude Code's own permission prompt on the exact command |
| Save as you go | every answer is written to `.claude/super-board/onboard-answers.json` the moment it is given |
| Write once | files in the repo (config, settings.json allow lines, AGENTS.md, CLAUDE.md, docs) change only at step 8, after "Write everything". GitHub-side actions the user just picked (create or extend the board, create `staging`) run in their own step |
| Secrets | NEVER read, grep, cat or source a dotenv file. Key names only, via `.claude/bin/super-board-env-check.sh` |

**Scripts.** `SB=.claude/bin` after an install. Plugin install before step 1 has run: the plugin's
own copy, `PACK=$(dirname "$(find ~/.claude/plugins -path '*super-board*' -name install.sh -not -path
'*/node_modules/*' 2>/dev/null | head -1)")`, `SB=$PACK/scripts`. `$PACK` empty → `🛑 Can't find the
super-board plugin files. Run the one-line installer (get.sh) or ./install.sh <this-dir> from a
checkout, then re-run onboard.`

| Script | Used in |
|---|---|
| `python3 $SB/super-board-setup.py check / fix --text` | 1 Checks |
| `python3 $SB/super-board-setup.py board-rank / board-migrate / names` | 1 (upgrade), 3 Board |
| `python3 $SB/super-board-setup.py branch` | 4 Branch |
| `python3 $SB/super-board-agents-md.py …` | 5 AGENTS.md |
| `python3 $SB/super-board-settings.py allow … --dry-run` | 6 Policies |
| `python3 .claude/skills/super-collect/scripts/collect_custom.py classify / ping / add` | 7 Bug sources |

---

## Screens

**Start** (after the skill loads; nothing asked yet):

```
⏺ super-board setup — 8 steps. Enter takes the recommended answer.
  1 🔍 Checks       install or update what the board needs
  2 🔑 GitHub       sign in so I can manage boards
  3 🗂️ Board        pick or create your project board
  4 🌿 Branch       choose where finished work merges
  5 📜 AGENTS.md    move your rules into one file
  6 🛡️ Policies     what the robot may do alone
  7 📥 Bug sources  where to find problems to fix
  8 ✅ Review       check every answer, then save once
  Stop any time; re-run continues. Live site only? /super-qa <url>.
```

**Agenda strip** — first line of every step, done steps ticked, the current one bold:

```
✓ 1 Checks · ✓ 2 GitHub · 3 Board · 4 Branch · 5 AGENTS.md · 6 Policies · 7 Bug sources · 8 Review
⏺ 3 of 8 · 🗂️ Board — the robot takes tickets from here.
```

| # | Header line |
|---|---|
| 1 | `1 of 8 · 🔍 Checks — install or update what the board needs.` |
| 2 | `2 of 8 · 🔑 GitHub — sign in so I can manage boards.` |
| 3 | `3 of 8 · 🗂️ Board — the robot takes tickets from here.` |
| 4 | `4 of 8 · 🌿 Branch — where finished work merges.` |
| 5 | `5 of 8 · 📜 AGENTS.md — Claude reads AGENTS.md; CLAUDE.md becomes "@AGENTS.md".` |
| 6 | `6 of 8 · 🛡️ Policies — what the robot may do alone.` |
| 7 | `7 of 8 · 📥 Bug sources — where to find problems to fix.` |
| 8 | `8 of 8 · ✅ Review — nothing is written until you say so.` |

**Resume** — an answers file with `last_step` and no finished config. Saved answers first, then
the question:

```
⏺ Bash(cat .claude/super-board/onboard-answers.json)
  ⎿  saved 2 Oct, 18:40 · stopped at Policies & permissions
⏺ 💾 Found your answers from last time:
  ✓ GitHub: erictech        ✓ board: Ledgerly Roadmap
  ✓ base: staging           ✓ AGENTS.md: merged
  → stopped at 🛡️ Policies & permissions
```

AskUserQuestion "Continue where you left off?" [Continue at <step> (Recommended) / Edit an earlier
answer — pick which on the next screen / Start over — saved answers are renamed .bak]. Step 1
Checks always runs again first, silently unless it fixes something.

**Re-run on a finished setup** (config exists, nothing interrupted): show the current values in
the step-8 table, then "Onboard found an existing setup. What now?" [Keep all — check and repair
(Recommended) / Edit an earlier answer / Start over]. Keep all = step 1, the board repair of step 3
(`board-migrate`, no question), the step-7 pings, the self-check. A CLAUDE.md that is no longer the
`@AGENTS.md` pointer → step 5 is offered even under Keep all.

---

## The answers file

`.claude/super-board/onboard-answers.json` (gitignored — step 8 adds it):

```json
{ "version": 2, "updated": "<iso>", "last_step": "policies",
  "answers": { "github": {"login": "erictech", "remote": "github.com/erictech/my-app"},
               "board": {"owner": "erictech", "number": 4, "title": "Ledgerly Roadmap", "reused": true},
               "base_branch": "staging", "agents": "merged",
               "policies": {"merge_default": "auto", "protect_main": true, "allowed_envs": ["test", "staging"]},
               "permissions": "add", "collect": ["sentry", "github", "prs", "architecture", "linear"],
               "custom": [{"name": "linear", "kind": "mcp", "target": "linear"}] } }
```

Write it atomically (temp file + rename) after every answer. A halt never loses work.

---

## Step by step

```
0. SILENT DETECT (no questions, nothing printed but the start screen)
   ├─ answers file, .claude/super-board/configs/*.json → resume / re-run screens
   ├─ instruction files: python3 $SB/super-board-agents-md.py detect
   ├─ manifests + README (board names), branches + deploy signals ($SB/super-board-setup.py branch)
   ├─ migration dirs (supabase/migrations, prisma/migrations, drizzle, **/migrations/*.sql,
   │    db/migrate, alembic/versions) and migrate scripts in the manifest (db:migrate, …)
   ├─ collect signals: Sentry (@sentry/* / sentry-sdk in manifests, Sentry.init(, .sentryclirc),
   │    PostHog (posthog-js / posthog-node / posthog, posthog.init(, NEXT_PUBLIC_POSTHOG_* names);
   │    key names: bash $SB/super-board-env-check.sh SENTRY_AUTH_TOKEN POSTHOG_PERSONAL_API_KEY
   └─ machine time zone for config `timezone`: $TZ, else readlink /etc/localtime | sed
      's#.*zoneinfo/##', else timedatectl show -p Timezone --value, else "UTC". Shown at step 8.

1. 🔍 CHECKS — nothing asked except system tools and sign-ins
   ├─ python3 $SB/super-board-setup.py fix --text
   │    Fixes with NO question, backed up first to .claude/super-board/backup/<ts>/:
   │    skills, .claude/bin scripts, workflows, guard hooks + settings.json entries (runs the
   │    pack's install.sh), removes old skill folders (super-refine, cleanup-wt, arch-loop),
   │    migrates every config to the v3 keys, git init, Matt Pocock's helper skills (Node present).
   ├─ Print its list exactly, one ✓ per line:
   │      ⏺ Fixed for you:
   │        ✓ super-board skills and scripts installed
   │        ✓ board engine (workflow) installed
   │        ✓ 6 safety guards switched on
   │        ✓ settings.json entries added (backup kept)
   │        ✓ git repo found
   ├─ Each `needs` item (a system tool): one line, then run its `command` with Bash — Claude
   │    Code's permission prompt IS the question. No AskUserQuestion.
   │      Needs your machine: Node.js isn't installed. It's needed for Matt Pocock's coding
   │      skills (tests, code review, debugging) the board uses.
   │      → Bash(brew install node && npx -y skills@latest add mattpocock/skills)
   │    The command is per OS (brew / apt / dnf / winget) and comes from the script.
   │    Declined: node → the board runs with built-in checklists instead (say so, continue);
   │    git or gh → halt: "Without <tool> the board can't <why>. Your answers are saved — run
   │    the command, then re-run onboard."
   ├─ Re-check (`check --text`) after every install; move on only when it says all green.
   ├─ Workflow runtime: syntax-check the installed workflow (same command run.md uses):
   │      { echo '(async function(){'; sed 's/^export const meta/const meta/' \
   │        .claude/workflows/super-board-wave.js; echo '})'; } | node --check --input-type=module
   │    Fails → fix re-copies it; still failing → 🛑 (error table). Remind once: dynamic
   │    workflows must be ON in /config.
   └─ OLDER SUPER-BOARD (the result says `upgraded: true`): same rule, no question. Header
      `1 of 8 · 🔍 Checks — found super-board v<from>; upgrading to v<pack>.` and the list:
          ⏺ Upgraded for you (backup: .claude/super-board/backup/<ts>/)
            ✓ skills updated; added super-collect, visual, git-sync, ui-refine-loop
            ✓ removed old folders: super-refine, cleanup-wt, arch-loop
            ✓ scripts, board engine and safety guards updated
            ✓ config moved to the new keys (merge rule, migrations, sources)
            ✓ labels mapped: build→feature · bug-fix→bug · qa-only→qa (14)
            ✓ Skipped column: 4 cards moved to Done, column removed
            ✓ re-checked: all green
          Your CLAUDE.md still has its own rules — step 5 offers to move them.
      The two board lines come from `python3 $SB/super-board-setup.py board-migrate --config
      <config>` — run it here when `gh auth status` already has the project scope, else in
      step 3 (it then prints them there). It adds missing columns, creates qa · bug · feature,
      maps old labels, labels every card `qa` on a board that was "qa-only", moves Skipped
      cards to Done, removes Skipped and restores any status the change cleared. Keep the board
      idle during this operation. The helper saves every card/status and label conversion plan
      in `.claude/super-board/migrations/` before writing to GitHub. A failed upgrade is not a
      completed setup: keep the recovery file and re-run the same command from the same project
      root (or with the same `--root`). It resumes the saved plan and verifies remote results;
      it never takes a new snapshot over a partially upgraded board. No extra setup question.

2. 🔑 GITHUB
   ├─ Bash(gh auth status). Signed in with project scopes → `✓ GitHub connected.`; continue below.
   ├─ Not signed in → one line, then Bash(gh auth login) — the permission prompt asks.
   ├─ Missing scopes → "This opens a browser to approve board access — needed to move cards and
   │    create the board for you." then Bash(gh auth refresh -s project,read:project,repo)
   ├─ Bash(git remote get-url origin). No remote → AskUserQuestion "This project isn't on GitHub
   │    yet. Create a repo?" [Create a private repo (Recommended) / Use an existing repo /
   │    Not now — the robot can't open pull requests]. Create → gh repo create <login>/<folder>
   │    --private --source . --remote origin
   ├─ Second account (AskUserQuestion, header "Robot account"); explain in four short lines:
   │      The robot's gh issue, gh pr and gh project GraphQL calls share your 5,000 points/hr.
   │      Finfluencer (2026-10-03/04): 3 cards cost ~2,850 (~950/card); 14 used all 5,000 in ~40 min.
   │      Board moves then failed; nearly every wave left the board idle for up to an hour.
   │      Your browsing and tools share that budget. A bot gets its own 5,000 points/hr.
   │    "Want a second GitHub account for the robot? It gives the board its own hourly budget,
   │    so it can run more cards before pausing. Takes about 10 minutes."
   │      • Yes, set it up now (Recommended)
   │      • Not now — stay on my account; waves pause when the hourly limit runs out
   │    Save the choice with the GitHub answers. Yes → follow references/second-account.md;
   │    keep the owner active through step 3, then finish bot access before step 4. Keep the
   │    repo/project owner unchanged. Already on a verified bot → keep it; don't create another.
   └─ bot_identity: new board with a machine account → bot username; existing board → keep its
      configured claim identity. Otherwise `super-board-bot[bot]` when a GitHub App is installed
      on the repo, else the login. Stage `notifications.bot_identity` for step 8; see second-account.md.

3. 🗂️ BOARD — one question: which board
   ├─ One checklist line, one labels line, no question about either:
   │      Columns: ✓ Backlog ✓ Ready ✓ Building ✓ QA ✓ Review ✓ Blocked ✓ Done
   │      Labels: feature · bug · qa (qa skips Building; no label = feature)
   ├─ python3 $SB/super-board-setup.py board-rank --owner <owner>   (boards ranked by matching
   │    columns; `recommend` = the best with ≥ 4 of 7)
   │  python3 $SB/super-board-setup.py names                         (two names from
   │    package.json / README / folder)
   ├─ AskUserQuestion "Which board?" (header "Board"):
   │    • Use <title> (#<n>) — <m> of 7 columns match, I'll add <missing> (Recommended)
   │        description: its URL (github.com/users/<owner>/projects/<n>)
   │    • Create a new board named "<names[0]>"       (Recommended when nothing is recommended)
   │    • Create a new board named "<names[1]>"
   │    "Other" = Type a name.
   ├─ Reuse → board-migrate --owner <o> --number <n> --repo <owner/repo>: adds the missing
   │    columns, the three labels, keeps every card. Prints `<title> ready`.
   └─ New → gh project create --owner <o> --title "<name>", link it to the repo, then
      board-migrate --prune-empty on it (the seven columns replace GitHub's default Todo /
      In Progress; labels). Prints its URL.
   There is no "Needs you" column and no Skipped column: a card waiting on a person goes to
   Blocked with 🙋 (block-template.md); a card dropped on purpose is closed and moved to Done.
   Second account chosen in step 2 → finish references/second-account.md now; verify bot access.

4. 🌿 BRANCH
   ├─ python3 $SB/super-board-setup.py branch → one line:
   │      Found: main (deploys to production via Vercel), no staging.
   ├─ AskUserQuestion "Where should finished work merge?" (header "Branch"):
   │    no staging:   • Create staging from main (Recommended) — "nothing goes live until you
   │                    move it to main" (or "keeps main clean" with no deploy signal)
   │                  • main — every merge goes live (or just "main" with no deploy signal)
   │    staging found: • staging (Recommended) — already exists · • main — every merge goes live
   ├─ Create staging → Bash(git push origin main:staging) right away (the pick is the OK).
   └─ main kept with a deploy signal → step 6 defaults to "you merge everything", target_env "live".

5. 📜 AGENTS.md — one line, one question; one short question per conflict
   ├─ detect says CLAUDE.md is already the pointer → `✓ Already done — CLAUDE.md is "@AGENTS.md".`
   ├─ No instruction files → "Create AGENTS.md for your project rules?" [Yes (Recommended) —
   │    CLAUDE.md becomes "@AGENTS.md" / Skip]
   ├─ Otherwise N = rule units in CLAUDE.md (`units --file CLAUDE.md`):
   │    AskUserQuestion "Move your N CLAUDE.md rules into AGENTS.md?" (header "AGENTS.md")
   │      • Yes, move them (Recommended) — backup first, diff before saving
   │      • Only add the super-board section
   │      • Skip
   ├─ Yes → draft the merge into onboard-staged/ by the rules below. Each conflict = its own
   │    AskUserQuestion, header "Conflict k of n", question "<Subject>: which rule wins?",
   │    options quoting BOTH lines verbatim with file:line, the more specific one Recommended.
   │    Then one tool line: Bash(super-board-agents-md.py coverage && check) ⎿ 31/31 rules kept ·
   │    118 lines. Written at step 8.
   ├─ Only the section → stage `block --create`; a CLAUDE.md alone gets `@AGENTS.md` prepended.
   └─ Writing standard, always, no question: stage docs/agents/issue-tracker.md with a
      `## Ticket format` section from references/ticket-format.md (create, or replace only that
      section). The block's "Writing (super-board)" table links it and writing-standard.md.

6. 🛡️ POLICIES — ONE AskUserQuestion call, two questions; details folded
   Q1 header "Rules", "Use the safe defaults?"
      • Yes (Recommended) — description: "robot merges normal changes · money/logins/DB wait for
        you · no pushes to main · migrate test + staging only"
        (production base kept: "you merge everything (main goes live) · no pushes to main ·
        migrate test + staging")
      • Review each
   Q2 header "Permissions", "Let it run its commands without asking each time?"
      • Yes, add <N> lines to settings.json (Recommended)
      • No, ask me each time
   Folded details = ONE dim line under each, never a table:
      merge_policy.default auto · always_human: money, auth, schema · push guard on (main, master,
      <base>) · migrations.allowed_envs: test, staging
      + Bash(gh project:*) + Bash(gh issue:*) + Bash(gh pr:*) + … (the --dry-run output, joined)
   Review each → ONE more AskUserQuestion call, up to three questions:
    a. "Merge" — "Who merges a change that passes review?" [Robot merges normal changes
       (Recommended) / I merge everything]; production base: the order flips, and robot-merges
       sets merge_policy.allow_auto_on_production: true (run.md's guard needs it).
       → merge_policy.default "auto" | "human"; auto_max_lines 400 (lockfiles, generated,
         snapshots, migration SQL not counted); always_human = schema defaults (money, auth,
         destructive schema). A matching PR parks in Blocked with 🙋.
    b. "Push guard" — "Block pushing straight to main?" [Yes (Recommended for a repo with
       commits) / No]. Skipped when settings.json already wires guard-protected-push.py. Script
       missing (--no-hooks install) → record the answer and say: "Run ./install.sh --no-hooks
       --protect-main <this-dir> — it installs only this guard."
    c. "Databases" (multiSelect, only when migration dirs exist) — "Which databases may the robot
       migrate?" [test (Recommended) / staging (Recommended) / live] → migrations.allowed_envs;
       target_env "live" on a production base, else "staging"; commands from the manifest's
       migrate scripts (ask only for a missing one). A command needing a DB URL resolves it
       from the project's `.env` by absolute path, never from the session, since a lane agent's
       shell loads nothing (config-schema → `migrations.commands`). Write a matching read-only
       `migrations.checks[env]` (e.g. `supabase migration list --db-url …`) and run it now; a
       failure is fixed here, not discovered at the first merge. For Supabase the URL is the
       Session pooler string (port 5432) with special characters in the password URL-encoded,
       and a just-reset password takes ~20 s to reach the pooler — retry once before calling it wrong.
   Permission lines: the base list in run-workflow.md → "Mid-run permission prompts", plus the
   merge lines when merge_policy.default is "auto" ("Bash(bash .claude/bin/super-board-merge-gate.sh:*)",
   "Bash(gh pr merge:*)"), one "Bash(<migrate command>)" per allowed env, "Bash(bash
   .claude/bin/super-board-env-check.sh:*)" and the test runner. N counts what is NOT already in
   settings.json: `super-board-settings.py allow .claude/settings.json <rules…> --dry-run`.

7. 📥 BUG SOURCES — tick sources; "Add another source" is the free-text box
   ├─ AskUserQuestion multiSelect "Where should I look for problems?" (header "Bug sources"):
   │    Sentry — app errors (Recommended when detected) · PostHog — rage clicks, errors, slow pages
   │    (Recommended when detected) · GitHub issues — bugs filed but not on the board · Past PRs —
   │    review comments that keep repeating · Architecture — tangled or duplicated code.
   │    Undetected Sentry / PostHog are left out. More than 4 options → split into two questions
   │    in the same call ("Error sources", "Code sources") — the tool takes 4 per question.
   │    "Other" = ➕ Add another source (link, app, API URL, MCP or command).
   ├─ Built-ins: ask only what detection missed (Sentry org/project/host, PostHog host/project_id).
   │    Missing key → the exact .env line to add (name only) + scopes: Sentry `event:read
   │    project:read`; PostHog personal key `query:read error_tracking:read`. PostHog failure
   │    events: grep capture() calls for *_failed / *_error, propose them, user confirms.
   ├─ ➕ typed text → C=.claude/skills/super-collect/scripts/collect_custom.py
   │    python3 $C classify "<text>" → kind mcp | http | cli (an app name resolves to one)
   │    python3 $C ping --kind <k> --target <t> [--auth-env <E>] --name <n>   (read-only)
   │      mcp → status "agent": call that server's read/list tool yourself, limit 1, read-only;
   │            pipe its JSON into `$C normalize --name <n>` to count what it returned.
   │    ✅ → `$C add … --config <staged config>` (collect.custom[] + collect.sources).
   │    ❌ → say why in one line (401 → the token name to add to .env); never saved; re-test by
   │         typing it again.
   ├─ Ping each built-in, read-only, before step 8:
   │      python3 .claude/skills/super-collect/scripts/collect_sentry.py  --config <staged> ping
   │      python3 .claude/skills/super-collect/scripts/collect_posthog.py --config <staged> ping
   │      gh api graphql -f query='{viewer{login}}'          (github, prs)
   └─ One result block, one line per source; a failure leaves that source out, never halts:
          ✅ linear — can read issues (12 open bugs); saved in this project's config
          ✅ sentry · github · prs · architecture
          ❌ posthog — key missing: add POSTHOG_PERSONAL_API_KEY to .env (left out)

8. ✅ REVIEW — compact table, then write once
   ├─ Two columns, no borders:
   │      Board    Ledgerly Roadmap #4 (+QA)    Branch   staging (new)
   │      Rules    safe defaults                Perms    7 lines
   │      AGENTS   rules moved, CLAUDE.md→@     Sources  sentry, github, prs, arch, linear
   ├─ AskUserQuestion "Write everything?" (header "Save") [Write everything (Recommended) /
   │    Change one thing → pick the step, walk only it, back here / Cancel — nothing written].
   ├─ Write, in order (each atomic; stop and report on the first failure — answers are kept):
   │    ├─ .claude/super-board/configs/<slug>.json (committed): description, project, target
   │    │    {type: repo | repo+url}, repo, base_branch, timezone, columns (the seven), labels,
   │    │    paths, merge_policy, migrations, collect (incl. custom), notifications {channel:
   │    │    "session", bot_identity}, worker_backend "workflow". No `variant`.
   │    ├─ .claude/super-board/active ← <slug>
   │    ├─ .gitignore += .claude/super-board/active, onboard-answers.json, onboard-staged/,
   │    │    backup/, inflight/, migrations/, upgrade.json (all under .claude/super-board/)
   │    ├─ settings.json: super-board-settings.py allow … ; protect main →
   │    │    super-board-settings.py hooks .claude/settings.json <pack>/hooks/settings-protect-main.json
   │    ├─ AGENTS.md / CLAUDE.md: super-board-agents-md.py backup, then write --src <staged>
   │    │    --dest AGENTS.md, pointer --tail <staged tail> --force, block, check
   │    └─ docs/agents/issue-tracker.md; docs/super-board/PROJECT.md (a sub-agent drafts it from
   │       manifests + README + tree, no question; listed in the table as "PROJECT.md drafted")
   └─ Delete onboard-staged/; keep the answers file (re-runs use it).

DONE — self-check, then the ONE place that names the next command:
      ⏺ Bash(self-check)  ⎿  all good
      ⏺ 🎉 Onboard complete.
        📋 Board: github.com/users/<owner>/projects/<n> (<title>)
        🧹 Next: /super-board lint — checks every ticket has clear success criteria.
        🤖 Then: /super-board run.
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
5. **Show** the diff of AGENTS.md and CLAUDE.md folded under the coverage line; the step-8
   "Write everything" is the approval. Nothing is written before step 8.

**The super-board section** sits between `<!-- super-board:begin vX.Y.Z … -->` and
`<!-- super-board:end -->`, rendered from `references/agents-md-block.md`. Re-install and
re-onboard rewrite ONLY that block; text outside the markers is never touched.

---

## Error recovery during onboard

The user never sees a raw stack trace — they get a diagnosis and the exact next command. Every
halt says what was tried, what failed, the exact fix, and "re-run `/super-board onboard` — your
answers are kept and it resumes at <step>".

| Step | Failure | What the user sees |
|---|---|---|
| 1 | Pack files not found (plugin) | `🛑 Can't find the super-board plugin files. Run the one-line installer (get.sh) or ./install.sh <this-dir> from a checkout, then re-run onboard.` |
| 1 | A tool install declined (git, gh) | `Without <tool> the board can't <why>. Your answers are saved — run <command>, then re-run onboard.` |
| 1 | Node declined, or `npx skills add` fails | `⚠️ Matt Pocock's skills aren't installed — lanes use built-in checklists. Later: <command>.` Continues. |
| 1 | Workflow still fails `node --check` after the re-copy | `🛑 .claude/workflows/super-board-wave.js is corrupt. Re-run ./install.sh <this-dir> — don't hand-edit it.` |
| 1 | settings.json invalid JSON | `✋ .claude/settings.json is not valid JSON; I left it untouched. Fix it, then re-run — only the settings entries repeat.` |
| 2 | Scope refused in the browser | `🔑 GitHub asked for project,read:project,repo and you said no. Without them I can't read or move cards. Re-run: gh auth refresh -s project,read:project,repo.` |
| 2 | Repo create refused | `📦 GitHub refused to create the repo (org admin required, or the free-repo quota). Pick an existing repo, or create one in the web UI, then re-run.` |
| 3 | Org project denied | `🔑 You can't create projects under <org>. Ask an org admin, or use your account: gh project create --owner @me.` |
| 3 | Board read-only | `🔑 That board is read-only for your account. Get write access, or pick another.` |
| 3 | board-migrate exits 2 | Show its `error` and recovery-file path. Some changes may already be applied. Keep the board stopped and the recovery file; fix the access/read/write failure, then re-run the same command from the same project root. A concurrent-edit conflict needs review of the saved original/desired state; never delete the record to bypass it. |
| 4 | `git push origin main:staging` rejected | `🌿 Couldn't create staging (<reason>). Create it on GitHub, or pick main.` |
| 5 | `coverage` exits 1 | Not an error: fix the mapping, re-run `coverage`, then show the result. |
| 5 | Two managed blocks / dangling marker | `✋ AGENTS.md has <n> super-board markers. Leave one begin/end pair (or none) and re-run.` |
| 7 | A ping fails | One ❌ line with the reason and what to add; the source is left out; onboard continues. |
| 8 | File not writable | `🛑 Can't write <path> — check permissions.` Answers kept; re-run resumes at Review. |

---

### Upgrade recovery limits

The recovery file is durable before any GitHub write, records verified progress, and is retained
on failure. Full cursor pagination covers boards beyond 500 cards; missing/partial pages block
writes. A lost mutation response is checked against GitHub before an operation can repeat.
Completed records retain the latest snapshot until a later, fully snapshotted migration replaces
them. The local OS lock releases automatically on a crash; run upgrades from one project root.

New nonempty task statuses and edits after a verified restore are preserved. Changed options,
labels, or conflicting unfinished restores halt for review. Deleted cards are never recreated.
GitHub cannot atomically compare a read with a field rewrite: edits made in that narrow interval,
or an intentional clear before the first post-rewrite observation, cannot always be distinguished
from the rewrite clearing a status. **Keep workers and people from editing this board during its
upgrade.** This is resumable recovery, not a promise of an atomic rollback. Do not hand-edit or
remove a pending recovery record; use its saved state to reconcile a conflict before retrying.

## Worker self-check (mandatory before the 🎉 screen)

1. **Config validates** — `.claude/super-board/configs/<slug>.json` parses, has every required
   field from `config-schema.json` (incl. `notifications.bot_identity`, `merge_policy`,
   `migrations`), has no `variant`, and `columns` is the seven.
2. **Active pointer** — `.claude/super-board/active` holds exactly the slug + `\n`.
3. **Board columns and labels** — `gh project field-list <n> --owner <o>` returns Backlog, Ready,
   Building, QA, Review, Blocked, Done (no Skipped); `gh label list` has qa, bug, feature.
4. **Setup green** — `python3 .claude/bin/super-board-setup.py check` exits 0 (or only `needs`
   the user declined).
5. **Workflow runtime** — unless `worker_backend` is `"claude-p"`, the step-1 `node --check` passes.

When step 5 wrote files: `super-board-agents-md.py check --file AGENTS.md` passes and `detect`
reports CLAUDE.md as a pointer (unless "Only add the super-board section"). Any check fails →
no 🎉: name the failed check and say "re-run `/super-board onboard` — it resumes there".
