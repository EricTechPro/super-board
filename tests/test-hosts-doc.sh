#!/usr/bin/env bash
# Tests docs/hosts.md — every host value super-board-host.sh accepts in its SUPER_BOARD_HOST
# case has a table row, and README's Install section links the page.
set -euo pipefail
cd "$(dirname "$0")/.."
fail() { echo "FAIL: $1" >&2; exit 1; }
DOC=docs/hosts.md
[ -f "$DOC" ] || fail "$DOC is missing"

# The accepted values: the first case arm after `case "${SUPER_BOARD_HOST:-}" in`.
values=$(awk '/case "\$\{SUPER_BOARD_HOST:-\}" in/{getline; sub(/^[ \t]*/, ""); sub(/\).*/, ""); print; exit}' \
  scripts/super-board-host.sh | tr '|' ' ')
[ -n "$values" ] || fail "no SUPER_BOARD_HOST values found in super-board-host.sh"
n=0
for v in $values; do
  grep -q "^| \`$v\` |" "$DOC" || fail "host \`$v\` has no row in $DOC"
  n=$((n + 1))
done
[ "$n" -ge 3 ] || fail "expected at least claude, codex and opencode, got: $values"

# README links the page from the Install section (between ## Install and the next ## heading).
awk '/^## Install/{on=1; next} /^## /{on=0} on' README.md | grep -q '(docs/hosts.md)' \
  || fail "README Install section must link docs/hosts.md"
echo "PASS: test-hosts-doc.sh ($n hosts)"
