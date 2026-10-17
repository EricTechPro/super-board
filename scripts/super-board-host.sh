#!/usr/bin/env bash
# super-board-host.sh — which agent host is this shell inside: `claude`, `codex` or `pi`.
#
# WHY. `/super-board run` launched from a Codex CLI or Pi session has no Claude Workflow tool, so the
# workflow backend cannot start. The orchestrator checks its own tool list first; this is the
# check a script can make, and the tie-breaker when the tool list is unclear.
#
# THE SIGNALS. Codex CLI sets CODEX_THREAD_ID (and CODEX_SESSION_ID, the same value) in every
# shell it runs. Observed 2026-10-04 on codex-cli 0.160.0 with `codex exec -s read-only`:
# CODEX_THREAD_ID, CODEX_SESSION_ID, CODEX_VERSION, CODEX_SANDBOX=seatbelt, CODEX_CI=1.
# Not used: CODEX_HOME (people export it in their own profile), CODEX_SANDBOX (absent when
# the sandbox is off). Pi sets two process markers, documented in its environment-variables
# reference: AI_AGENT=pi (generic) and PI_CODING_AGENT=true (Pi-specific). Both are inherited
# by child processes; Pi's bash tool additionally injects PI_SESSION_ID/PI_MODEL, which are
# session state rather than host markers and are deliberately not consulted here.
# A lane started from another host also carries that host's ids; the ids of the innermost
# host win, because the innermost host is the one running this shell. Pi is checked first:
# `pi` launched from a Codex shell would otherwise inherit CODEX_THREAD_ID and misreport.
#
# Usage: super-board-host.sh          prints `claude`, `codex` or `pi`, exit 0
# SUPER_BOARD_HOST=claude|codex|pi forces the answer (tests, or a host the check misreads).
set -euo pipefail

case "${SUPER_BOARD_HOST:-}" in
  claude|codex|pi) echo "$SUPER_BOARD_HOST"; exit 0 ;;
  '') ;;
  *) echo "super-board-host.sh: SUPER_BOARD_HOST must be claude, codex or pi" >&2; exit 64 ;;
esac

if [ "${AI_AGENT:-}" = "pi" ] || [ "${PI_CODING_AGENT:-}" = "true" ]; then
  echo pi
elif [ -n "${CODEX_THREAD_ID:-}" ] || [ -n "${CODEX_SESSION_ID:-}" ]; then
  echo codex
else
  echo claude
fi
