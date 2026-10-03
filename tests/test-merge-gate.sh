#!/usr/bin/env bash
# Tests super-board-merge-gate.sh — the merge mutex and the freshness gate.
# Scenarios 1-7 stop at or before the first `gh pr view`. Scenarios 8-13 run past
# it against a local bare `origin` and a `gh` stub on PATH, to pin the head guard.
#
# The gate exists because `mergeable: CLEAN` was trusted twice on 2026-08-20 and
# was wrong both times: the text did not conflict, but a shared interface had
# grown on the base since the branch was tested, so the merge would have turned
# the base branch red. These tests pin the two properties that prevent it — one
# merge at a time, and the proof happens under the lock.
set -euo pipefail
cd "$(dirname "$0")"
GATE="../scripts/super-board-merge-gate.sh"

fail() { echo "FAIL: $1" >&2; exit 1; }

setup() {  # $1 = verify_commands JSON array
  TMP=$(mktemp -d)
  mkdir -p "$TMP/.claude/super-board/inflight"
  printf '{"base_branch":"staging","repo":{"path":"%s","remote":"https://github.com/x/y.git"},"verify_commands":%s}' \
    "$TMP" "${1:-[]}" > "$TMP/c.json"
  LOCK="$TMP/.claude/super-board/inflight/merge.lock"
}
teardown() { rm -rf "$TMP"; }

# 1 — a held, fresh lock makes a second caller wait and then give up with 4.
#     Exit 4 is distinct on purpose: "someone else is merging" is not the same
#     answer as "this branch is broken", and the caller routes them differently.
setup
mkdir -p "$LOCK"; date +%s > "$LOCK/at"
RC=0; "$GATE" --config "$TMP/c.json" --pr 1 --lock-timeout 6 --stale-after 9999 >/dev/null 2>&1 || RC=$?
[ "$RC" -eq 4 ] || fail "a contended fresh lock should exit 4, got $RC"
[ -d "$LOCK" ] || fail "the loser must not delete the winner's lock"
teardown

# 2 — a lock older than --stale-after is reaped. A process that died holding it
#     would otherwise wedge every future merge on the board.
setup
mkdir -p "$LOCK"; echo $(( $(date +%s) - 99999 )) > "$LOCK/at"
OUT=$("$GATE" --config "$TMP/c.json" --pr 1 --lock-timeout 6 --stale-after 60 2>&1 || true)
echo "$OUT" | grep -q "reaping a lock abandoned" || fail "an abandoned lock should be reaped, got: $OUT"
teardown

# 3 — THE REGRESSION THIS FILE EXISTS FOR. --lock-timeout and --stale-after must
#     be independent. A caller willing to wait 20 minutes must NOT thereby decide
#     that a 20-minute-old lock is dead: that reaps the very merge it is queued
#     behind. With them collapsed into one number (the first implementation), a
#     lock aged just past the wait window was stolen.
setup
mkdir -p "$LOCK"; echo $(( $(date +%s) - 30 )) > "$LOCK/at"
OUT=$("$GATE" --config "$TMP/c.json" --pr 1 --lock-timeout 6 --stale-after 9999 2>&1 || true)
echo "$OUT" | grep -q "reaping" && fail "a 30s-old lock must survive a 6s waiter with stale-after 9999"
echo "$OUT" | grep -q "could not take the merge lock" || fail "the waiter should time out politely, got: $OUT"
teardown

# 4 — the default stale-after has an absolute floor, not just a multiple of the
#     wait. An impatient caller must not be able to reap by being impatient: with
#     only a 3x multiple, `--lock-timeout 6` outlived its own 18s threshold inside
#     the polling loop and stole a live lock.
setup
mkdir -p "$LOCK"; echo $(( $(date +%s) - 60 )) > "$LOCK/at"
OUT=$("$GATE" --config "$TMP/c.json" --pr 1 --lock-timeout 6 2>&1 || true)
echo "$OUT" | grep -q "reaping" && fail "a 60s-old lock must survive an impatient waiter (floor is 1800s)"
echo "$OUT" | grep -q "could not take the merge lock" || fail "the impatient waiter should time out, got: $OUT"
teardown

