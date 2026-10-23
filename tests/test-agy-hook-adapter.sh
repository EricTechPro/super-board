#!/usr/bin/env bash
# Tests hooks/agy-hook-adapter.py: Antigravity PreToolUse payloads in (the shape agy 1.4.6
# sends: toolCall.name, toolCall.args.CommandLine, workspacePaths), the existing Claude guards
# run, an Antigravity decision out. No agy binary needed.
# Fake keys and dotenv names are assembled at runtime so this file holds no live-looking literal.
set -euo pipefail
cd "$(dirname "$0")"
A="../hooks/agy-hook-adapter.py"
ROOT=$(cd .. && (pwd -W 2>/dev/null || pwd))
PASS=0
fail() { echo "FAIL: $1" >&2; exit 1; }

call() {  # $1 tool name, $2 args JSON, $3.. adapter flags → prints the decision JSON
  local tool="$1" args="$2"; shift 2
  jq -cn --arg n "$tool" --argjson a "$args" --arg r "$ROOT" \
    '{toolCall:{name:$n, args:$a}, workspacePaths:[$r], conversationId:"t", stepIdx:1}' \
    | python3 "$A" --event PreToolUse "$@"
}
expect() {  # $1 decision, $2 label, $3 output
  printf '%s' "$3" | jq -e --arg d "$1" '.decision == $d' >/dev/null || fail "$2: expected $1, got '$3'"
  PASS=$((PASS + 1))
}
cmd() { jq -cn --arg c "$1" '{CommandLine:$c}'; }

D=.env
ANT="sk-""ant-$(printf 'a%.0s' $(seq 1 30))"

# Shell commands: every Bash guard runs; no objection keeps agy's own permission flow ("ask").
expect deny  "dotenv read via run_command"        "$(call run_command "$(cmd "cat $D")")"
expect ask   "ordinary command passes as ask"     "$(call run_command "$(cmd "git status")")"
expect deny  "worktree outside .claude/worktrees" "$(call run_command "$(cmd "git worktree add ../elsewhere")")"
expect deny  "rm outside the project"             "$(call run_command "$(cmd "rm -rf /")")"
expect ask   "push guard is opt-in"               "$(call run_command "$(cmd "git push origin HEAD:main")")"
expect deny  "push guard with --protect-push"     "$(call run_command "$(cmd "git push origin HEAD:main")" --protect-push)"
expect deny  "lower-case command key"             "$(call run_command "$(jq -cn --arg c "cat $D" '{command:$c}')")"
expect deny  "args as a JSON string"              "$(jq -cn --arg c "cat $D" --arg r "$ROOT" '{toolCall:{name:"run_command", args:({CommandLine:$c}|tojson)}, workspacePaths:[$r]}' | python3 "$A" --event PreToolUse)"

# Files: secrets on reads, key literals on writes; workspace files pass as allow.
expect deny  "view_file on a dotenv"              "$(call view_file "$(jq -cn --arg p "$ROOT/$D.local" '{AbsolutePath:$p}')")"
expect allow "view_file in the workspace"         "$(call view_file "$(jq -cn --arg p "$ROOT/README.md" '{AbsolutePath:$p}')")"
expect ask   "view_file outside the workspace"    "$(call view_file '{"AbsolutePath":"/definitely/elsewhere/file.txt"}')"
expect deny  "write_to_file with a live key"      "$(call write_to_file "$(jq -cn --arg p "$ROOT/x.ts" --arg k "const k = '$ANT'" '{TargetFile:$p, CodeContent:$k}')")"
expect deny  "replace chunks with a live key"     "$(call replace_file_content "$(jq -cn --arg p "$ROOT/x.ts" --arg k "$ANT" '{TargetFile:$p, ReplacementChunks:[{TargetContent:"a", ReplacementContent:("x = \"" + $k + "\"")}]}')")"
expect allow "ordinary write"                     "$(call write_to_file "$(jq -cn --arg p "$ROOT/x.ts" '{TargetFile:$p, CodeContent:"export const x = 1"}')")"
expect allow "relative path resolves in the workspace" "$(call write_to_file '{"TargetFile":"src/x.ts","CodeContent":"export const x = 1"}')"

# Overrides for the pass decision, and fail-open on garbage.
OUT=$(SB_AGY_HOOK_PASS_COMMAND=force_ask call run_command "$(cmd "ls")")
expect force_ask "command pass override" "$OUT"
OUT=$(echo 'not json' | python3 "$A" --event PreToolUse)
expect ask "garbage input falls back to the pass decision" "$OUT"
OUT=$(echo '{}' | python3 "$A" --event PostToolUse)
[ "$OUT" = "{}" ] || fail "PostToolUse must answer {}, got '$OUT'"; PASS=$((PASS + 1))
expect ask "unknown tool passes" "$(call some_unrelated_tool '{}')"

# The shipped hooks.json is valid, points at the adapter relative to .agents/ (the hook's cwd)
# and matches the tool names agy uses.
jq -e '."super-board-guards".PreToolUse[0].hooks[0].command == "python3 hooks/agy-hook-adapter.py --event PreToolUse"' ../hooks/agy-hooks.json >/dev/null \
  || fail "hooks/agy-hooks.json must run hooks/agy-hook-adapter.py relative to .agents/"; PASS=$((PASS + 1))
M=$(jq -r '."super-board-guards".PreToolUse[0].matcher' ../hooks/agy-hooks.json)
for t in run_command view_file write_to_file replace_file_content grep_search find_by_name; do
  echo "$t" | grep -Eq "^($M)$" || fail "matcher must cover $t"
done; PASS=$((PASS + 1))

echo "PASS: test-agy-hook-adapter.sh ($PASS checks)"
