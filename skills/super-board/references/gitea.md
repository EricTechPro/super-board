# gitea.md — running super-board against Gitea

One page for every lane and script that talks to a forge. A board is Gitea when its
config (`.claude/super-board/configs/<slug>.json`) sets `"forge": "gitea"` (+ `forge_host`,
optional `forge_login`), or the environment says `SB_FORGE=gitea`. Absent both, the board is
GitHub and nothing on this page applies. Resolution order everywhere: **env → config → git
remote (advisory) → github** (`super-board-forge.py`).

Everything goes through the **tea CLI (v0.16.x pinned semantics)**: native commands where they
exist, `tea api` for the REST surface. Auth: `tea login add --name <slug> --url <host> --token`
(interactive) or `GITEA_TOKEN` + `TEA_HOST` (CI, never persisted). `SB_GITEA_TEA` overrides the
executable (tests point it at `evals/_stubs/bin/tea`).

## Model mapping

| GitHub | Gitea | Notes |
|---|---|---|
| Projects v2 board (`project.number`) | repo Project (`project.number` = **API id**) | UI URL: `<host>/<owner>/<repo>?project=<id>` |
| Status single-select field + options | project **columns** | `card.sh` synthesizes a `Status` field from columns; option ids are column ids (strings) |
| `updateProjectV2ItemFieldValue` | `POST …/projects/{id}/issues/{gid}/move {column_id}` | `gid` = issue **global id**, not the repo-local number |
| project item id (`PVTI_…`) | `gitea:<global id>` | same cache slots in `board-<owner>-<number>.json` |
| GraphQL (`gh api graphql`) | none — REST only | every read is 1+ `tea api` GETs |
| `gh pr merge --squash --match-head-commit X` | `POST …/pulls/{i}/merge {do:"squash", head_commit_id:X, delete_branch_after_merge:true}` | merge-gate owns it on both forges |
| `closingIssuesReferences` | `Closes #N` trailer parse | writing standard guarantees the trailer; no trailer → no link → approval fails closed |
| `stateReason` | absent | closed issues read as `COMPLETED` |
| rate limits (5000 pts/hr GraphQL + REST) | `X-RateLimit-*` headers, often **disabled** | `--kind quota` answers `rate_limits_disabled:true` with sentinel 5000s; the per-worker budget (exit 73) is then the only guard |
| `[bot]` app identity | plain bot user | `bot_identity` = username, no suffix |
| assignee claim mutex (atomic edit) | best-effort assign | local `inflight/` lock stays the primary claim |
| review threads / `resolveReviewThread` | no thread API | use PR review comments + `tea pulls resolve` where the server supports it |
| DraftIssue board cards | impossible | — |
| org-level boards | out of scope (v1) | repo projects only |

## gh ↔ tea dictionary (the literal commands skills quote)

| Task | GitHub | Gitea |
|---|---|---|
| Read issue body | `gh issue view N --json number,title,body` | `python3 .claude/bin/super-board-gitea-read.py --kind issue --issue N` |
| Read issue comments | `gh api repos/{o}/{r}/issues/N/comments --paginate` | `…gitea-read.py --kind comments --issue N` |
| Issue state | `gh issue view N --json state` | `…gitea-read.py --kind state --issue N` |
| PR head | `gh pr view N --json headRefName,headRefOid` | `…gitea-read.py --kind head --pr N` |
| PR metadata / diff | `gh pr view --json …` / `gh pr diff` | `…gitea-read.py --kind metadata --pr N` / `--kind diff --pr N --meta <file>` |
| Board read / move | `super-board-card.sh` | `super-board-card.sh` (same verbs; forge inside) |
| Add label | `gh issue edit N --add-label L` | `bash -c '. .claude/bin/super-board-forge.sh && sb_forge_resolve <cfg> && sb_forge_label_add N L'` |
| Comment | `gh issue comment N --body …` | `bash -c '. .claude/bin/super-board-gitea-api.sh && sb_gitea_api POST repos/{o}/{r}/issues/N/comments "$(jq -cn --arg b … '{body:$b}')"'` |
| Create issue | `gh issue create …` | `sb_gitea_api POST repos/{o}/{r}/issues '{"title":…,"body":…,"labels":[ids]}'` (labels are **ids**; resolve/create first) |
| Default branch | `gh repo view --json defaultBranchRef` | `tea api repos/{o}/{r}` → `.default_branch` |
| Quota line on exit | `gh-quota-on-exit: graphql=<n>/5000 rest=<n>/5000` | `gh-quota-on-exit: budget=<n> rate_limits=off` or `budget=<n> rate_limits=<rem>/<limit>` |

