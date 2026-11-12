# Connect the project's existing code checks

`verify_commands` is the existing merge-gate integration. It runs commands from a
fresh worktree with the current base merged in. The package neither defines your
app's architecture nor installs a folder/import linter.

Choose checks already owned by the project: type checks, tests, lint, and any
existing layout/import rule scripts. Include dependency setup for a fresh checkout.
For a JavaScript app whose package actually defines these scripts, a config could
contain:

```json
"verify_commands": [
  "npm ci --silent && npm run typecheck && npm run lint",
  "npm run lint:imports && npm run lint:layout"
]
```

These are examples, not commands to invent in every app. Python/Rust/other projects
use their own runners. The readiness gate checks that commands are configured;
it cannot prove that a custom command tests the right behaviour. Failed checks
stop merging through the existing gate. A failed command is rerun on the same
tree `verify_retries` times (default 1, `0` = none) first; a pass on a retry
merges and prints `flaky: <command>` so the flaky check can be fixed.

For import boundaries, enforce a decision the app already made, such as an
internal server module being accessible only from server code. A browser app may
legitimately use a client SDK; do not ban all database/SDK imports universally.
For folder rules, enforce the project's chosen layout, not a generic requirement
for one folder per feature. If a required rule is missing, add it in the owning
app with its maintainers, then connect its check here. Documentation or a command
example alone does not install new enforcement in any app.
