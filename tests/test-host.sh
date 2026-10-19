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
nohost AGENT=1                                 # OpenCode sets it, but so do other tools

# OpenCode v2.0.22 exports OPENCODE=1. It wins over a CLAUDECODE leaked from a parent Claude
# session; the override and a Codex id still win over it.
[ "$(host OPENCODE=1)" = opencode ] || fail 'OPENCODE=1 means opencode'
[ "$(host OPENCODE=1 CLAUDECODE=1)" = opencode ] || fail 'OpenCode under a Claude parent is opencode'
[ "$(host SUPER_BOARD_HOST=claude OPENCODE=1)" = claude ] || fail 'override beats the OpenCode sign'
[ "$(host CODEX_THREAD_ID=01a1 OPENCODE=1)" = codex ] || fail 'a Codex id beats the OpenCode sign'

# Config `host` (top-level key): used only when no override and no env sign is present.
T=$(mktemp -d); trap 'rm -f "$ERR"; rm -rf "$T"' EXIT
printf '{"host":"codex"}' > "$T/codex.json"
printf '{"worker_backend":"workflow"}' > "$T/none.json"
printf '{"host":"gemini"}' > "$T/bad.json"
cfg() { local f=$1; shift; env -i PATH="$PATH" "$@" bash "$S" --config "$f"; }
[ "$(cfg "$T/codex.json")" = codex ] || fail 'config host codex prints codex'
[ "$(cfg "$T/codex.json" CLAUDECODE=1)" = claude ] || fail 'an env sign beats config host'
[ "$(cfg "$T/codex.json" SUPER_BOARD_HOST=opencode)" = opencode ] || fail 'override beats config host'
for f in none missing; do
  rc=0; out=$(cfg "$T/$f.json" 2>/dev/null) || rc=$?
  [ "$rc" = 65 ] && [ -z "$out" ] || fail "config $f without host should exit 65, got $rc '$out'"
done
rc=0; cfg "$T/bad.json" >/dev/null 2>&1 || rc=$?
[ "$rc" = 64 ] || fail "a bad config host exits 64, got $rc"
echo "PASS: super-board-host"
