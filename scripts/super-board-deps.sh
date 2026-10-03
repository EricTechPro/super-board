#!/usr/bin/env bash
# super-board-deps.sh — work out, for every open issue, whether it can start now.
#
# Two sources, in precedence order:
#   1. the last `blocked-by:` line in the issue's Block comments (what a lane
#      wrote when it most recently parked the card)
#   2. the issue body's `## Blocked by` section (what the ticket was written with)
#
# This is the dependency primitive. The wave planner uses it to size a wave and to
# sweep the Blocked column; anything else that needs to know "what is waiting on
# what" should call this rather than re-parse issue bodies.
#
# WHY A SEPARATE SCRIPT, AND WHY IT IS FUSSY
#
# Parsing this section naively gets it wrong in three ways that were all observed
# on a real board on 2026-08-20:
#
#   1. The preflight banner at the top of every super-board ticket quotes the words
#      "## Blocked by" inside backticks. A parser that takes the FIRST match reads
#      the banner and finds no blockers. This takes the LAST heading-shaped match.
#
#   2. Tickets written by `to-tickets` follow its template, whose example line is
#      `**Blocked by:** … or "None — can start immediately"`. In practice that
#      produced lines like:
#
#          - None — but #26 must be merged first, since this edits the module it builds.
#
#      A human reads one blocker. A parser reads the word "None" and builds it
#      early. Any line that says None AND names an issue is UNPARSEABLE, never
#      "no blockers" — see the fail-safe rule below.
#
#   3. A missing section and an empty section both mean "nothing was written",
#      which is not the same as "nothing blocks this". Both are UNPARSEABLE.
#
# FAIL SAFE, NOT FAIL OPEN. An issue this script cannot read confidently is
# reported `parseable: false` and callers must treat it as blocked. Guessing
# "runnable" on an ambiguous line is how a card gets built against a base branch
# that does not have what it needs yet — one wave saved, one rewrite spent.
#
# Usage:
#   super-board-deps.sh --repo <owner/name> [--issues 12,34] [--from <payload.json>]
#
# Stdout, one object keyed by issue number:
#   { "40": { "number": 40, "title": "…", "state": "OPEN",
#             "blockers": [32,36], "openBlockers": [32],
#             "parseable": true, "humanGated": false, "runnable": false, "why": "",
#             "needsYou": false, "needsYouDone": false } }
#
# `needsYou` — the newest Block comment carries the 🙋 reason tag, or the issue
# has the `needs-you` label: a human-only command is waiting (block-template.md).
# `needsYouDone` — the human said it is done: the issue has the `needs-you:done`
# label, or a comment AFTER that 🙋 comment reads just "done". The wave planner
# reports these in `resume`; they go back to Review and the merge gate re-runs.
# A 🙋 card stays humanGated either way — only the resume path moves it.
#
# `runnable` is true only when the line parses, no blocker is still open, AND the
# card is not human-gated. `humanGated` comes from `blocked-by: -`, which means
# "nothing on this board clears it" — credentials, permissions, a product ruling.
# The sweep must never free one of those; only a person can.
set -euo pipefail

REPO=""; LIMIT="200"; ONLY=""; FROM=""
while [ $# -gt 0 ]; do
  case "$1" in
    --repo)   REPO="$2"; shift 2 ;;
    --limit)  LIMIT="$2"; shift 2 ;;
    --issues) ONLY="$2"; shift 2 ;;
    --from)   FROM="$2"; shift 2 ;;   # a saved `gh issue list --json …` payload; tests use this
    *) echo "unknown arg: $1" >&2; exit 64 ;;
  esac
done

# Open issues carry the graph; closed ones are only needed to answer "is this
# blocker still open?", which `openBlockers` derives from the open set itself.
if [ -n "$FROM" ]; then
  ISSUES=$(cat "$FROM")
else
  [ -n "$REPO" ] || { echo "--repo <owner/name> is required" >&2; exit 64; }
  # GraphQL rather than `gh issue list`, because the lanes' `blocked-by:` line
  # lives in a COMMENT and the REST list cannot return comments. One query gets
  # bodies and comments together; `gh issue view` per issue would be one REST
  # call each, and a 35-card board burns that budget for no reason.
  ISSUES=$(gh api graphql --paginate --slurp -f query='
    query($owner:String!,$repo:String!,$endCursor:String){
      repository(owner:$owner,name:$repo){
        issues(states:OPEN,first:100,after:$endCursor){
          pageInfo{ hasNextPage endCursor }
          nodes{ number title body state labels(first:30){ nodes{ name } } comments(last:8){ nodes{ body } } }
        }
      }
    }' -F owner="${REPO%%/*}" -F repo="${REPO##*/}" 2>/dev/null \
    | jq '[ .[].data.repository.issues.nodes[] ]') || {
    echo "could not read issues for $REPO" >&2; exit 69; }
fi

