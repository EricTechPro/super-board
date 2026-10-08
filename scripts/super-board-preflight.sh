#!/usr/bin/env bash
# super-board-preflight.sh — before a card goes Ready → Building, is it worth building?
#
# Four questions, asked of every candidate card before any Builder starts:
#
#   1. Already done?        a merged PR closes it, or a merged PR / closed issue carries
#                           the same fingerprint or (near-)same title.
#   2. Already in progress? an open PR from ANOTHER branch closes it or has the same
#                           title, or another card in Building/QA/Review (or a lower-
#                           numbered Ready peer in this wave) has the same title.
#   3. File overlap?        an open PR touches files this card names, or a lower-numbered
#                           card in the same --issues batch names them. Not a duplicate —
#                           a sequencing problem. The card goes behind the issue that
#                           PR closes (blocked-by, so the wave-start sweep frees it when
#                           that issue closes), or, if the PR closes nothing, proceeds
#                           with an expected-conflict note so the merge gate rebases. Two
#                           batch peers: the lower number proceeds, the other is sequenced
#                           `blockedBy: [<lower>]` — never both against each other.
#   4. Unclear?             no `## Acceptance Criteria` section with at least one bullet.
#
# Outcomes: proceed · hold (dup done / dup in progress / unclear) · sequence.
#
# THIS SCRIPT IS THE MECHANICAL HALF. It catches what string matching can catch and
# lists near-misses (`candidates`) for the pre-flight sub-agent, which makes the
# semantic call: "same feature, different words" and "AC contradicts the code" are
# judgements, not regexes. The agent may upgrade proceed → hold on evidence; it may
# downgrade a mechanical hold only by naming why the match is a different feature.
#
# Cheap by construction: the three list calls run ONCE per invocation however many
# issues are checked (pass --issues 12,14,15 to batch a wave), plus one `gh issue
# view` per issue. The worker gh guard runs first when it is installed alongside.
#
# Usage:
#   super-board-preflight.sh --repo <owner/name> --issues <N[,M…]>
#                            [--inflight <cards.json>]   # [{number,title,status}] board cards
#                            [--files a/b.ts,c/d.ts]     # paths the card will touch (else: parsed from body)
#                            [--threshold 0.6]           # title Jaccard for a duplicate
#
# Stdout, one object keyed by issue number:
#   { "14": { "number": 14, "title": "…", "verdict": "proceed|hold|sequence",
#             "tag": "done|in-progress|unclear|overlap|clean", "reason": "…",
#             "evidence": ["#31 merged: Resolves #14"], "blockedBy": [31],
#             "conflictWith": [52], "candidates": [{"ref":"#40","kind":"open-pr","sim":0.4,"title":"…"}] } }
#
# Exit 0 ok · 64 usage · 79 required GitHub evidence unavailable (pause the run;
# a blind pre-flight never says proceed).
set -euo pipefail
# Fixed read commands: a malformed payload is GitHub's, so it halts (#32).
export SB_GITHUB_READ_STRICT=1

REPO=""; ISSUES=""; INFLIGHT=""; FILES=""; THRESHOLD="0.6"
while [ $# -gt 0 ]; do
  case "$1" in
    --repo)      REPO="$2"; shift 2 ;;
    --issues|--issue) ISSUES="$2"; shift 2 ;;
    --inflight)  INFLIGHT="$2"; shift 2 ;;
    --files)     FILES="$2"; shift 2 ;;
    --threshold) THRESHOLD="$2"; shift 2 ;;
    *) echo "unknown arg: $1" >&2; exit 64 ;;
  esac
done
[ -n "$REPO" ] && [ -n "$ISSUES" ] || { echo "usage: --repo <owner/name> --issues <N[,M…]>" >&2; exit 64; }
echo "$ISSUES" | grep -Eq '^[0-9]+(,[0-9]+)*$' || { echo "--issues must be numbers: $ISSUES" >&2; exit 64; }

HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
if [ -f "$HERE/super-board-gh-guard.sh" ]; then
  # shellcheck source=/dev/null
  . "$HERE/super-board-gh-guard.sh"
  sb_gh_guard_check 200 || exit $?
