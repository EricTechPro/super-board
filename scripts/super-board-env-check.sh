#!/usr/bin/env bash
# super-board-env-check.sh — say which env keys exist, never what they hold.
#
# Onboarding needs to know whether SENTRY_AUTH_TOKEN, POSTHOG_PERSONAL_API_KEY
# or a migration DB URL is set. The guard-secrets hook (rightly) denies `grep`,
# `cat` or `source` on a dotenv file, so the old `grep -c '^NAME=' .env` check
# was blocked on every install that had the guard. This script reads the file
# itself and prints one word per key — present, empty or missing — so no value
# ever reaches stdout, stderr or the transcript. guard-secrets allows a plain
# call to it (see hooks/guard-secrets.py → ENV_CHECK).
#
# Usage:
#   super-board-env-check.sh [--file <dotenv>] KEY [KEY ...]
#
# --file defaults to the first that exists of .env.local, .env (in the CWD).
# Accepts `KEY=…` and `export KEY=…`; a commented line does not count.
#
# Stdout, one line per key:   KEY present | KEY empty | KEY missing
# Exit: 0 every key present · 1 at least one empty or missing · 64 usage
set -euo pipefail

FILE=""
KEYS=()
while [ $# -gt 0 ]; do
  case "$1" in
    --file) FILE="${2:-}"; shift 2 ;;
    -h|--help) sed -n '2,22p' "$0"; exit 0 ;;
    -*) echo "unknown option: $1" >&2; exit 64 ;;
    *) KEYS+=("$1"); shift ;;
  esac
done
[ "${#KEYS[@]}" -gt 0 ] || { echo "usage: $0 [--file <dotenv>] KEY [KEY ...]" >&2; exit 64; }

if [ -z "$FILE" ]; then
  for f in .env.local .env; do [ -f "$f" ] && { FILE="$f"; break; }; done
fi

rc=0
for k in "${KEYS[@]}"; do
  case "$k" in
    *[!A-Za-z0-9_]*|"") echo "invalid key name: $k" >&2; exit 64 ;;
  esac
  state=missing
  if [ -n "$FILE" ] && [ -f "$FILE" ]; then
    # awk prints a single word and nothing from the value itself.
    state=$(awk -v k="$k" '
      { sub(/^[ \t]+/, ""); sub(/^export[ \t]+/, "") }
      index($0, k "=") == 1 {
        v = substr($0, length(k) + 2); gsub(/^["'\'' \t]+|["'\'' \t\r]+$/, "", v)
        s = (v == "") ? "empty" : "present"
      }
      END { print (s == "" ? "missing" : s) }' "$FILE")
  fi
  echo "$k $state"
  [ "$state" = present ] || rc=1
done
exit "$rc"
