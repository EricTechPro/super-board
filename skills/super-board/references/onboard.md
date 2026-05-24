# super-board onboard — verb reference

Source of truth: `docs/superpowers/specs/2026-05-21-super-board-design.md` §5
(with §4 config schema and field notes referenced from `config-schema.json`).

This file documents the interactive setup wizard. It is loaded by `SKILL.md`
when the user invokes `super-board onboard …`.

**Where it runs:** current Claude Code session, in user's CWD. Not headless.
**Design rule:** minimize questions. Detect first, ask only what can't be
inferred. Lead with one big "goal" question — it branches the entire flow.

---

## Intro shown when onboard starts

```
super-board onboard
─────────────────────────────────────────────────────────
super-board = a GitHub Project pipeline that runs autonomously.
              It drains issues from Ready across columns
              (Building → QA → Review → Done) until the board
              is empty or only Blocked/Skipped cards remain.

Progress: 🛠 onboard (you are here)  →  🧹 lint  →  🤖 run
─────────────────────────────────────────────────────────
```

---

## Step-by-step logic

```
0. SILENT DETECT (no questions yet)
   ├─ CWD: git repo? any commits? remote URL?
   ├─ Existing configs in .claude/super-board/configs/?
   └─ Existing PROJECT.md?

1. ONE BIG QUESTION — "What do you want to run in a loop?"
   ├─ A) Test a live URL (staging/prod, no code access)
   │       → variant = qa-only, target = url
   ├─ B) Build features for a local repo
   │       → variant = full, target = repo (+ optional URL)
   ├─ C) QA a local repo (already built)
   │       → variant = qa-only, target = repo (+ optional URL)
   └─ D) Use an existing config
           → list configs with descriptions → pick → skip to step 9

2. VERIFY GITHUB AUTH (always)
   ├─ `gh auth status`  — must be authenticated
   ├─ Scope check: `project`, `read:project`, `repo`
   ├─ If missing → `gh auth refresh -s project,read:project,repo`
   └─ Tell user WHY: "needed to move cards on your board and create
       projects on your behalf"

3. ENFORCE LOCAL GIT REPO (mandatory)
   ├─ If CWD is not a git repo → "I need to init git before continuing. Proceed? [y/n]"
   ├─ If no remote on local repo and user picked B or C with `push`/`pr`/`merge` authority later
   │     → offer `gh repo create`
   └─ Reason: version control is required to manage worktrees, branches, and merges.

4. RESOLVE TARGET (branches by Q1 answer)
   ├─ A (URL only): ask for the URL → save target.url. Repo = null.
   ├─ B (build local repo):
   │    ├─ Auto-detect remote. Offer `gh repo create` if missing.
   │    ├─ No commits? Offer "scaffold from template? [NestJS / Next.js / Vite / blank]"
   │    └─ Save repo = {path, remote_or_null}. Optionally also save target.url.
   └─ C (QA local repo): auto-detect repo. Ask only for target URL if any.

5. PICK OR CREATE GITHUB PROJECT
   ├─ List existing projects under repo owner (or user's account if no repo)
   ├─ If picked → validate column shape matches variant (fix if not)
   └─ If new → `gh project create --title <name>` → create columns for variant

6. VALIDATE / CREATE COLUMNS (idempotent)
   ├─ Full variant (7 total):    Ready · Building · QA · Review · Done · Blocked · Skipped
   ├─ QA-only variant (6 total): Ready ·            QA · Review · Done · Blocked · Skipped
   └─ Read Status field, add missing options, re-read to confirm.

7. AUTO-GENERATE PROJECT.md (skip if URL-only or user opts out)
   ├─ Spawn sub-agent: read whichever manifest set exists + README + top-level structure:
   │    • Node:    package.json
   │    • Python:  pyproject.toml or requirements.txt
   │    • Rust:    Cargo.toml
   │    • Go:      go.mod
   │    • Ruby:    Gemfile
   │    • Other:   no manifest found → ask user one question:
   │              "What does this project do? (one short paragraph)"
   │              Use the answer verbatim as the seed for PROJECT.md.
   │    → draft PROJECT.md (what the app is, stack, conventions, success criteria)
   ├─ Show draft → user confirms/edits inline
   └─ Save to docs/super-board/PROJECT.md

8. PICK BASE BRANCH (Full variant with local repo, OR QA-only with a local repo)
   (Skip entirely only when target.type == "url" with no repo.)
   ├─ Detect current branch + remote default branch
   ├─ Production-detection (any of these signals → treat as production):
   │    • `.github/workflows/*.yml` contains `deploy` job triggered on push to base
   │    • `vercel.json` / `netlify.toml` present at repo root
   │    • Branch protection rules require PR review on base (gh api repos/.../branches/<base>/protection)
   │    • README contains "production" or live URL on the base branch
   ├─ Ask: "Which branch should super-board cut feature branches from
   │        and squash-merge them back into?"
   ├─ Default: main (unless production-detected, then default to creating `staging`)
   └─ ⚠️ WARN if base looks production-y (any signal above fires):
       "Heads up — using main means every merged ticket lands in
        production. Consider a staging or develop branch instead.
        Want me to create one?"

9. MERGE POLICY (Full variant with local repo, OR QA-only with a local repo)
   (Tester commits test files to the same branch; merge policy applies.
   Skip only when target.type == "url" with no repo.)
   ├─ "Should super-board auto-merge approved PRs into base, or wait
   │   for a human to click merge? [auto / human]"
   ├─ Sets config.human_approves_merge accordingly.
   └─ HARD RULE: if base_branch was production-detected (step 8) AND user
       did NOT switch to staging/develop, force human_approves_merge = true
       and tell the user: "Auto-merge to production is disabled. Approved
       PRs will be marked ready for review; you click merge."

10. RECORD NOTIFICATION CHANNEL
    └─ Auto-detect from the current session; allow override.

11. WRITE CONFIG + ACTIVE POINTER
    ├─ Generate `description` (short, scannable)
    ├─ Record notifications.bot_identity — either `super-board-bot[bot]`
    │  (when a GitHub App is installed on the repo) or the user's own
    │  GitHub login (solo projects). Pick during step 2 based on what
    │  `gh auth status` returned.
    ├─ Write .claude/super-board/configs/<slug>.json (committed)
    └─ Write .claude/super-board/active ← <slug> (gitignored)

12. SUMMARY
    "✅ Onboard complete.
     📋 Go write your tickets here: <project URL>
     🧹 Then run `super-board lint` to make sure each issue has clear
        success criteria."
```

---

## Error recovery during onboard

Every onboard step that touches GitHub or the filesystem has a defined recovery path. The user never gets a raw `gh` stack trace — they get a friendly diagnosis and the exact next command.

| Step | Failure mode | What the user sees |
|---|---|---|
| 2. gh auth | Not logged in | `🔑 You're not signed in to GitHub. Run: \`gh auth login\` — then re-run super-board onboard.` |
| 2. gh auth | Scope refused (user said no on browser) | `🔑 GitHub asked for project,read:project,repo scopes and you said no. Without them I can't read or move project cards. Re-run: \`gh auth refresh -s project,read:project,repo\`.` |
| 3. git init | User declined | Halt with: `🛑 super-board needs a git repo. Re-run when ready.` |
| 4. gh repo create | Quota/perm denied | `📦 GitHub refused to create the repo (org admin required, or you hit your free-repo quota). Options: (a) pick an existing repo, (b) create one in the web UI then re-run, (c) skip repo and run URL-only.` |
| 5. gh project create | Org project denied | `🔑 You don't have permission to create projects under <org>. Either ask an org admin, or pick your personal account: \`gh project create --owner @me\`.` |
| 5. gh project pick | Project deleted between list + pick | `📋 That project was deleted after I listed it. Reloading…` then auto-retry. |
| 6. column create | Column add denied (read-only project) | `🔑 Project is read-only for your account. Either get write access, or pick a different project.` |
| 7. PROJECT.md autogen | Sub-agent timeout / empty draft | `📝 Couldn't auto-draft PROJECT.md. Skip for now, or write one paragraph and I'll seed from that.` |
| 8. base branch | gh API rate limit on protection-rule lookup | Soft-fail production detection, warn the user, fall back to asking. Do not halt. |
| 11. write config | File system not writable | Halt with the exact path: `🛑 Can't write to .claude/super-board/configs/<slug>.json — check permissions.` |

Every onboard halt comment includes (a) what the bot tried, (b) what failed, (c) the exact command or click the user can do, (d) how to resume (always: "re-run `super-board onboard`").

---

## Re-running onboard

- Detects existing active config → "Reconfigure? [y/n]"
- If yes: walks the same steps, defaults to current values.
- Variant switches (Full ↔ QA-only) warn that column shape changes.

---

## Worker self-check (mandatory before exit)

Before exiting `onboard` successfully, the worker MUST verify:

1. **Config file exists and validates** — `.claude/super-board/configs/<slug>.json`
   parses as JSON and contains every required field from `references/config-schema.json`
   (including `notifications.bot_identity`).
2. **Active pointer is updated** — `.claude/super-board/active` is a one-line
   file containing exactly the new slug, no trailing whitespace beyond a single `\n`.
3. **Project columns are present on GitHub** — running
   `gh project field-list <project.number> --owner <project.owner>` returns all
   required column options for the chosen variant:
   - Full: `Ready, Building, QA, Review, Done, Blocked, Skipped`
   - QA-only: `Ready, QA, Review, Done, Blocked, Skipped`
4. **PROJECT.md exists** — when `paths.project_md` is non-null (i.e. any flow with
   a local repo), the file at that path exists and is non-empty.

If any of these four checks fail, do NOT print the step-12 summary. Instead, surface
the specific failed check and tell the user to re-run `super-board onboard`. A
partial config is worse than no config — the lint and run verbs depend on these
invariants.
