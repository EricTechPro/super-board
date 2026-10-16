#!/usr/bin/env bash
# super-board-gitea-api.sh — low-level Gitea REST calls through `tea api`.
#
# Sourced by super-board-forge.sh and the gitea-side scripts; never executed.
# Every call goes through the tea CLI (v0.16.x pinned semantics): `tea api`
# prefixes /api/v1/, expands {owner}/{repo} from the repo context (GITEA_REPO
# env, exported by forge.sh, or --repo), and `-i` prints response headers to
# STDERR so stdout stays clean JSON.
#
#   sb_gitea_api GET  repos/{owner}/{repo}/issues
#   sb_gitea_api POST repos/{owner}/{repo}/issues '{"title":"…"}'
#   sb_gitea_api_headers GET version 2>headers.txt   # body stdout, headers stderr
#   sb_gitea_label_add 12 bug                        # resolve/create id, attach
#
# All tea spawns are timeout-bounded (SB_GITEA_TIMEOUT, default 30s) because a
# broken tea binary on Windows hangs instead of failing — a hung board call
# must still surface as exit 67, not a dead worker.

SB_GITEA_TIMEOUT="${SB_GITEA_TIMEOUT:-30}"

# Label colors shared with setup.py's LABELS map (github strips the leading #).
SB_GITEA_LABEL_COLORS_qa="0e8a16"
SB_GITEA_LABEL_COLORS_bug="d73a4a"
SB_GITEA_LABEL_COLORS_feature="1d76db"
SB_GITEA_LABEL_DEFAULT_COLOR="ededed"

sb_gitea_tea() {
  # Run tea with a bounded lifetime; prefer coreutils timeout when present.
  # SB_GITEA_TEA overrides the executable (tests point it at the offline stub);
  # it is split with eval so quoted paths with spaces survive — the same value
  # is shlex-split by super-board-gitea-read.py.
  local login_flag=() tea_cmd
  [ -n "${SB_FORGE_LOGIN:-}" ] && login_flag=(--login "$SB_FORGE_LOGIN")
  eval "tea_cmd=(${SB_GITEA_TEA:-tea})"
  if command -v timeout >/dev/null 2>&1; then
    timeout "${SB_GITEA_TIMEOUT:-30}" "${tea_cmd[@]}" "${login_flag[@]}" "$@"
  else
    "${tea_cmd[@]}" "${login_flag[@]}" "$@"
  fi
}

sb_gitea_api() {
  # <METHOD> <endpoint> [json-body]. JSON on stdout. Non-zero on HTTP/tea failure.
  local method="$1" endpoint="$2" body="${3:-}"
  if [ -n "$body" ]; then
    sb_gitea_tea api -X "$method" -d "$body" "$endpoint"
  else
    sb_gitea_tea api -X "$method" "$endpoint"
  fi
}

sb_gitea_api_headers() {
  # Same as sb_gitea_api plus `-i`: response headers land on stderr (the guard
  # reads X-RateLimit-* from there), the body stays clean JSON on stdout.
  local method="$1" endpoint="$2" body="${3:-}"
  if [ -n "$body" ]; then
    sb_gitea_tea api -i -X "$method" -d "$body" "$endpoint"
  else
    sb_gitea_tea api -i -X "$method" "$endpoint"
  fi
}

sb_gitea_label_id() {
  # $1 = label name → prints its id, or nothing when the repo lacks it.
  sb_gitea_api GET 'repos/{owner}/{repo}/labels' 2>/dev/null \
    | jq -r --arg n "$1" '.[] | select(.name == $n) | .id' | head -1
}

sb_gitea_label_add() {
  # $1 = issue number, $2 = label name. Creates the label when missing
  # (Gitea's create has no --force; the pre-check is the idempotence).
  local issue="$1" label="$2" id color
  id=$(sb_gitea_label_id "$label")
  if [ -z "$id" ]; then
    # Bash indirect lookup, guarded: only plain names can have a color preset.
    color="$SB_GITEA_LABEL_DEFAULT_COLOR"
    case "$label" in
      *[!A-Za-z0-9_-]* | '') : ;;
      *) local varname="SB_GITEA_LABEL_COLORS_${label}"
         [ -n "${!varname:-}" ] && color="${!varname}" ;;
    esac
    id=$(sb_gitea_api POST 'repos/{owner}/{repo}/labels' \
      "$(jq -cn --arg n "$label" --arg c "#$color" '{name:$n,color:$c}')" | jq -r '.id')
    [ -n "$id" ] && [ "$id" != "null" ] || return 67
  fi
  sb_gitea_api POST "repos/{owner}/{repo}/issues/${issue}/labels" \
    "$(jq -cn --argjson id "$id" '{labels:[$id]}')" >/dev/null
}