Scripts must never hardcode a forge: source `.claude/bin/super-board-forge.sh`, call
`sb_forge_resolve <config>`, then use `sb_forge_read` / `sb_forge_write_once` (github) /
`sb_forge_tea_write` (gitea) / `sb_forge_label_add`. Exit codes are identical on both forges:
79 halt · 73 budget · 69 board · 67 CLI fail · 64 usage/shape · 66 config · 6 head moved.

## Kinds served by `super-board-gitea-read.py`

Passthrough kinds (`-- <tea api GET …>`): `json`, `scalar`, `object`, `array`, `issue-number`.
Composites (the wrapper performs the calls and prints the **github-normalized** shape):
`--issue N` → issue/state/comments · `--pr N` → head/body/merge-state/metadata/diff/approval ·
`--items o/r/pid` → items · `--fields o/r/pid` → fields · `--project`/`--projects` ·
`--permission o/r` · `--issue-history o/r` · `--deps o/r` · `--prs-open`/`--prs-merged`/
`--issues-closed o/r` · `--quota`. Same halt file as github-read
(`.claude/super-board/github-halt.json`), same `--check/--halt/--resume` contract, exit 79/64.

## Lane checklist (Gitea runs)

1. `SB_FORGE`, `SB_FORGE_HOST`, `SB_FORGE_LOGIN`, `GITEA_REPO` come from
   `sb_forge_resolve <config>`; lanes that run bare commands export them first.
2. Required reads still go through the read wrapper (`…gitea-read.py`); `--check` before every
   write burst; a halt (79) preserves work exactly as on GitHub.
3. Board moves: `super-board-card.sh --config <cfg> move <issue> <Status>` — never raw
   `tea api …/move`.
4. Merges: `super-board-merge-gate.sh` only — never bare `tea pulls merge`.
5. Screenshots in tickets/PRs use the Gitea raw form (writing-standard.md → Rules).

## Degradations (accepted, fail-closed)

- **No GraphQL**: multi-object reads are several REST calls (`--deps` = 1 + N comments reads).
  Budget your calls; `sb_gh_budget_spend` still caps every worker (exit 73).
- **No compare-and-swap on assignees**: two dispatchers can claim the same card remotely; the
  local inflight lock is authoritative for a single machine.
- **`head_commit_id` on merge**: enforced on current Gitea; an old server ignoring it narrows
  the pin to the gate's own re-read (documented risk, see merge-gate).
- **Approval trust**: repo owner = admin; listed collaborators = write; nobody else approves.
  An unreadable collaborator list fails closed.
- **collect `prs` source**: no review threads; `mergedAt` is `closed_at`/`updated_at`.

## Troubleshooting

| Symptom | Fix |
|---|---|
| every tea call times out (Windows) | the tea binary itself hangs — reinstall: `winget install --id Gitea.tea -e`, `brew install tea`, or the `dl.gitea.com/tea` binary; onboard's `tea_probe` (5 s) catches this |
| `HTTP 401/403` on first read | token scopes — recreate with `write:issue`, `write:repository` (+ projects when gated), then `tea login add …` again |
| onboard says "no project-columns API" | the instance predates the columns endpoints — upgrade Gitea or keep `forge: github` |
| guard never sleeps, runs fast, then 429s | instance rate limits were enabled mid-run — the throttle steps `max_workers` down from lane-result evidence |
| cards visible in UI but `items` empty | the project id in config is the UI number, not the API id — re-run `board-rank --forge gitea` and fix `project.number` |