# 5 — an empty verify_commands list warns rather than implying a check it skipped.
#     Reaching the warning means the lock was taken, so this also proves the happy
#     path acquires cleanly on an uncontended lock.
setup '[]'
OUT=$("$GATE" --config "$TMP/c.json" --pr 1 --lock-timeout 6 2>&1 || true)
echo "$OUT" | grep -q "lock taken" || fail "an uncontended lock should be taken, got: $OUT"
teardown

# 6 — the lock is released on every exit path, including the failures above.
#     A gate that strands its own lock wedges the board it was written to protect.
setup
OUT=$("$GATE" --config "$TMP/c.json" --pr 1 --lock-timeout 6 2>&1 || true)
[ ! -d "$LOCK" ] || fail "the lock must be released on exit, even when the run fails"
teardown

# 7 — usage errors are distinct from operational ones, so a caller never reads a
#     typo as "the branch is broken".
setup
RC=0; "$GATE" --config "$TMP/c.json" >/dev/null 2>&1 || RC=$?
[ "$RC" -eq 64 ] || fail "a missing --pr should exit 64, got $RC"
RC=0; "$GATE" --config /nope/nope.json --pr 1 >/dev/null 2>&1 || RC=$?
[ "$RC" -eq 66 ] || fail "a missing config should exit 66, got $RC"
teardown

# ── Head guard (8-11). A real git origin with a `staging` base and a `feat`
#    branch; `gh` is a stub that reports feat's head and logs every call.
#    STUB_OID       — headRefOid `gh pr view` reports
#    STUB_OID_AFTER — headRefOid reported once a merge has been attempted
#    STUB_MERGE_RC  — exit code of `gh pr merge`
head_setup() {
  setup '[]'
  ORIGIN="$TMP/origin.git"; git init -q --bare "$ORIGIN"
  git -C "$TMP" init -q -b staging 2>/dev/null || { git -C "$TMP" init -q; git -C "$TMP" checkout -q -b staging; }
  git -C "$TMP" -c user.email=t@t -c user.name=t commit -q --allow-empty -m base
  git -C "$TMP" remote add origin "$ORIGIN"; git -C "$TMP" push -q origin staging
  git -C "$TMP" checkout -q -b feat
  git -C "$TMP" -c user.email=t@t -c user.name=t commit -q --allow-empty -m feat
  git -C "$TMP" push -q origin feat; git -C "$TMP" checkout -q staging
  SHA=$(git -C "$TMP" rev-parse feat)
  mkdir -p "$TMP/bin"; export GH_LOG="$TMP/gh.log"; : > "$GH_LOG"
  cat > "$TMP/bin/gh" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$GH_LOG"
case "$1 $2" in
  "pr view")
    case "$*" in *labels*)
      if [ -n "${STUB_META:-}" ]; then printf '%s\n' "$STUB_META"; else echo '{"files":[],"labels":[]}'; fi
      exit 0 ;; esac
    oid="$STUB_OID"; grep -q '^pr merge' "$GH_LOG" && oid="${STUB_OID_AFTER:-$STUB_OID}"
    echo "feat $oid" ;;
  "pr merge") exit "${STUB_MERGE_RC:-0}" ;;
  "pr diff") printf '%b' "${STUB_DIFF:-}" ;;
esac
STUB
  chmod +x "$TMP/bin/gh"
}
gate() { PATH="$TMP/bin:$PATH" "$GATE" --config "$TMP/c.json" --pr 1 --lock-timeout 6 "$@"; }

# 8 — head moved after review: the reviewed sha no longer matches the PR head.
#     Exit 6, and no merge is attempted on evidence gathered for another commit.
head_setup
RC=0; STUB_OID="$SHA" gate --expect-head deadbeef >/dev/null 2>&1 || RC=$?
[ "$RC" -eq 6 ] || fail "a moved head should exit 6, got $RC"
grep -q '^pr merge' "$GH_LOG" && fail "no merge may be attempted when the head moved"
teardown

