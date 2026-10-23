# Agent hosts

super-board runs inside an agent host: the CLI whose session types `/super-board run`.
`scripts/super-board-host.sh` (installed as `.claude/bin/super-board-host.sh`) names it.

| Host value | Tested version | Start a run | Sign-in | Gaps |
|---|---|---|---|---|
| `claude` | Claude Code 2.1.302 | `/super-board run` (Workflow backend) | `claude` then `/login`; `gh auth login` | None. The reference host. |
| `codex` | codex-cli 0.160.0 | `/super-board run` inside Codex runs as `--codex`; from Claude, `/super-board run --codex` | `codex login`; `gh auth login` | No Workflow tool, so every lane is headless `codex exec`. Review runs only with explicit `--codex` (a host-switched plain `run` counts). No Claude usage guard. |
| `opencode` | OpenCode v2.0.22 | Not supported yet: the run halts with a host-selection request | `opencode auth login`; `gh auth login` | No OpenCode lane backend yet. `permission.external_directory: deny` is not enforced in v2.0.22 (`patch` still writes outside the repo), so OpenCode runs stay attended-only once a backend lands. |
| `agy` | Google Antigravity CLI 1.4.6 (`agy`) | `/super-board run` inside Antigravity runs as `--agy`; from Claude, `/super-board run --agy` | interactive `agy` once (headless runs use the cached sign-in); `gh auth login` | No Workflow tool, so every lane is headless `agy -p`. Review runs only with explicit `--agy` (a host-switched plain `run` counts). Headless agy auto-denies every tool call no rule in `~/.gemini/antigravity-cli/settings.json` allows: run `super-board-agy-permissions.py --apply` once (see "First run on Antigravity"). The quota guard reads the agy status line, not Claude's. |

Every host also needs `gh`, `jq`, bash 3.2+ and Python 3.9+.

## First run on Antigravity

Once per machine, on a throwaway board, before an unattended run:

| # | Check | How | If it fails |
|---|---|---|---|
| 1 | Install for the host | `./install.sh --hosts agy --protect-main <project>` writes `.agents/hooks.json` (the guards through `hooks/agy-hook-adapter.py`) | re-run it; a hook that cannot start blocks every tool call with its error as the reason |
| 2 | Permission rules | `python3 .claude/bin/super-board-agy-permissions.py --apply` (dry run without `--apply`) | without them a headless lane is auto-denied on its first command and "succeeds" having run nothing |
| 3 | Guards fire headless | in the project: `agy -p 'Use run_command to run exactly: git worktree add ../x -b x' --output-format json` → `BLOCKED: tool call denied by pre-tool hook: Blocked: worktree path …` and no worktree | the hook command in `.agents/hooks.json` does not resolve (cwd is `.agents/`; `python` not `python3` on Windows) |
| 4 | An allowed command runs | `agy -p 'Use run_command to run exactly: git status' --output-format json` prints the status | a `denied_actions` entry means step 2 was skipped |
| 5 | Worker skills resolve | `python3 .claude/bin/super-board-skills-ready.py --root . --host agy --profile setup` exits 0 | onboard's 🔍 Checks installs the helpers |
| 6 | Quota reaches the guard | set `statusLine.command` to `bash <repo>/.claude/bin/super-board-usage.sh record` (on Windows name Git Bash by path, without spaces: `C:\PROGRA~1\Git\bin\bash.exe C:/<repo>/.claude/bin/super-board-usage.sh record`; agy runs the status line through `cmd /c`, where a bare `bash` is WSL's and cannot see `C:/` paths), open `agy` once, then `bash .claude/bin/super-board-usage.sh check --host agy --config <config>` prints `ok` with the buckets of `agy.model` (`gemini-5h` / `gemini-weekly` for a Gemini slug, `3p-*` for Claude or GPT) | the status line only runs in an interactive session |
| 7 | One card end to end | `/super-board run --agy` on a Ready card with acceptance criteria | read `.claude/super-board/inflight/agy-<n>-<lane>.last.json` for the raw run of a lane that returned no result |
| 8 | A lane denied on its very first command, after earlier lanes ran | `head -c 3 ~/.gemini/antigravity-cli/settings.json`: agy 1.4.6 rewrites its settings with a UTF-8 BOM (seen one minute into a lane) and then loads `permissions=<nil>` from it | `python3 .claude/bin/super-board-agy-permissions.py --apply` rewrites the file without the BOM |

Observed on 1.4.6: model slugs carry an effort (`gemini-3.8-flash-low`) and refuse `--effort`; the
lane passes the base slug. Lanes run in PowerShell 5.1 on Windows and hooks under `cmd /c`.
Quota is per model: an exhausted bucket exits 3 with `RESOURCE_EXHAUSTED` and the lane halts.

## How the host is picked

`super-board-host.sh [--config <config.json>]` prints one value. First match wins:

1. `SUPER_BOARD_HOST=claude|codex|opencode`, the manual override. Any other value exits 64.
2. `CODEX_THREAD_ID` or `CODEX_SESSION_ID` → `codex`.
3. `OPENCODE=1` → `opencode`. Checked before `CLAUDECODE`, which leaks into an OpenCode
   session started from Claude Code. `AGENT=1` is ignored: other tools set it too.
4. `ANTIGRAVITY_AGENT=1` → `agy`. Also checked before `CLAUDECODE`, which leaks into an
   Antigravity lane started from a Claude session. The other `ANTIGRAVITY_*` variables are
   per-conversation ids or session secrets and are not used.
5. `CLAUDECODE` → `claude`.
6. The board config's top-level `host` key, when `--config` is given.
7. Nothing matched: empty stdout, a hint on stderr, exit 65. The run halts and asks for a
   host. It never guesses Claude.

A live env sign beats the saved config, so a Codex lane started from a Claude-configured
board still answers `codex`.

Onboard always writes `host` into `.claude/super-board/configs/<slug>.json`.
`super-board-setup.py fix` adds a missing one from `--host`; `check` flags any other value.

## Evidence

- Codex: env of `codex exec -s read-only`, 2026-10-04 (recorded in the script header).
- OpenCode: env diff of an `opencode run` shell, 2026-10-19: `OPENCODE=1`,
  `OPENCODE_SESSION_ID`, `OPENCODE_TERMINAL=1`, `AGENT=1`.
- Antigravity: `cmd /c set` run by `run_command` inside a headless `agy -p` on agy 1.4.6,
  Windows 11, 2026-10-23: `ANTIGRAVITY_AGENT=1`, `ANTIGRAVITY_CONVERSATION_ID`,
  `ANTIGRAVITY_LS_VERSION=cli-1.4.6`, `ANTIGRAVITY_APP_DATA_DIR`, `ANTIGRAVITY_PROJECT_ID`,
  `ANTIGRAVITY_TRAJECTORY_ID`, `ANTIGRAVITY_AGENTAPI_EXE`, `ANTIGRAVITY_LS_ADDRESS`,
  `ANTIGRAVITY_CSRF_TOKEN`, `ANTIGRAVITY_SOURCE_METADATA`. No `AGENT`, `GEMINI_*` or
  `CLAUDECODE`. The hooks and permissions docs name none of them.
