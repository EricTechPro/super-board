#!/usr/bin/env bash
# super-board-pr-body.sh — rewrite ONE marker block of a PR body, idempotently.
#
# The PR body is a set of marker blocks (writing-standard.md § 2). Each lane owns
# some of them. Rewriting the whole body from memory clobbers the blocks another
# lane wrote since you read it; this script touches only the block you name.
#
#   super-board-pr-body.sh --pr <N> --block <name> --expect-head <sha> \
#                          (--body-file <md> | --append-file <md>) [--repo o/r] [--dry-run]
#   super-board-pr-body.sh --skeleton          # empty body with every marker, in order
#   super-board-pr-body.sh --time [--config <cfg.json>]   # "Oct 2, 10:02 EDT" in config timezone
#
# Blocks, in body order: redcheck status problem solution ac history visual risk.
# A block that is missing is inserted at its place in that order.
#
# --body-file    replaces the block's content.
# --append-file  appends lines inside the block (history rows).
# --expect-head  the PR head you based this edit on. The script refuses (exit 6) when
#                the PR head is no longer that commit: the block would describe code
#                that is not the code on the PR. Required unless --dry-run.
# --dry-run      prints the new body on stdout, edits nothing.
#
# Same content twice is a no-op ("unchanged"), so a retried lane exit is safe.
#
# Exits: 0 ok (stdout: updated | unchanged | the body on --dry-run)
#        6 PR head moved · 64 usage · 66 unreadable file · 70 gh failure
set -uo pipefail

BLOCKS="redcheck status problem solution ac history visual risk"
die() { echo "pr-body: $1" >&2; exit "$2"; }

PR=""; BLOCK=""; HEAD=""; BODY_FILE=""; APPEND_FILE=""; REPO=""; DRY=0; MODE="edit"; CONFIG=""
while [ $# -gt 0 ]; do
  case "$1" in
    --pr)          PR="$2"; shift 2 ;;
    --block)       BLOCK="$2"; shift 2 ;;
    --expect-head) HEAD="$2"; shift 2 ;;
    --body-file)   BODY_FILE="$2"; shift 2 ;;
    --append-file) APPEND_FILE="$2"; shift 2 ;;
    --repo)        REPO="$2"; shift 2 ;;
    --config)      CONFIG="$2"; shift 2 ;;
    --dry-run)     DRY=1; shift ;;
    --skeleton)    MODE="skeleton"; shift ;;
    --time)        MODE="time"; shift ;;
    *) die "unknown arg: $1" 64 ;;
  esac
done

if [ "$MODE" = "skeleton" ]; then
  for b in $BLOCKS; do
    [ "$b" = redcheck ] && continue   # only when a check was red
    printf '<!-- sb:%s -->\n<!-- /sb:%s -->\n\n' "$b" "$b"
  done
  exit 0
fi

if [ "$MODE" = "time" ]; then
  TZV=""
  [ -n "$CONFIG" ] && [ -r "$CONFIG" ] && TZV=$(jq -r '.timezone // empty' "$CONFIG" 2>/dev/null)
  if [ -n "$TZV" ]; then TZ="$TZV" date '+%b %e, %H:%M %Z' | sed 's/  */ /g'
  else date '+%b %e, %H:%M %Z' | sed 's/  */ /g'; fi
  exit 0
fi

[ -n "$PR" ] || die "--pr is required" 64
case " $BLOCKS " in *" $BLOCK "*) ;; *) die "--block must be one of: $BLOCKS (got: ${BLOCK:-<unset>})" 64 ;; esac
if [ -n "$BODY_FILE" ] && [ -n "$APPEND_FILE" ]; then die "use --body-file or --append-file, not both" 64; fi
SRC="${BODY_FILE:-$APPEND_FILE}"
[ -n "$SRC" ] || die "--body-file or --append-file is required" 64
[ -r "$SRC" ] || die "cannot read $SRC" 66
[ "$DRY" -eq 1 ] || [ -n "$HEAD" ] || die "--expect-head <sha> is required (the PR head your edit is based on)" 64

