#!/usr/bin/env bash
# ui-refine-loop finish: commit the before/after screenshots to the refine branch
# and print the PR's Before | After table, each image linked by a raw GitHub URL
# pinned to the commit sha (never a public upload site). Run after the loop.
#
#   pr-shots.sh --worktree <wt> --run <runDir> --slug <slug> --final <label>
#               [--state main] [--repo owner/name] [--no-commit]
#
# Copies <run>/shots/round-0-<state>-<viewport>-<theme>.png and the --final
# label's matching shots to <wt>/docs/ui-refine/<slug>/{before,after}-<viewport>-<theme>.png,
# commits them as "💄 [ui] <slug>: before/after screenshots", and prints the
# Before | After table on stdout (writing-standard.md § 2: two columns, one row
# per viewport and theme, both shas in the header — before = <run>/base, after =
# the code the final shots show). The links resolve once the branch is pushed.
# --repo defaults to the origin remote. --no-commit only prints (for tests or
# a re-run after the commit exists).
#
# Exit codes: 0 ok · 64 usage · 70 failed (no shots, no GitHub remote)
set -euo pipefail
die() { echo "pr-shots: $1" >&2; exit "${2:-70}"; }

WT="" RUN="" SLUG="" FINAL="" STATE="main" REPO="" COMMIT=1
while [ $# -gt 0 ]; do
  case "$1" in
    --worktree) WT="$2"; shift 2 ;;
    --run) RUN="$2"; shift 2 ;;
    --slug) SLUG="$2"; shift 2 ;;
    --final) FINAL="$2"; shift 2 ;;
    --state) STATE="$2"; shift 2 ;;
    --repo) REPO="$2"; shift 2 ;;
    --no-commit) COMMIT=0; shift ;;
    *) die "unknown arg $1" 64 ;;
  esac
done
[ -n "$WT" ] && [ -n "$RUN" ] && [ -n "$SLUG" ] && [ -n "$FINAL" ] || die "needs --worktree --run --slug --final" 64
[ -d "$RUN/shots" ] || die "no shots dir at $RUN/shots" 70

if [ -z "$REPO" ]; then
  url=$(git -C "$WT" remote get-url origin 2>/dev/null || true)
  REPO=$(printf '%s' "$url" | sed -nE 's#^(git@github\.com:|ssh://git@github\.com/|https://([^@/]+@)?github\.com/)([^/]+/[^/]+)$#\3#p' | sed 's/\.git$//')
  [ -n "$REPO" ] || die "origin is not a GitHub remote ($url); pass --repo owner/name" 70
fi

DEST="docs/ui-refine/$SLUG"
mkdir -p "$WT/$DEST"
copied=0
for vp in desktop mobile; do
  for theme in light dark; do
    for side in before after; do
      label=$([ "$side" = before ] && echo round-0 || echo "$FINAL")
      src="$RUN/shots/$label-$STATE-$vp-$theme.png"
      [ -f "$src" ] && cp "$src" "$WT/$DEST/$side-$vp-$theme.png" && copied=$((copied + 1))
    done
  done
done
[ "$copied" -gt 0 ] || die "no round-0 or $FINAL shots for state $STATE in $RUN/shots" 70

short() { git -C "$WT" rev-parse --short "$1" 2>/dev/null || printf '%s' "$1" | cut -c1-7; }
BEFORE_SHA="round-0"
[ -s "$RUN/base" ] && BEFORE_SHA=$(short "$(head -1 "$RUN/base")")
AFTER_SHA=$(short HEAD)
if [ "$COMMIT" = 1 ]; then
  git -C "$WT" add -- "$DEST"
  git -C "$WT" diff --cached --quiet -- "$DEST" || git -C "$WT" commit -q \
    -m "💄 [ui] $SLUG: before/after screenshots" \
    -m "- round-0 and $FINAL shots, desktop + mobile, light + dark" -- "$DEST"
fi
SHA=$(git -C "$WT" rev-parse HEAD)
# On a --no-commit re-run HEAD is the screenshot commit; the code it shows is its parent.
if [ "$COMMIT" = 0 ] && git -C "$WT" log -1 --format=%s | grep -q ': before/after screenshots$'; then
  AFTER_SHA=$(short HEAD~1)
fi

cell() {
  local f="$DEST/$1"
  if [ -f "$WT/$f" ]; then printf '<img src="https://github.com/%s/raw/%s/%s" width="%s">' "$REPO" "$SHA" "$f" "$2"; else printf 'not shot'; fi
}
echo "| | Before \`$BEFORE_SHA\` | After \`$AFTER_SHA\` ($FINAL) |"
echo "|---|---|---|"
for vp in desktop mobile; do
  for theme in light dark; do
    w=$([ "$vp" = desktop ] && echo 480 || echo 220)
    name=$([ "$vp" = desktop ] && echo "Desktop 1440" || echo "Mobile 390")
    echo "| $name · $theme | $(cell "before-$vp-$theme.png" "$w") | $(cell "after-$vp-$theme.png" "$w") |"
  done
done
