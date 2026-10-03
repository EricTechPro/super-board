#!/usr/bin/env bash
# Offline release checks. Keep test-* / test_* suites offline; paid evals live in evals/.
# Run every suite even after a failure, then fail the whole gate if any suite failed.
set -uo pipefail
cd "$(dirname "$0")/.."

for tool in bash python3 git jq node curl tar; do
  command -v "$tool" >/dev/null || { echo "Missing test dependency: $tool" >&2; exit 1; }
done

shopt -s nullglob
suites=(tests/test-*.sh tests/test_*.py)
[ "${#suites[@]}" -gt 0 ] || { echo 'No safety suites found' >&2; exit 1; }
failed=()
for suite in "${suites[@]}"; do
  echo "::group::$suite"
  case "$suite" in
    *.sh) bash "$suite" ;;
    *.py) python3 "$suite" ;;
  esac
  rc=$?
  echo '::endgroup::'
  if [ "$rc" -ne 0 ]; then
    failed+=("$suite")
    echo "::error::$suite failed (exit $rc)"
  fi
done
if [ "${#failed[@]}" -gt 0 ]; then
  printf 'Failed suite: %s\n' "${failed[@]}" >&2
  exit 1
fi
echo "PASS: ${#suites[@]} safety suites"
