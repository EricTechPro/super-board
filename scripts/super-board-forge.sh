#!/usr/bin/env bash
# super-board-forge.sh — forge dispatch for board scripts.
#
# Sourced, never executed. One place decides whether the board talks to GitHub
# (gh + super-board-github-read.py) or Gitea (tea + super-board-gitea-read.py);
# callers keep using the same verbs and the same exit codes (79 halt · 73
# budget · 69 board · 67 CLI fail). Resolution lives in super-board-forge.py:
# env SB_FORGE/SB_FORGE_HOST/SB_FORGE_LOGIN → config forge/forge_host/
# forge_login → the git remote → default github.
#
# Usage from a board script:
#   source "$(dirname "$0")/super-board-forge.sh"
#   sb_forge_resolve "$CONFIG_PATH"   # sets+exports SB_FORGE_* (exit 64/66 propagates)
#   sb_forge_checkpoint               # halt-file check, both forges
#   sb_forge_read json -- <args>      # bounded read via the forge's wrapper
#   sb_forge_write_once issue edit 3 --add-label qa     # github gh write
#   sb_forge_tea_write POST repos/o/r/issues "labels" '[1]'  # gitea REST write
#   sb_forge_label_add 12 bug         # add a label on either forge
#
# On gitea, GITEA_REPO=<owner>/<repo> is exported so `tea api` expands
# {owner}/{repo} placeholders inside worktrees the same way GH_REPO does for
# `gh api` on GitHub.

# This file's own path: BASH_SOURCE under bash, the %x prompt escape under zsh.
if [ -n "${BASH_SOURCE[0]:-}" ]; then _sb_forge_src="${BASH_SOURCE[0]}"; else eval '_sb_forge_src="${(%):-%x}"'; fi
SB_FORGE_BIN="$(cd "$(dirname "$_sb_forge_src")" && pwd)"; unset _sb_forge_src
SB_FORGE_PY="$SB_FORGE_BIN/super-board-forge.py"
SB_GITHUB_READ="$SB_FORGE_BIN/super-board-github-read.py"
SB_GITEA_READ="$SB_FORGE_BIN/super-board-gitea-read.py"
SB_GITEA_API="$SB_FORGE_BIN/super-board-gitea-api.sh"

SB_FORGE_KIND="${SB_FORGE_KIND:-github}"
SB_FORGE_HOST="${SB_FORGE_HOST:-}"
SB_FORGE_LOGIN="${SB_FORGE_LOGIN:-}"
SB_FORGE_OWNER="${SB_FORGE_OWNER:-}"
SB_FORGE_REPO="${SB_FORGE_REPO:-}"

sb_forge_resolve() {
  # $1 = config path (optional). Fills SB_FORGE_* from super-board-forge.py.
  local assignments rc=0
  assignments=$(python3 "$SB_FORGE_PY" get --shell ${1:+--config "$1"}) || rc=$?
  [ "$rc" -eq 0 ] || return "$rc"
  eval "$assignments"
  export SB_FORGE_KIND SB_FORGE_HOST SB_FORGE_LOGIN SB_FORGE_OWNER SB_FORGE_REPO
  if [ "$SB_FORGE_KIND" = "gitea" ] && [ -n "$SB_FORGE_OWNER" ] && [ -n "$SB_FORGE_REPO" ]; then
    export GITEA_REPO="$SB_FORGE_OWNER/$SB_FORGE_REPO"
  fi
  return 0
}

sb_forge_read_wrapper() {
  if [ "$SB_FORGE_KIND" = "gitea" ]; then
    [ -f "$SB_GITEA_READ" ] || { echo "[forge] gitea read wrapper missing: $SB_GITEA_READ" >&2; return 67; }
    echo "$SB_GITEA_READ"
  else
    echo "$SB_GITHUB_READ"
  fi
}

sb_forge_checkpoint() { python3 "$(sb_forge_read_wrapper)" --check; }

sb_forge_read() {
  # Callers pass `<kind> [--] <args…>`; the wrappers take `--kind K -- args`.
  local kind="$1"; shift
  [ "${1:-}" = "--" ] && shift
  local wrapper; wrapper=$(sb_forge_read_wrapper) || return $?
  python3 "$wrapper" --kind "$kind" -- "$@"
}

sb_forge_halt() {
  # Record an ambiguous write outcome (never retried) on either forge.
  local wrapper; wrapper=$(sb_forge_read_wrapper) || return 0
  python3 "$wrapper" --halt "$1" >&2 || true
}

sb_forge_write_once() {
  # GitHub write with halt-on-unknown-outcome. Mirrors run.sh's gh_write_once:
  # a FAILED write may or may not have landed, so the run stops (79) and a
  # human reconciles instead of a retry doubling it.
  sb_forge_checkpoint || return $?
  gh "$@" || {
    sb_forge_halt "GitHub $1 ${2:-} response failed; reconcile the write before restarting"
    return 79
  }
}

sb_forge_tea_write() {
  # Gitea write with the same discipline: <METHOD> <endpoint> [json-body].
  sb_forge_checkpoint || return $?
  [ -f "$SB_GITEA_API" ] || { echo "[forge] gitea api helper missing: $SB_GITEA_API" >&2; return 67; }
  # shellcheck source=super-board-gitea-api.sh
  . "$SB_GITEA_API"
  sb_gitea_api "$@" || {
    sb_forge_halt "Gitea $1 $2 response failed; reconcile the write before restarting"
    return 79
  }
}

sb_forge_label_add() {
  # $1 = issue number, $2 = label name. Creates the label on gitea only when
  # missing (no --force there); github's `gh label create --force` idiom stays
  # with callers that already use it.
  local issue="$1" label="$2"
  if [ "$SB_FORGE_KIND" = "gitea" ]; then
    . "$SB_GITEA_API"
    sb_gitea_label_add "$issue" "$label"
  else
    sb_forge_write_once issue edit "$issue" --add-label "$label" >/dev/null
  fi
}