echo "$ISSUES" | jq --arg only "$ONLY" '
  # ---- the parser ---------------------------------------------------------
  # Everything after the LAST "## Blocked by" heading, stopping at the next
  # "## " heading so a following section is never swallowed.
  def section:
    ( . / "\n" ) as $lines
    | [ $lines | to_entries[] | select(.value | test("^##[ \t]+Blocked by[ \t]*$")) | .key ] as $heads
    | if ($heads | length) == 0 then null
      else ( $heads | last ) as $at
        # Take the lines after the heading, then cut at the first line that is
        # itself a heading. Done by index rather than by substituting a sentinel
        # string: a sentinel has to be a value no real line can equal, and the
        # obvious choices are control characters — which is how a NUL byte ended
        # up in this script and made git treat it as a binary file.
        | [ $lines[($at + 1):][] ] as $tail
        | ( [ $tail | to_entries[] | select(.value | test("^##[ \t]")) | .key ] | first ) as $end
        | if $end == null then $tail else $tail[:$end] end
      end;

  # Issue numbers on a bullet: "- #32 — The price feed" -> 32
  def refs: [ .[] | select(test("^[ \t]*-[ \t]*#[0-9]+"))
                  | capture("^[ \t]*-[ \t]*#(?<n>[0-9]+)").n | tonumber ];

  # A BULLET that claims None while naming an issue is the landmine of 2026-08-20.
  # Restricted to bullets on purpose: a blockquote underneath may legitimately
  # explain why a past blocker no longer applies, and naming it there is history,
  # not a dependency. Only the bullet is the machine-read line.
  def none_but_names: any(.[];
        (test("^[ \t]*-[ \t]*[Nn]one")) and (test("#[0-9]+")));

  def blank: (map(select(test("[^ \t]"))) | length) == 0;

  # The lanes write `blocked-by: 32, 91` as the last line of a Block comment. The
  # most recent one wins over the issue body: a lane that just parked the card
  # knows why, and the `## Blocked by` in the body may be weeks older.
  #
  # `blocked-by: -` is NOT "no blockers". It means nothing on this board clears
  # it — a credentials, permissions or product-decision block — so the card is
  # parseable AND deliberately not runnable. Only a person moves it.
  def comment_line:
    [ (.comments.nodes // .comments // [])[]
      | (.body // "") | split("\n")[]
      | select(test("^[ \t]*blocked-by:"; "i")) ]
    | last // null;

  def bodies: [ (.comments.nodes // .comments // [])[] | (.body // "") ];
  def label_names: [ (.labels.nodes // .labels // [])[] | (.name // "") ];
  # Index of the newest 🙋 Block comment, or null.
  def needs_at: ( bodies | to_entries
                  | map(select(.value | test("Reason tag:[^\n]*🙋"))) | last | .key ) // null;
  def needs_you: (label_names | index("needs-you") != null) or (needs_at != null);
  def needs_you_done:
    (label_names | index("needs-you:done") != null)
    or ( needs_at as $at | $at != null
         and ( bodies[($at + 1):] | any(.[]; test("^[ \t\n]*done[.!]?[ \t\n]*$"; "i")) ) );

  ( [ .[] | .number ] ) as $open
  | ( if $only == "" then null else ($only / "," | map(tonumber)) end ) as $filter
  | [ .[]
      | . as $i
      | ($i.body | section) as $sec
      | ($i | comment_line) as $cl
      | ( if $cl != null then
            ( $cl | capture("blocked-by:[ \t]*(?<v>.*)$"; "i").v | gsub("[ \t]"; "") ) as $v
            | if $v == "-" or $v == "" then
                { parseable: true, blockers: [], human_gated: true, why: "" }
              elif ($v | test("^[0-9]+(,[0-9]+)*$")) then
                { parseable: true, blockers: ($v / "," | map(tonumber)), human_gated: false, why: "" }
              else
                { parseable: false, blockers: [], human_gated: false,
                  why: ("the `blocked-by:` line reads \"" + $v + "\" — it must be issue numbers alone, or `-`") }
              end
          elif $sec == null then
            { parseable: false, blockers: [], human_gated: false,
              why: "no `## Blocked by` section — silence is not the same as None" }
          elif ($sec | blank) then
            { parseable: false, blockers: [], human_gated: false,
              why: "`## Blocked by` section is empty — write `- None.` if nothing blocks it" }
          elif ($sec | none_but_names) then
            { parseable: false, blockers: ($sec | refs), human_gated: false,
              why: "the section says None and then names an issue — a planner reads no blocker, a human reads one" }
          elif (($sec | refs) | length) > 0 then
            { parseable: true, blockers: ($sec | refs), human_gated: false, why: "" }
          elif ($sec | any(.[]; test("^[ \t]*-?[ \t]*[Nn]one"))) then
            { parseable: true, blockers: [], human_gated: false, why: "" }
          else
            { parseable: false, blockers: [], human_gated: false,
              why: "`## Blocked by` section has no `- #N` bullets and no `- None.`" }
          end ) as $p
      | ( [ $p.blockers[] | select(. as $b | $open | index($b)) ] ) as $stillOpen
      | { number: $i.number, title: $i.title, state: $i.state,
          blockers: $p.blockers, openBlockers: $stillOpen,
          parseable: $p.parseable,
          humanGated: $p.human_gated,
          runnable: ($p.parseable and ($p.human_gated | not) and (($stillOpen | length) == 0)),
          why: $p.why,
          needsYou: ($i | needs_you),
          needsYouDone: (($i | needs_you) and ($i | needs_you_done)) }
    ]
  | ( if $filter == null then . else map(select(.number as $n | $filter | index($n))) end )
  | INDEX(.number | tostring)'
