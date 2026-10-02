#!/usr/bin/env bash
# Tests hooks/cleanup-wt.py on a throwaway repo with a bare origin.
# Pins: merged work goes (fast-forward, squash, merged into a non-default base),
# unmerged work and the current worktree stay, dirty state is wip-committed, a stray
# worktree loses its folder but keeps its branch, and the recovery TSV restores.
set -euo pipefail
cd "$(dirname "$0")"
CW="$(pwd)/../hooks/cleanup-wt.py"
fail() { echo "FAIL: $1" >&2; exit 1; }

T=$(mktemp -d); T=$(cd "$T" && pwd -P)
trap 'rm -rf "$T"' EXIT
export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@t GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@t
OLD="2020-01-01T00:00:00"
GH_STUB="$T/gh"; printf '#!/bin/sh\necho "[]"\n' > "$GH_STUB"; chmod +x "$GH_STUB"
export CLEANUP_WT_GH="$GH_STUB"

git init -q --bare -b trunk "$T/origin.git"
git clone -q "$T/origin.git" "$T/repo" 2>/dev/null
R="$T/repo"
g() { git -C "$R" "$@"; }
commit() { echo "$2" > "$R/$1"; g add "$1"; GIT_COMMITTER_DATE="${3:-$OLD}" GIT_AUTHOR_DATE="${3:-$OLD}" g commit -qm "$1 $2"; }

g switch -q -c trunk 2>/dev/null || true
commit base.txt 1
g push -q origin trunk
g remote set-head origin trunk         # default branch is "trunk": nothing may assume main
g switch -q -c staging; g push -q origin staging; g switch -q trunk

g switch -q -c feat-ff;       commit ff.txt 1;  g switch -q trunk; g merge -q --ff-only feat-ff
g push -q origin feat-ff
g switch -q -c feat-squash;   commit sq.txt 1;  commit sq.txt 2; g switch -q trunk
g merge -q --squash feat-squash >/dev/null 2>&1; GIT_COMMITTER_DATE=$OLD g commit -qm "squash feat-squash"
g switch -q -c feat-staging staging; commit st.txt 1; g switch -q staging; g merge -q --ff-only feat-staging
g switch -q trunk
g switch -q -c feat-old;      commit old.txt 1; g switch -q trunk
g switch -q -c feat-today;    commit today.txt 1 "$(date +%Y-%m-%dT%H:%M:%S)"; g switch -q trunk
g switch -q -c feat-dirty;    commit dirty.txt 1; g switch -q trunk; g merge -q --ff-only feat-dirty
g switch -q -c feat-cur;      commit cur.txt 1; g switch -q trunk; g merge -q --ff-only feat-cur
g switch -q -c feat-stray;    commit stray.txt 1; g switch -q trunk
g switch -q -c feat-wtmerged; commit wtm.txt 1; g switch -q trunk; g merge -q --ff-only feat-wtmerged
g push -q origin trunk staging

