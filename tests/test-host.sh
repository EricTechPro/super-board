#!/usr/bin/env bash
# Tests super-board-host.sh — the Codex-host check that turns a plain `run` into `--codex`.
set -euo pipefail
KIT=$(cd "$(dirname "$0")/.." && pwd)
S="$KIT/scripts/super-board-host.sh"
fail() { echo "FAIL: $1" >&2; exit 1; }
# A clean env, so the test answers the same inside Claude Code, Codex or CI.
host() { env -i PATH="$PATH" "$@" bash "$S"; }

[ "$(host)" = claude ] || fail 'no Codex ids means claude'
[ "$(host CODEX_THREAD_ID=01a1)" = codex ] || fail 'CODEX_THREAD_ID means codex'
[ "$(host CODEX_SESSION_ID=01a1)" = codex ] || fail 'CODEX_SESSION_ID means codex'
[ "$(host CODEX_THREAD_ID=01a1 CLAUDECODE=1)" = codex ] || fail 'a Codex lane under Claude is codex'
[ "$(host CODEX_HOME=/x CODEX_SANDBOX=seatbelt)" = claude ] || fail 'CODEX_HOME/CODEX_SANDBOX alone are not a host'
[ "$(host CODEX_THREAD_ID=)" = claude ] || fail 'an empty id is not a host'
[ "$(host SUPER_BOARD_HOST=codex)" = codex ] || fail 'override forces codex'
[ "$(host SUPER_BOARD_HOST=claude CODEX_THREAD_ID=01a1)" = claude ] || fail 'override beats the env'
rc=0; host SUPER_BOARD_HOST=gemini >/dev/null 2>&1 || rc=$?
[ "$rc" = 64 ] || fail "bad override exits 64, got $rc"
echo "PASS: super-board-host"
