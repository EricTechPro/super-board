#!/usr/bin/env bash
# Tests super-board-host.sh — which agent host runs this shell, else exit 65 so the run
# asks for a host instead of guessing.
set -euo pipefail
KIT=$(cd "$(dirname "$0")/.." && pwd)
S="$KIT/scripts/super-board-host.sh"
fail() { echo "FAIL: $1" >&2; exit 1; }
# A clean env, so the test answers the same inside Claude Code, Codex or CI.
host() { env -i PATH="$PATH" "$@" bash "$S"; }

[ "$(host CLAUDECODE=1)" = claude ] || fail 'CLAUDECODE means claude'
[ "$(host CODEX_THREAD_ID=01a1)" = codex ] || fail 'CODEX_THREAD_ID means codex'
[ "$(host CODEX_SESSION_ID=01a1)" = codex ] || fail 'CODEX_SESSION_ID means codex'
[ "$(host CODEX_THREAD_ID=01a1 CLAUDECODE=1)" = codex ] || fail 'a Codex lane under Claude is codex'
[ "$(host SUPER_BOARD_HOST=codex)" = codex ] || fail 'override forces codex'
[ "$(host SUPER_BOARD_HOST=claude CODEX_THREAD_ID=01a1)" = claude ] || fail 'override beats the env'
[ "$(host SUPER_BOARD_HOST=opencode)" = opencode ] || fail 'override accepts opencode'
rc=0; host SUPER_BOARD_HOST=gemini >/dev/null 2>&1 || rc=$?
[ "$rc" = 64 ] || fail "bad override exits 64, got $rc"

# No sign and no override: empty stdout, a hint on stderr, exit 65 — never a guessed claude.
ERR=$(mktemp); trap 'rm -f "$ERR"' EXIT
nohost() {
  local rc=0 out
  out=$(host "$@" 2>"$ERR") || rc=$?
  [ "$rc" = 65 ] || fail "'$*' should exit 65, got $rc"
  [ -z "$out" ] || fail "'$*' should print nothing to stdout, got '$out'"
  grep -q SUPER_BOARD_HOST "$ERR" || fail "'$*' should explain SUPER_BOARD_HOST on stderr"
}
nohost
nohost CODEX_HOME=/x CODEX_SANDBOX=seatbelt   # not host signs
nohost CODEX_THREAD_ID= CLAUDECODE=            # empty values are not signs
echo "PASS: super-board-host"
