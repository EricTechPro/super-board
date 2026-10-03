#!/usr/bin/env bash
# Tests super-board-preflight.sh — the check that runs before any card goes
# Ready → Building. `gh` is a stub on PATH that serves fixtures and logs calls.
#
# The rule it pins: two agents must never build the same thing, and nothing that
# is already on the base branch gets built twice. Same files alone is not a
# duplicate — it is a sequencing problem, and must not hold the card.
set -euo pipefail
cd "$(dirname "$0")"
PRE="$(pwd)/../scripts/super-board-preflight.sh"

fail() { echo "FAIL: $1" >&2; exit 1; }

TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT
mkdir -p "$TMP/bin" "$TMP/fx"; export GH_LOG="$TMP/gh.log" FX="$TMP/fx"
cat > "$TMP/bin/gh" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$GH_LOG"
case "$*" in
  "api rate_limit"*)          echo '{"resources":{"graphql":{"remaining":5000,"reset":0},"core":{"remaining":5000,"reset":0}}}' ;;
  "issue view "*)             cat "$FX/issue-$3.json" ;;
  "pr list"*"--state merged"*) cat "$FX/merged.json" ;;
  "pr list"*"--state open"*)   cat "$FX/open.json" ;;
  "issue list"*"--state closed"*) cat "$FX/closed.json" ;;
  *) exit 1 ;;
esac
STUB
chmod +x "$TMP/bin/gh"

AC=$'## Acceptance Criteria\n- [ ] it works'
issue() { jq -n --argjson n "$1" --arg t "$2" --arg b "$3" '{number:$n,title:$t,body:$b}' > "$FX/issue-$1.json"; }
issue 20 "Export invoices as CSV"            "$AC"
issue 21 "Dark mode toggle in settings"      "$AC"
issue 22 "Rate limit the login endpoint"     $'Touches `src/auth/login.ts`.\n'"$AC"
issue 23 "Weekly digest email"               "$AC"
issue 24 "Something about the dashboard"     $'No criteria here.'
issue 25 "Retry failed webhooks"             "$AC"$'\nfingerprint: err|sentry|991'

cat > "$FX/merged.json" <<'J'
[ {"number":31,"title":"CSV export for invoices","body":"## Issue\nResolves #20 — Export invoices as CSV","url":"u31"},
  {"number":32,"title":"Webhook backoff","body":"fingerprint: err|sentry|991","url":"u32"} ]
J
cat > "$FX/open.json" <<'J'
[ {"number":40,"title":"Dark mode toggle in settings page","body":"wip","url":"u40","headRefName":"eric/dark-mode",
   "files":[{"path":"src/settings/theme.ts"}]},
  {"number":41,"title":"Session timeout banner","body":"Resolves #50","url":"u41","headRefName":"issue-50-session-timeout",
   "files":[{"path":"src/auth/login.ts"},{"path":"src/ui/banner.tsx"}]},
  {"number":42,"title":"Weekly digest email","body":"Resolves #23","url":"u42","headRefName":"issue-23-weekly-digest",
   "files":[{"path":"src/mail/digest.ts"}]} ]
J
echo '[]' > "$FX/closed.json"

run() { PATH="$TMP/bin:$PATH" "$PRE" --repo o/r "$@"; }
OUT=$(run --issues 20,21,22,23,24,25)
get() { echo "$OUT" | jq -e ".[\"$1\"] | $2" >/dev/null; }

# 1 — duplicate merged PR → hold. #31 merged with "Resolves #20": building #20
#     again would ship the same feature twice.
get 20 '.verdict == "hold" and .tag == "done"' || fail "#20 is already merged in #31: $(echo "$OUT" | jq -c '.["20"]')"
get 20 '.evidence | any(test("#31"))'          || fail "#20's hold must name PR #31"

# 2 — open PR, same feature, different branch → hold. Another agent (or a human)
#     is already building dark mode on eric/dark-mode.
get 21 '.verdict == "hold" and .tag == "in-progress"' || fail "#21 is in flight in #40: $(echo "$OUT" | jq -c '.["21"]')"
get 21 '.evidence | any(test("#40"))'                 || fail "#21's hold must name PR #40"

# 3 — same files only → sequence, never hold. #41 is a different feature that
#     touches login.ts; #22 goes behind the issue #41 closes (#50), so the
#     wave-start sweep frees it the moment #50 closes.
get 22 '.verdict == "sequence" and .tag == "overlap"' || fail "#22 overlaps #41 only: $(echo "$OUT" | jq -c '.["22"]')"
get 22 '.blockedBy == [50] and .conflictWith == [41]' || fail "#22 must sit behind #50 / PR #41: $(echo "$OUT" | jq -c '.["22"]')"

# 4 — clean → proceed. #23's own branch PR (#42, issue-23-*) is the card coming
#     back for a rebuild, not a duplicate of itself.
get 23 '.verdict == "proceed" and .tag == "clean"' || fail "#23 is clean (own PR ignored): $(echo "$OUT" | jq -c '.["23"]')"

# 5 — no acceptance criteria → hold as unclear (❓), never built on a guess.
get 24 '.verdict == "hold" and .tag == "unclear"' || fail "#24 has no ACs: $(echo "$OUT" | jq -c '.["24"]')"

# 6 — a merged PR with the same fingerprint is "already done" even with a
#     different title. That is what fingerprints are for.
get 25 '.verdict == "hold" and .tag == "done"' || fail "#25 shares #32's fingerprint: $(echo "$OUT" | jq -c '.["25"]')"

# 7 — batching is cheap: three list calls total for six issues, plus one view each.
[ "$(grep -c '^pr list\|^issue list' "$GH_LOG")" -eq 3 ] || fail "lists must be fetched once per batch: $(cat "$GH_LOG")"
[ "$(grep -c '^issue view' "$GH_LOG")" -eq 6 ] || fail "one issue view per card"

# 8 — another card already in Building with the same title → hold; a lower-
#     numbered Ready peer in the same wave wins, a higher-numbered one does not.
issue 26 "Bulk archive old projects" "$AC"
echo '[{"number":19,"title":"Bulk archive old projects","status":"Ready"},
       {"number":27,"title":"Retry failed webhooks","status":"Ready"}]' > "$TMP/cards.json"
OUT8=$(run --issues 26 --inflight "$TMP/cards.json")
echo "$OUT8" | jq -e '.["26"].verdict == "hold" and .["26"].tag == "in-progress"' >/dev/null \
  || fail "#26 duplicates lower Ready peer #19: $OUT8"
echo '[{"number":27,"title":"Bulk archive old projects","status":"Ready"}]' > "$TMP/cards.json"
OUT8b=$(run --issues 26 --inflight "$TMP/cards.json")
echo "$OUT8b" | jq -e '.["26"].verdict == "proceed"' >/dev/null \
  || fail "the lower-numbered peer (#26) must proceed: $OUT8b"

# 9 — a blind pre-flight never says proceed: gh failing exits 69.
RC=0; PATH="$TMP/bin:$PATH" "$PRE" --repo o/r --issues 99 >/dev/null 2>&1 || RC=$?
[ "$RC" -eq 69 ] || fail "an unreadable issue should exit 69, got $RC"
RC=0; "$PRE" --repo o/r >/dev/null 2>&1 || RC=$?
[ "$RC" -eq 64 ] || fail "missing --issues should exit 64, got $RC"

echo "PASS: test-preflight.sh (9 scenarios)"
