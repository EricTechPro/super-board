#!/usr/bin/env bash
# Tests super-board-host.sh — the Codex/Pi-host check that turns a plain `run` into `--codex`/`--pi`.
set -euo pipefail
KIT=$(cd "$(dirname "$0")/.." && pwd)
S="$KIT/scripts/super-board-host.sh"
fail() { echo "FAIL: $1" >&2; exit 1; }
# A clean env, so the test answers the same inside Claude Code, Codex, Pi or CI.
host() { env -i PATH="$PATH" "$@" bash "$S"; }

[ "$(host)" = claude ] || fail 'no host ids means claude'
[ "$(host CODEX_THREAD_ID=01a1)" = codex ] || fail 'CODEX_THREAD_ID means codex'
[ "$(host CODEX_SESSION_ID=01a1)" = codex ] || fail 'CODEX_SESSION_ID means codex'
[ "$(host CODEX_THREAD_ID=01a1 CLAUDECODE=1)" = codex ] || fail 'a Codex lane under Claude is codex'
[ "$(host CODEX_HOME=/x CODEX_SANDBOX=seatbelt)" = claude ] || fail 'CODEX_HOME/CODEX_SANDBOX alone are not a host'
[ "$(host CODEX_THREAD_ID=)" = claude ] || fail 'an empty id is not a host'
[ "$(host PI_CODING_AGENT=true)" = pi ] || fail 'PI_CODING_AGENT means pi'
[ "$(host AI_AGENT=pi)" = pi ] || fail 'AI_AGENT=pi means pi'
[ "$(host AI_AGENT=pi CLAUDECODE=1)" = pi ] || fail 'a Pi session under Claude is pi'
[ "$(host AI_AGENT=pi CODEX_THREAD_ID=01a1)" = pi ] || fail 'a pi spawned from a Codex shell is pi (innermost wins)'
[ "$(host PI_CODING_AGENT=false)" = claude ] || fail 'PI_CODING_AGENT=false is not pi'
[ "$(host AI_AGENT=codex)" = claude ] || fail 'AI_AGENT alone is not a host'
[ "$(host PI_SESSION_ID=01a1)" = claude ] || fail 'session state alone is not a host'
[ "$(host SUPER_BOARD_HOST=codex)" = codex ] || fail 'override forces codex'
[ "$(host SUPER_BOARD_HOST=pi)" = pi ] || fail 'override forces pi'
[ "$(host SUPER_BOARD_HOST=claude CODEX_THREAD_ID=01a1)" = claude ] || fail 'override beats the env'
[ "$(host SUPER_BOARD_HOST=claude AI_AGENT=pi)" = claude ] || fail 'override beats the pi env'
rc=0; host SUPER_BOARD_HOST=gemini >/dev/null 2>&1 || rc=$?
[ "$rc" = 64 ] || fail "bad override exits 64, got $rc"
echo "PASS: super-board-host"