GITHUB_READ="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/super-board-github-read.py"
# REST, not `gh pr view`/`gh pr edit`: this script runs ~3 times per lane per
# card, and the REST core bucket is separate from the GraphQL one the board
# lives on. GH_REPO fills {owner}/{repo}; unset, gh uses the current checkout.
export GH_REPO="${REPO:-${GH_REPO:-}}"; [ -n "$GH_REPO" ] || unset GH_REPO
META=$(python3 "$GITHUB_READ" --kind body -- api "repos/{owner}/{repo}/pulls/$PR" --jq '{headRefOid: .head.sha, body: (.body // "")}' ) || exit $?
NOW=$(printf '%s' "$META" | jq -r '.headRefOid // empty')
if [ -n "$HEAD" ]; then
  # Short or full sha both work: the PR head must start with what you passed.
  case "$NOW" in
    "") die "cannot read the head of PR #$PR" 70 ;;
    "$HEAD"*) ;;
    *) echo "pr-body: PR #$PR head is $NOW, not $HEAD — re-read the PR and redo the edit" >&2
       exit 6 ;;
  esac
fi

OLD_TMP=$(mktemp); NEW_TMP=$(mktemp)
trap 'rm -f "$OLD_TMP" "$NEW_TMP"' EXIT
printf '%s' "$META" | jq -r '.body // ""' > "$OLD_TMP"

MODE_FLAG=replace; [ -n "$APPEND_FILE" ] && MODE_FLAG=append
python3 - "$OLD_TMP" "$SRC" "$BLOCK" "$MODE_FLAG" "$BLOCKS" > "$NEW_TMP" <<'PY' || die "could not splice the block" 70
import sys
old_path, src_path, block, mode, order = sys.argv[1:6]
order = order.split()
body = open(old_path, encoding="utf-8").read()
content = open(src_path, encoding="utf-8").read().strip("\n")
open_m, close_m = f"<!-- sb:{block} -->", f"<!-- /sb:{block} -->"

def find(name, text):
    o, c = f"<!-- sb:{name} -->", f"<!-- /sb:{name} -->"
    i = text.find(o)
    if i < 0:
        return None
    j = text.find(c, i)
    return None if j < 0 else (i, j + len(c))

span = find(block, body)
if span:
    inner = body[span[0] + len(open_m):span[1] - len(close_m)].strip("\n")
    if mode == "append":
        lines = inner.split("\n") if inner else []
        new_lines = [l for l in content.split("\n")]
        # Idempotent append: a row already present is not added twice.
        for l in new_lines:
            if l.strip() and l in lines:
                continue
            lines.append(l)
        inner = "\n".join(lines).strip("\n")
    else:
        inner = content
    out = body[:span[0]] + f"{open_m}\n{inner}\n{close_m}" + body[span[1]:]
else:
    new_block = f"{open_m}\n{content}\n{close_m}"
    idx = order.index(block)
    # Insert before the first later block that exists; else after the last earlier one; else at the end.
    pos = None
    for later in order[idx + 1:]:
        s = find(later, body)
        if s:
            pos = s[0]
            out = body[:pos] + new_block + "\n\n" + body[pos:]
            break
    if pos is None:
        for earlier in reversed(order[:idx]):
            s = find(earlier, body)
            if s:
                pos = s[1]
                out = body[:pos] + "\n\n" + new_block + body[pos:]
                break
    if pos is None:
        out = (body.rstrip("\n") + "\n\n" if body.strip() else "") + new_block + "\n"
sys.stdout.write(out)
PY

if [ "$DRY" -eq 1 ]; then cat "$NEW_TMP"; exit 0; fi
# $(…) drops trailing newlines, which GitHub does not keep either.
if [ "$(cat "$OLD_TMP")" = "$(cat "$NEW_TMP")" ]; then echo unchanged; exit 0; fi
python3 "$GITHUB_READ" --check || exit $?
jq -n --rawfile b "$NEW_TMP" '{body: $b}' | gh api -X PATCH "repos/{owner}/{repo}/pulls/$PR" --input - >/dev/null 2>&1 || { python3 "$GITHUB_READ" --halt "PR body update outcome unknown for #$PR; read the body before retrying"; exit 79; }
echo updated