# 9 — head unchanged: merge pins the reviewed commit with --match-head-commit.
head_setup
RC=0; STUB_OID="$SHA" gate --expect-head "$SHA" >/dev/null 2>&1 || RC=$?
[ "$RC" -eq 0 ] || fail "a matching head should merge (exit 0), got $RC"
grep -q -- "--match-head-commit $SHA" "$GH_LOG" || fail "merge must pass --match-head-commit $SHA, got: $(cat "$GH_LOG")"
teardown

# 10 — a push lands during verification: GitHub refuses the pinned merge and the
#      head has moved, so this is void evidence (6), not branch protection (3).
head_setup
RC=0; STUB_OID="$SHA" STUB_OID_AFTER=cafef00d STUB_MERGE_RC=1 gate --expect-head "$SHA" >/dev/null 2>&1 || RC=$?
[ "$RC" -eq 6 ] || fail "a head that moved mid-gate should exit 6, got $RC"
teardown

# 11 — same refusal with the head unchanged is still GitHub saying no (3).
head_setup
RC=0; STUB_OID="$SHA" STUB_MERGE_RC=1 gate --expect-head "$SHA" >/dev/null 2>&1 || RC=$?
[ "$RC" -eq 3 ] || fail "a refusal with an unchanged head should exit 3, got $RC"
teardown

# 12 — post-merge cleanup: when the cleanup-wt hook is installed the gate runs it with
#      --post-merge --base <base> after a merge, and its failure never fails the
#      merge that already happened.
head_setup
mkdir -p "$TMP/.claude/hooks"
printf 'import sys\nopen("%s/cleanup.args","w").write(" ".join(sys.argv[1:]))\nsys.exit(1)\n' "$TMP" \
  > "$TMP/.claude/hooks/cleanup-wt.py"
RC=0; STUB_OID="$SHA" gate --expect-head "$SHA" >/dev/null 2>&1 || RC=$?
[ "$RC" -eq 0 ] || fail "a failing cleanup must not fail the merge, got $RC"
grep -q -- "--post-merge --base staging" "$TMP/cleanup.args" 2>/dev/null \
  || fail "cleanup-wt should run with --post-merge --base staging, got: $(cat "$TMP/cleanup.args" 2>/dev/null)"
teardown

# 13 — a refused merge never cleans up. (Scenario 9 is the no-cleanup-wt path.)
head_setup
mkdir -p "$TMP/.claude/hooks"
printf 'open("%s/cleanup.ran","w")\n' "$TMP" > "$TMP/.claude/hooks/cleanup-wt.py"
RC=0; STUB_OID="$SHA" STUB_MERGE_RC=1 gate --expect-head "$SHA" >/dev/null 2>&1 || RC=$?
[ "$RC" -eq 3 ] || fail "a refused merge should still exit 3, got $RC"
[ ! -f "$TMP/cleanup.ran" ] || fail "cleanup must not run when the merge was refused"
teardown

# ── Merge policy and migrations (14-25). Same origin and stub; STUB_META is the
#    `gh pr view --json labels,files,…` answer, STUB_DIFF the `gh pr diff` text.
cfgset() { jq "$1" "$TMP/c.json" > "$TMP/c2.json" && mv "$TMP/c2.json" "$TMP/c.json"; }
meta() {  # $1 labels csv, $2 files csv, $3 body, $4 size
  jq -cn --arg l "$1" --arg f "$2" --arg b "${3:-}" --argjson n "${4:-1}" \
    '{labels: ($l | split(",") | map(select(. != "") | {name: .})),
      files:  ($f | split(",") | map(select(. != "") | {path: .})),
      additions: $n, deletions: 0, body: $b}'
}

# 14 — a money label: a human merges. Exit 7, the category is named, no merge.
head_setup
RC=0; OUT=$(STUB_OID="$SHA" STUB_META="$(meta money src/x.ts)" gate --expect-head "$SHA" 2>/dev/null) || RC=$?
[ "$RC" -eq 7 ] || fail "a money label should exit 7, got $RC"
echo "$OUT" | grep -q "^human-gate: money — label money" || fail "exit 7 must name the category, got: $OUT"
grep -q '^pr merge' "$GH_LOG" && fail "no merge may be attempted on a human-gated PR"
teardown

