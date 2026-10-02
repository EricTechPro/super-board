# super-board guard hooks

Claude Code hook scripts. Python 3 standard library only (no jq, no node). Each reads the
hook JSON on stdin, prints a decision only when it blocks, and exits 0 on its own errors
so a broken guard never stops unrelated work.

- `guard-worktree-path.py` — PreToolUse `Bash`: denies `git worktree add|move` whose target resolves outside `<repo>/.claude/worktrees/` (honours `cd X &&`, `git -C X`).
- `guard-secrets.py` — PreToolUse `Bash|Read|Grep`: denies reading or piping dotenv files, SSH keys, `.npmrc`, `credentials(.json)`, service-account JSON and `.pem`; `.env.example` stays readable.
- `guard-key-literals.py` — PreToolUse `Edit|MultiEdit|Write|NotebookEdit|Bash`: denies writing a live-looking API key into a file; PostToolUse `Edit|MultiEdit|Write|NotebookEdit`: flags one already on disk. Reports line numbers, never the value.

## Enable

`install.sh` does this for you: it copies the scripts to `.claude/hooks/` in the target
project and merges the block below (kept in `settings-snippet.json`) into
`.claude/settings.json`, backing the file up first and never adding a command twice.
`./install.sh --no-hooks` skips both. By hand, copy the scripts and merge this:

```json
{
  "hooks": {
    "PreToolUse": [
      {
        "matcher": "Bash",
        "hooks": [
          { "type": "command", "command": "python3 \"$CLAUDE_PROJECT_DIR\"/.claude/hooks/guard-worktree-path.py" }
        ]
      },
      {
        "matcher": "Bash|Read|Grep",
        "hooks": [
          { "type": "command", "command": "python3 \"$CLAUDE_PROJECT_DIR\"/.claude/hooks/guard-secrets.py" }
        ]
      },
      {
        "matcher": "Edit|MultiEdit|Write|NotebookEdit|Bash",
        "hooks": [
          { "type": "command", "command": "python3 \"$CLAUDE_PROJECT_DIR\"/.claude/hooks/guard-key-literals.py" }
        ]
      }
    ],
    "PostToolUse": [
      {
        "matcher": "Edit|MultiEdit|Write|NotebookEdit",
        "hooks": [
          { "type": "command", "command": "python3 \"$CLAUDE_PROJECT_DIR\"/.claude/hooks/guard-key-literals.py" }
        ]
      }
    ]
  }
}
```

Optional, with the `cleanup-wt` skill installed — sweep merged worktrees when a base
branch has moved since the last session:

```json
{
  "hooks": {
    "SessionStart": [
      {
        "hooks": [
          { "type": "command", "command": "cd \"$CLAUDE_PROJECT_DIR\" && python3 .claude/skills/cleanup-wt/scripts/cleanup-wt.py --auto --fetch 2>/dev/null || true" }
        ]
      }
    ]
  }
}
```

Tests: `tests/test-guard-hooks.sh`.

## Credit

- `guard-worktree-path.py` — ported from `.claude/hooks/guard-worktree-path.js` in Eric
  Tech's BookKeepingApp.
- `guard-secrets.py`, `guard-key-literals.py` — ported from `.agents/hooks/` in Eric
  Tech's [ai-builder-starter-kit](https://github.com/EricTechPro/ai-builder-starter-kit)
  (same author as this pack; the kit has no top-level licence file, and this pack is MIT).
