# Skill readiness before dispatch

Run `python3 .claude/bin/super-board-skills-ready.py --root <project> --host
<claude|codex> --cards <cards.json>` before any claims or wave writes. The cards
array carries number, status, labels and literal issue body; hydrate absent
bodies read-only with the guarded GitHub reader (`--hydrate` does this).
For a worker boundary add `--lane build|qa|review`. Before using a conditional
or custom helper add `--require <exact-name>`; repeat when the execution host changes.

Load `resolved_path` files from the JSON report. Use only its declared fallback
IDs and source instructions. Exit 10 names missing required skills: return
`status=halted`, detail beginning `skills-readiness:`, preserve card state,
claims, worktrees and approval evidence, repair files and restart explicitly.
Exit 64 means malformed input/catalog; halt and repair it. GitHub read exit 79
keeps its existing halt policy. Verification-readiness remains exit 9.

`REGISTRY` in the installed script owns the executable dependency contract:
label precedence, Build overrides, lane boundaries, conditionals and fallbacks.
`Skills:` outside code fences replaces the Build row and keeps always helpers;
QA-only overrides are additional requests. Empty selection needs no helpers.
Setup uses `--profile setup` for the eight core skills and unconditional union;
a selected chain can be runnable while the setup union is incomplete.

Claude sees project/user `.claude/skills` and enabled, scoped plugin records.
Codex sees `.agents/skills` from the current directory through its owning Git
root, user/active Codex roots, and
authoritative catalog entries. Its core `.claude` direct reads are supported;
helper files in `.claude` alone are not Codex availability. Symlinks are valid
when their target is a readable, nonempty regular `SKILL.md`. A lockfile,
cache directory or another host's install is not evidence.

`--home` isolates home discovery; `--catalog` supplies the enabled active
inventory. Launchers accept `SUPER_BOARD_SKILLS_HOME` and
`SUPER_BOARD_SKILLS_CATALOG`. Catalog entries name exact paths, host and
user/project scope, with project_root for project entries. They grant no
fallback or mutation authority. Read-only checks and dispatch install nothing.
Explicit onboard `fix` retains helper repair and re-resolves files afterward.

Codex native `[[skills.config]]` disabled paths also apply after symlink
resolution. Unsupported activation syntax requires an authoritative active
catalog; only its exact enabled paths may resolve until native syntax is
understood. Discovery and activation follow [Codex skill documentation](https://learn.chatgpt.com/docs/build-skills).

Project `.codex/config.toml` activation depends on trust and configuration
layers. When a scoped project config contains skill activation, provide the
host's effective active catalog; the resolver uses only its exact enabled
paths rather than guessing trust or layer precedence. Ordinary project
configs with no activation leave discovery unchanged. See [Codex project
configuration](https://learn.chatgpt.com/docs/config-file/config-basic).
