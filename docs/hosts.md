# Agent hosts

super-board runs inside an agent host: the CLI whose session types `/super-board run`.
`scripts/super-board-host.sh` (installed as `.claude/bin/super-board-host.sh`) names it.

| Host value | Tested version | Start a run | Sign-in | Gaps |
|---|---|---|---|---|
| `claude` | Claude Code 2.1.302 | `/super-board run` (Workflow backend) | `claude` then `/login`; `gh auth login` | None. The reference host. |
| `codex` | codex-cli 0.160.0 | `/super-board run` inside Codex runs as `--codex`; from Claude, `/super-board run --codex` | `codex login`; `gh auth login` | No Workflow tool, so every lane is headless `codex exec`. Review runs only with explicit `--codex` (a host-switched plain `run` counts). No Claude usage guard. |
| `pi` | Pi 1.3.0 (print-mode source also checked at 1.2.0) | `/super-board run --pi` | Configure `pi.provider` and `pi.model`, authenticate that provider, and `gh auth login` | Fresh `pi --print` process per lane. Explicit skills, existing hook checks through the installed Pi guard adapter, and shared merge/readiness gates. Pi tool settings do not provide an OS sandbox. Claude stays the default pending acceptance. |
| `opencode` | OpenCode v2.0.22 | Not supported yet: the run halts with a host-selection request | `opencode auth login`; `gh auth login` | No OpenCode lane backend yet. `permission.external_directory: deny` is not enforced in v2.0.22 (`patch` still writes outside the repo), so OpenCode runs stay attended-only once a backend lands. |

Every host also needs `gh`, `jq`, bash 3.2+ and Python 3.9+.

## How the host is picked

`super-board-host.sh [--config <config.json>]` prints one value. First match wins:

1. `SUPER_BOARD_HOST=claude|codex|pi|opencode`, the manual override. Any other value exits 64.
2. `CODEX_THREAD_ID` or `CODEX_SESSION_ID` → `codex`.
3. `OPENCODE=1` → `opencode`. Checked before `CLAUDECODE`, which leaks into an OpenCode
   session started from Claude Code. `AGENT=1` is ignored: other tools set it too.
4. `CLAUDECODE` → `claude`.
5. The board config's top-level `host` key, when `--config` is given.
6. Nothing matched: empty stdout, a hint on stderr, exit 65. The run halts and asks for a
   host. It never guesses Claude.

A live env sign beats the saved config, so a Codex lane started from a Claude-configured
board still answers `codex`.

Onboard always writes `host` into `.claude/super-board/configs/<slug>.json`.
`super-board-setup.py fix` adds a missing one from `--host`; `check` flags any other value.

## Evidence

- Codex: env of `codex exec -s read-only`, 2026-10-04 (recorded in the script header).
- OpenCode: env diff of an `opencode run` shell, 2026-10-19: `OPENCODE=1`,
  `OPENCODE_SESSION_ID`, `OPENCODE_TERMINAL=1`, `AGENT=1`.

## Pi selection

`--pi` overrides either worker backend. Run the existing wave helper with
`--pi` in place of `--codex`: `.claude/bin/super-board-codex-wave.sh` selects
`super-board-pi-lane.sh`. Do not combine the flags. The config must provide
non-empty `pi.provider` and `pi.model`. Pi never uses the Codex model ladder.
Use `SUPER_BOARD_HOST=pi` when selecting Pi from an environment with another
host's inherited signals. No unverified Pi environment variable is treated as a host sign.
The Pi adapter refuses unsupported command hooks and explicit Claude `permissions.deny`
or `permissions.ask` rules before dispatch. These rules must not disappear when changing hosts.
The existing `codex-wave.pid` marker owns both one-shot backends, so stop and
status keep using the same process identity and recovery paths.