fi

MERGED=$(python3 "$HERE/super-board-github-read.py" --kind prs-merged -- pr list --repo "$REPO" --state merged --limit 100 --json number,title,body,url ) || exit $?
OPEN=$(python3 "$HERE/super-board-github-read.py" --kind prs-open -- pr list --repo "$REPO" --state open --limit 100 --json number,title,body,url,headRefName,files ) || exit $?
CLOSED=$(python3 "$HERE/super-board-github-read.py" --kind issues-closed -- issue list --repo "$REPO" --state closed --limit 100 --json number,title,body,stateReason ) || exit $?
CARDS="[]"
[ -n "$INFLIGHT" ] && CARDS=$(cat "$INFLIGHT")

TARGETS="[]"
for n in ${ISSUES//,/ }; do
  one=$(python3 "$HERE/super-board-github-read.py" --kind issue -- issue view "$n" --repo "$REPO" --json number,title,body ) || exit $?
  TARGETS=$(jq -c --argjson one "$one" '. + [$one]' <<<"$TARGETS")
done

jq -n --argjson targets "$TARGETS" --argjson merged "$MERGED" --argjson open "$OPEN" \
      --argjson closed "$CLOSED" --argjson cards "$CARDS" --arg files "$FILES" \
      --argjson th "$THRESHOLD" '
  def stop: ["the","and","for","with","from","into","when","that","this","add","fix","make","use","should","not","are","can","new"];
  def toks: ascii_downcase | [scan("[a-z0-9]+")] | map(select(length > 2)) | . - stop | unique;
  def sim($a; $b): ($a | toks) as $x | ($b | toks) as $y
    | if ($x | length) == 0 or ($y | length) == 0 then 0
      else ((($x - ($x - $y)) | length) / (($x + $y) | unique | length) * 100 | floor) / 100 end;
  # GitHub closing keywords only: a PR that merely mentions #N is not delivering it.
  def closes($n): (.body // "") | test("(?i)\\b(close[sd]?|fix(e[sd])?|resolve[sd]?)[ :]+#" + ($n | tostring) + "\\b");
  def closed_refs: [ (.body // "") | scan("(?i)\\b(?:close[sd]?|fix(?:e[sd])?|resolve[sd]?)[ :]+#([0-9]+)")[0] | tonumber ] | unique;
  def fps: [ (.body // "") | scan("(?m)^[ \t]*fingerprint:[ \t]*([^\n]*[^ \t\n])")[0] ];
  def paths: [ (.body // "") | scan("[A-Za-z0-9_.-]+(?:/[A-Za-z0-9_.-]+)+\\.[A-Za-z0-9]+") ] | unique;
  # The AC section: lines after the LAST "## Acceptance Criteria" heading, up to the next "## ".
  def has_acs: ((.body // "") / "\n") as $l
    | [ $l | to_entries[] | select(.value | test("^##[ \t]+Acceptance Criteria")) | .key ] as $h
    | if ($h | length) == 0 then false
      else [ $l[($h | last) + 1:][] ] as $t
        | ([ $t | to_entries[] | select(.value | test("^##[ \t]")) | .key ] | first) as $e
        | (if $e == null then $t else $t[:$e] end) | any(.[]; test("^[ \t]*[-*][ \t]+\\S")) end;

  [ $targets[] | . as $i | $i.number as $n
    | ($i | fps) as $myfp
    | (if $files == "" then ($i | paths) else ($files / ",") end) as $mine
    # Own branch = this card coming back (rebuild, rebase); never its own duplicate.
    | [ $open[] | select((.headRefName // "") | startswith("issue-\($n)-") | not) ] as $others

    | ( [ $merged[] | select(closes($n)) | "PR #\(.number) merged and closes #\($n)" ]
      + [ $merged[] | select(($myfp | length) > 0 and (fps - (fps - $myfp) | length) > 0)
          | "PR #\(.number) merged with the same fingerprint" ]
      + [ $merged[] | select(sim(.title; $i.title) >= $th) | "PR #\(.number) merged: \"\(.title)\"" ]
      + [ $closed[] | select(.number != $n and .stateReason != "NOT_PLANNED")
          | select(sim(.title; $i.title) >= $th or (($myfp | length) > 0 and (fps - (fps - $myfp) | length) > 0))
          | "issue #\(.number) closed: \"\(.title)\"" ] ) as $done

    | ( [ $others[] | select(closes($n)) | "open PR #\(.number) (\(.headRefName)) already closes #\($n)" ]
      + [ $others[] | select(closes($n) | not) | select(sim(.title; $i.title) >= $th)
          | "open PR #\(.number) covers it: \"\(.title)\"" ]
      + [ $cards[] | select(.number != $n)
          | select(((.status as $s | ["Building","QA","Review"] | index($s)) != null)
                   or (.status == "Ready" and .number < $n))
          | select(sim(.title; $i.title) >= $th)
          | "card #\(.number) in \(.status) covers it: \"\(.title)\"" ] ) as $busy

    | [ $others[] | select(closes($n) | not) | select(sim(.title; $i.title) < $th)
        | . as $p | [ ($p.files // [])[] | .path ] as $pf
        | ($mine - ($mine - $pf)) as $hit
        | select(($hit | length) > 0)
        | { pr: $p.number, issues: ($p | closed_refs), files: $hit } ] as $overlap

    | ( [ $merged[] | { ref: "#\(.number)", kind: "merged-pr", title, sim: sim(.title; $i.title) } ]
        + [ $others[] | { ref: "#\(.number)", kind: "open-pr", title, sim: sim(.title; $i.title) } ]
        + [ $closed[] | select(.number != $n) | { ref: "#\(.number)", kind: "closed-issue", title, sim: sim(.title; $i.title) } ]
        + [ $cards[] | select(.number != $n) | { ref: "#\(.number)", kind: "card:\(.status)", title, sim: sim(.title; $i.title) } ]
        | map(select(.sim >= 0.25 and .sim < $th)) | sort_by(-.sim) | .[:5] ) as $near

    | { number: $n, title: $i.title, candidates: $near, blockedBy: [], conflictWith: [], _files: $mine }
      + ( if ($done | length) > 0 then
            { verdict: "hold", tag: "done", reason: "already delivered", evidence: $done }
          elif ($busy | length) > 0 then
            { verdict: "hold", tag: "in-progress", reason: "already being built elsewhere", evidence: $busy }
          elif ($i | has_acs | not) then
            { verdict: "hold", tag: "unclear", reason: "no `## Acceptance Criteria` bullets", evidence: ["issue #\($n) body"] }
          elif ($overlap | length) > 0 then
            { verdict: "sequence", tag: "overlap",
              reason: "open PRs touch the same files — build after them",
              evidence: [ $overlap[] | "open PR #\(.pr) touches \(.files | join(", "))" ],
              blockedBy: ([ $overlap[].issues[] ] | unique - [$n]),
              conflictWith: [ $overlap[].pr ] }
          else
            { verdict: "proceed", tag: "clean", reason: "no duplicate, no overlap", evidence: [] }
          end ) ]
  # Peer overlap: two cards checked together name the same files and neither has an open
  # PR yet. The lower-numbered one goes first; the other waits behind it. Sequencing both
  # against each other parks both forever (#180/#181 on 2026-10-03, corpus.ts).
  | sort_by(.number)
  | reduce .[] as $c ({out: [], go: []};
      ([ .go[] | select((.files - (.files - $c._files)) | length > 0) ] | first) as $first
      | if $c.verdict == "proceed" and $first != null then
          .out += [ $c + { verdict: "sequence", tag: "overlap",
                           reason: "a lower-numbered card in this check touches the same files — build after it",
                           evidence: [ "#\($first.number) touches \(($first.files - ($first.files - $c._files)) | join(", "))" ],
                           blockedBy: [ $first.number ] } ]
        elif $c.verdict == "proceed" then
          .out += [ $c ] | .go += [ { number: $c.number, files: $c._files } ]
        else .out += [ $c ] end)
  | .out | map(del(._files))
  | INDEX(.number | tostring)'