# 15 — an auth path, by glob; merge_policy.default human; a diff over auto_max_lines.
head_setup
RC=0; STUB_OID="$SHA" STUB_META="$(meta "" src/auth/session.ts)" gate --expect-head "$SHA" >/dev/null 2>&1 || RC=$?
[ "$RC" -eq 7 ] || fail "a path under **/auth/** should exit 7, got $RC"
cfgset '.merge_policy = {default: "human"}'
RC=0; STUB_OID="$SHA" STUB_META="$(meta "" src/x.ts)" gate --expect-head "$SHA" >/dev/null 2>&1 || RC=$?
[ "$RC" -eq 7 ] || fail "merge_policy.default human should exit 7, got $RC"
cfgset '.merge_policy = {default: "auto", auto_max_lines: 100}'
RC=0; OUT=$(STUB_OID="$SHA" STUB_META="$(meta "" src/x.ts "" 400)" gate --expect-head "$SHA" 2>/dev/null) || RC=$?
[ "$RC" -eq 7 ] || fail "400 lines over auto_max_lines 100 should exit 7, got $RC"
echo "$OUT" | grep -q "human-gate: size" || fail "the size gate must say so, got: $OUT"
teardown

# 16 — a destructive keyword counts in an ADDED line only. Deleting a DROP TABLE
#      is not adding one.
head_setup
RC=0; STUB_OID="$SHA" STUB_META="$(meta "" db/x.sql)" STUB_DIFF='+DROP TABLE users;\n' gate --expect-head "$SHA" >/dev/null 2>&1 || RC=$?
[ "$RC" -eq 7 ] || fail "an added DROP TABLE should exit 7 (schema), got $RC"
RC=0; STUB_OID="$SHA" STUB_META="$(meta "" db/x.sql)" STUB_DIFF='-DROP TABLE users;\n' gate --expect-head "$SHA" >/dev/null 2>&1 || RC=$?
[ "$RC" -eq 0 ] || fail "a removed DROP TABLE must not gate, got $RC"
teardown

# 16b — a human approved the policy gate (needs-you:done): the gate merges.
head_setup
RC=0; STUB_OID="$SHA" STUB_META="$(meta money,needs-you:done src/x.ts)" gate --expect-head "$SHA" >/dev/null 2>&1 || RC=$?
[ "$RC" -eq 0 ] || fail "needs-you:done should clear the policy gate, got $RC"
teardown

# 17 — custom categories replace the defaults: with always_human = {} a money
#      label merges.
head_setup
cfgset '.merge_policy = {always_human: {}}'
RC=0; STUB_OID="$SHA" STUB_META="$(meta money src/x.ts)" gate --expect-head "$SHA" >/dev/null 2>&1 || RC=$?
[ "$RC" -eq 0 ] || fail "always_human {} should let a money label merge, got $RC"
teardown

