#!/usr/bin/env bash
# Tests super-board-gh-guard.sh's gitea mode against the offline tea stub:
# a disabled-limit instance never sleeps (the local budget is the guard),
# the summary reports the api bucket, and the budget exits 73 when spent.
# No network. GitHub-side guard behavior stays covered by test-throttle.sh.
set -euo pipefail
cd "$(dirname "$0")"
KIT="$PWD/.."
GUARD="$KIT/scripts/super-board-gh-guard.sh"
STUB="$KIT/evals/_stubs/bin/tea"
TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT
fail() { echo "FAIL: $1" >&2; exit 1; }
pass=0; ok() { pass=$((pass + 1)); echo "  ✅ $1"; }

mkdir -p "$TMP/.git"
if [ -x "/c/Program Files/Git/usr/bin/bash.exe" ]; then
  BASH_EXE="C:/Program Files/Git/usr/bin/bash.exe"
else
  BASH_EXE="bash"
fi
export SB_GITEA_TEA="\"$BASH_EXE\" $(cygpath -m "$STUB" 2>/dev/null || echo "$STUB")" \
       SB_FORGE_KIND=gitea SB_GH_GUARD_STATE_FILE="$TMP/budget" \
       SB_GITHUB_HALT_FILE="$TMP/halt.json" SB_GITEA_RETRY_DELAY=0
# shellcheck source=/dev/null
source "$GUARD"
cd "$TMP"

# 1 — healthy headers: guard check passes without sleeping.
T0=$(date +%s)
sb_gh_guard_check 200 || fail "healthy guard check"
[ $(( $(date +%s) - T0 )) -lt 10 ] || fail "healthy check slept"
ok "healthy api bucket → no sleep"

# 2 — summary reports the api bucket in the shared one-line format.
SUM=$(sb_gh_guard_summary)
grep -q 'rest=3597/3600' <<<"$SUM" || fail "summary: $SUM"
ok "summary: $SUM"

# 3 — a disabled-limit instance: check returns instantly, summary says off.
mkdir -p .git/tea-fixture
touch .git/tea-fixture/no-ratelimit
T0=$(date +%s)
sb_gh_guard_check 200 || fail "disabled guard check"
[ $(( $(date +%s) - T0 )) -lt 10 ] || fail "disabled check slept"
SUM=$(sb_gh_guard_summary)
grep -q 'rate_limits=off' <<<"$SUM" || fail "disabled summary: $SUM"
rm -f .git/tea-fixture/no-ratelimit
ok "rate limits off → no sleep, summary says rate_limits=off"

# 4 — the local budget is forge-neutral and still exits 73 when spent.
sb_gh_budget_init 2
sb_gh_budget_spend 1 || fail "first spend"
RC=0; sb_gh_budget_spend 1 >/dev/null 2>&1 || RC=$?
[ "$RC" = 73 ] || fail "spending the last unit should exit 73, got $RC"
ok "budget 2 → first spend ok, second exits 73"

echo "test-gh-guard-gitea: $pass passed"
