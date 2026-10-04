#!/usr/bin/env bash
# super-board-host.sh — which agent host is this shell inside: `claude` or `codex`.
#
# WHY. `/super-board run` launched from a Codex CLI session has no Claude Workflow tool, so the
# workflow backend cannot start. The orchestrator checks its own tool list first; this is the
# check a script can make, and the tie-breaker when the tool list is unclear.
#
# THE SIGNAL. Codex CLI sets CODEX_THREAD_ID (and CODEX_SESSION_ID, the same value) in every
# shell it runs. Observed 2026-10-04 on codex-cli 0.160.0 with `codex exec -s read-only`:
# CODEX_THREAD_ID, CODEX_SESSION_ID, CODEX_VERSION, CODEX_SANDBOX=seatbelt, CODEX_CI=1.
# Not used: CODEX_HOME (people export it in their own profile), CODEX_SANDBOX (absent when
# the sandbox is off). A Codex lane started from a Claude session also carries CLAUDECODE; the
# Codex ids still win there, because the innermost host is the one running this shell.
#
# Usage: super-board-host.sh          prints `claude` or `codex`, exit 0
# SUPER_BOARD_HOST=claude|codex forces the answer (tests, or a host the check misreads).
set -euo pipefail

case "${SUPER_BOARD_HOST:-}" in
  claude|codex) echo "$SUPER_BOARD_HOST"; exit 0 ;;
  '') ;;
  *) echo "super-board-host.sh: SUPER_BOARD_HOST must be claude or codex" >&2; exit 64 ;;
esac

if [ -n "${CODEX_THREAD_ID:-}" ] || [ -n "${CODEX_SESSION_ID:-}" ]; then
  echo codex
else
  echo claude
fi