# 18 — a migration whose target env is allowed: the gate runs the configured
#      command for each allowed env, then merges.
head_setup
cfgset ".migrations = {allowed_envs: [\"test\",\"staging\"], target_env: \"staging\",
        commands: {test: \"touch $TMP/ran-test\", staging: \"touch $TMP/ran-staging\"}}"
RC=0; STUB_OID="$SHA" STUB_META="$(meta "" supabase/migrations/001_add.sql)" gate --expect-head "$SHA" >/dev/null 2>&1 || RC=$?
[ "$RC" -eq 0 ] || fail "an allowed migration should merge, got $RC"
[ -f "$TMP/ran-test" ] && [ -f "$TMP/ran-staging" ] || fail "both allowed migrate commands should have run"
teardown

# 19 — the target env is NOT allowed (live): 🙋 exit 8 with the exact command,
#      no merge. The allowed env still ran, so the human has one step left.
head_setup
cfgset ".migrations = {allowed_envs: [\"staging\"], target_env: \"live\",
        commands: {staging: \"touch $TMP/ran-staging\", live: \"npm run db:migrate:live\"}}"
RC=0; OUT=$(STUB_OID="$SHA" STUB_META="$(meta "" prisma/migrations/2026/migration.sql)" gate --expect-head "$SHA" 2>/dev/null) || RC=$?
[ "$RC" -eq 8 ] || fail "a migration for a disallowed env should exit 8, got $RC"
echo "$OUT" | grep -q "^needs-you: npm run db:migrate:live" || fail "exit 8 must print the exact command, got: $OUT"
[ -f "$TMP/ran-staging" ] || fail "the allowed env should still migrate"
grep -q '^pr merge' "$GH_LOG" && fail "no merge while a human step is open"
teardown

# 20 — the human ran it and the PR carries needs-you:done: re-verify, merge.
head_setup
cfgset ".migrations = {allowed_envs: [\"staging\"], target_env: \"live\",
        commands: {staging: \"true\", live: \"npm run db:migrate:live\"}}"
RC=0; STUB_OID="$SHA" STUB_META="$(meta needs-you:done prisma/migrations/2026/migration.sql)" gate --expect-head "$SHA" >/dev/null 2>&1 || RC=$?
[ "$RC" -eq 0 ] || fail "needs-you:done should let the gate merge, got $RC"
teardown

# 21 — an allowed migrate command that FAILS is a needs-you, and needs-you:done
#      does not excuse a command that is failing right now.
head_setup
cfgset '.migrations = {allowed_envs: ["staging"], target_env: "staging", commands: {staging: "exit 3"}}'
RC=0; OUT=$(STUB_OID="$SHA" STUB_META="$(meta needs-you:done drizzle/0001.sql)" gate --expect-head "$SHA" 2>/dev/null) || RC=$?
[ "$RC" -eq 8 ] || fail "a failing migrate command should exit 8, got $RC"
echo "$OUT" | grep -q "staging: failed in the merge gate" || fail "the failure must be named, got: $OUT"
teardown

# 22 — a human-only step declared in the PR body, on a PR with no migrations.
head_setup
RC=0; OUT=$(STUB_OID="$SHA" STUB_META="$(meta "" src/x.ts 'Notes
needs-you: `npm run backfill -- --env live`')" gate --expect-head "$SHA" 2>/dev/null) || RC=$?
[ "$RC" -eq 8 ] || fail "a needs-you: line in the body should exit 8, got $RC"
echo "$OUT" | grep -q "^needs-you: npm run backfill -- --env live" || fail "the declared step must be printed, got: $OUT"
teardown

# 23 — metadata the gate cannot read fails safe to a human (7), never to merge.
head_setup
RC=0; STUB_OID="$SHA" STUB_META='not json' gate --expect-head "$SHA" >/dev/null 2>&1 || RC=$?
[ "$RC" -eq 7 ] || fail "unreadable PR metadata should exit 7, got $RC"
teardown

# 24 — dry run: migrations are reported, never executed.
head_setup
cfgset ".migrations = {allowed_envs: [\"staging\"], target_env: \"staging\", commands: {staging: \"touch $TMP/ran\"}}"
RC=0; OUT=$(STUB_OID="$SHA" STUB_META="$(meta "" supabase/migrations/1.sql)" gate --expect-head "$SHA" --dry-run 2>&1) || RC=$?
[ "$RC" -eq 0 ] || fail "a dry run should exit 0, got $RC"
[ ! -f "$TMP/ran" ] || fail "a dry run must not run a migrate command"
echo "$OUT" | grep -q "would migrate staging" || fail "a dry run should say what it would migrate, got: $OUT"
teardown

# 25 — the glob dialect: **/ spans zero or more directories; * stays in one segment.
P="../scripts/super-board-merge-policy.py"
pol() { printf '%s' "$1" > "$T25/m.json"; python3 "$P" --config "$T25/c.json" --meta "$T25/m.json" --diff /dev/null; }
T25=$(mktemp -d); echo '{"base_branch":"staging","migrations":{"globs":["**/migrations/*.sql"]}}' > "$T25/c.json"
pol "$(meta "" migrations/1.sql)"          | jq -e '.migrations == ["migrations/1.sql"]' >/dev/null || fail "**/ should match zero directories"
pol "$(meta "" a/b/migrations/1.sql)"      | jq -e '.migrations | length == 1' >/dev/null || fail "**/ should match nested directories"
pol "$(meta "" migrations/old/1.sql)"      | jq -e '.migrations | length == 0' >/dev/null || fail "* must not cross a /"
rm -rf "$T25"

echo "PASS: test-merge-gate.sh (26 scenarios)"