g worktree add -q "$R/.claude/worktrees/wt-merged" feat-wtmerged
g worktree add -q "$R/.claude/worktrees/wt-dirty"  feat-dirty
g worktree add -q "$R/.claude/worktrees/wt-cur"    feat-cur
g worktree add -q "$T/repo-stray"                  feat-stray
echo scratch > "$R/.claude/worktrees/wt-dirty/notes.txt"
# Age the worktrees past the 24h "fresh" window.
for d in "$R"/.git/worktrees/*; do touch -t 202001010000 "$d/gitdir" "$d/commondir"; done

sha_of() { g rev-parse "$1"; }
FF_SHA=$(sha_of feat-ff)

# 1 -- dry run changes nothing and plans the right rows.
OUT=$(cd "$R" && python3 "$CW" --no-fetch)
for b in feat-ff feat-squash feat-staging feat-wtmerged; do
  printf '%s\n' "$OUT" | grep -E "^WOULD .* $b " >/dev/null || fail "dry run should plan to remove $b"$'\n'"$OUT"
done
printf '%s\n' "$OUT" | grep -E '^REVIEW .* feat-old ' >/dev/null || fail "old unmerged branch should be REVIEW"
printf '%s\n' "$OUT" | grep -E '^KEEP .* feat-today ' >/dev/null  || fail "today's unmerged branch should be KEEP"
printf '%s\n' "$OUT" | grep -q 'bases: trunk, staging' || fail "bases should be detected as trunk, staging"$'\n'"$OUT"
g rev-parse -q --verify feat-ff >/dev/null || fail "dry run must not delete anything"

# 2 -- apply from inside wt-cur: that worktree survives even though its branch is merged.
OUT=$(cd "$R/.claude/worktrees/wt-cur" && python3 "$CW" --no-fetch --apply)
gone()  { ! g rev-parse -q --verify "refs/heads/$1" >/dev/null || fail "$1 should be deleted"$'\n'"$OUT"; }
kept()  { g rev-parse -q --verify "refs/heads/$1" >/dev/null || fail "$1 should be kept"$'\n'"$OUT"; }
gone feat-ff; gone feat-squash; gone feat-staging; gone feat-wtmerged
kept feat-old; kept feat-today; kept feat-cur; kept trunk; kept staging
[ -d "$R/.claude/worktrees/wt-cur" ]      || fail "the current worktree must never be removed"
[ ! -d "$R/.claude/worktrees/wt-merged" ] || fail "merged clean worktree should be removed"
# dirty merged worktree: removed, branch kept with a wip commit holding notes.txt
[ ! -d "$R/.claude/worktrees/wt-dirty" ]  || fail "dirty merged worktree should be removed after the wip commit"
kept feat-dirty
g show feat-dirty:notes.txt | grep -q scratch || fail "wip commit should hold the dirty file"
# stray unmerged worktree: folder gone, branch kept
[ ! -d "$T/repo-stray" ] || fail "stray worktree folder should be removed"
kept feat-stray
# merged remote branch deleted (gh stub reports no open PRs); bases kept on the remote
! git -C "$T/origin.git" rev-parse -q --verify refs/heads/feat-ff >/dev/null || fail "merged remote branch should be deleted"
git -C "$T/origin.git" rev-parse -q --verify refs/heads/staging >/dev/null || fail "remote base must be kept"

# 3 -- the recovery TSV holds what was removed and restores it.
TSV=$(printf '%s\n' "$OUT" | sed -n 's/^recovery TSV: \([^ ]*\).*/\1/p')
[ -f "$TSV" ] || fail "recovery TSV missing"$'\n'"$OUT"
head -1 "$TSV" | grep -q $'^when\tkind\tname\tsha\tpath\taction\treason$' || fail "TSV header"
grep -q $'\tfeat-ff\t'"$FF_SHA"$'\t' "$TSV" || fail "TSV should record feat-ff at its SHA"
g branch feat-ff "$FF_SHA" && kept feat-ff

# 4 -- without gh, remote branches are kept.
OUT=$(cd "$R" && CLEANUP_WT_GH=/nonexistent python3 "$CW" --no-fetch --remote-only)
printf '%s\n' "$OUT" | grep -q 'gh unavailable' || fail "should note gh unavailable"
printf '%s\n' "$OUT" | grep -qE '^WOULD' && fail "nothing remote may be planned without gh"

# 5 -- --post-merge is silent unless it acts, local only, and never wip-commits.
g worktree add -q "$R/.claude/worktrees/wt-pm" feat-ff
for d in "$R"/.git/worktrees/wt-pm; do touch -t 202001010000 "$d/gitdir" "$d/commondir"; done
echo wip > "$R/.claude/worktrees/wt-pm/x.txt"
OUT=$(cd "$R" && python3 "$CW" --post-merge --base trunk </dev/null)
[ -d "$R/.claude/worktrees/wt-pm" ] || fail "--post-merge must keep a dirty worktree"
[ ! -d "$R/.claude/worktrees/wt-cur" ] || fail "wt-cur is merged and no longer current: it should go"
OUT=$(cd "$R" && python3 "$CW" --post-merge --base trunk </dev/null)
[ -z "$OUT" ] || fail "--post-merge with nothing to do should be silent, got: $OUT"
rm "$R/.claude/worktrees/wt-pm/x.txt"
OUT=$(cd "$R" && python3 "$CW" --post-merge --base trunk </dev/null)
printf '%s' "$OUT" | grep -q 'removed worktree' || fail "--post-merge should report what it removed, got: $OUT"
gone feat-ff

# 6 -- --auto records the base tips on first run and acts only after a base moves.
g branch feat-auto trunk~1 2>/dev/null || g branch feat-auto trunk
OUT=$(cd "$R" && python3 "$CW" --auto </dev/null)
kept feat-auto
[ -f "$R/.git/cleanup-wt/last-bases" ] || fail "--auto should record base tips"
commit moved.txt 1; g push -q origin trunk
OUT=$(cd "$R" && echo '{"hook_event_name":"SessionStart"}' | python3 "$CW" --auto)
gone feat-auto
printf '%s' "$OUT" | jq -e '.hookSpecificOutput.hookEventName == "SessionStart"' >/dev/null || fail "--auto under a hook should emit hook JSON, got: $OUT"

echo "PASS: test-cleanup-wt.sh"
