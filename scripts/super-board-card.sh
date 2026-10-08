#!/usr/bin/env bash
# super-board-card.sh — read and move project cards for a few GraphQL points.
#
# Why this exists: on 2026-10-04 a 3-card wave spent ~2,850 of the 5,000/hr
# GraphQL points (~950 a card) and the board stalled an hour after every wave.
# Almost all of it was board lookups, not work. Measured with
# `rateLimit(dryRun:true){cost}` against gh 2.101:
#   gh project item-list          101 points per 100-item page (fieldValues(100)
#                                 x labels/users/reviewers/pullRequests(10) each),
#                                 so a 131-card board costs ~203 per call
#   gh project field-list         101 — the same query with items(first:100),
#                                 fetched only to be thrown away
#   gh project view               2   (owner lookup + project)
#   gh issue/pr view, pr list     1 each
# Lanes moved a card as item-list + field-list + item-edit: ~305 points a move.
# This script moves one for 1 point (cached ids) or 2 (first sight of an issue),
# and lists the whole board for ~1 point per 100 cards.
#
# Usage:
#   super-board-card.sh [--config <cfg.json>] [--owner O --number N] [--repo owner/name] <verb>
#     move <issue> <Status>   set the card's Status column (Ready, QA, Review, Blocked, Done, …)
#     status <issue>          print the card's current Status name (1 point, never cached)
#     item-id <issue>         print the card's project item id (cached)
#     ids                     print {projectId, fieldId, options:{name:id}} (cached)
#     items                   the whole board in `gh project item-list --format json` shape
#                             ({items:[{id,status,labels,title,content:{type,number,title,url,repository}}],totalCount})
#
# Owner/number/repo come from --config (project.owner, project.number,
# repo.remote), else $BUILD_LOOP_OWNER / $BUILD_LOOP_PROJECT and the origin remote.
#
# Cache: <main checkout>/.claude/super-board/cache/board-<owner>-<number>.json,
# shared by every worktree. Option ids are reminted whenever someone edits the
# column list, so a failed move drops the cache, re-reads it once, and retries
# once — a stale id costs one extra point, never a wrong move.
#
# Exit: 0 ok · 64 usage · 66 config · 69 GitHub read/mutation failed ·
#       79 reads halted (super-board-github-read.py) · 3 issue not on this board /
#       Status option missing.
set -euo pipefail
# Fixed read commands: a malformed payload is GitHub's, so it halts (#32).
export SB_GITHUB_READ_STRICT=1

HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
CONFIG="${SB_CONFIG:-}"; OWNER="${BUILD_LOOP_OWNER:-}"; NUMBER="${BUILD_LOOP_PROJECT:-}"; REPO=""
while [ $# -gt 0 ]; do
  case "$1" in
    --config) CONFIG="$2"; shift 2 ;;
    --owner)  OWNER="$2"; shift 2 ;;
    --number) NUMBER="$2"; shift 2 ;;
    --repo)   REPO="$2"; shift 2 ;;
    -h|--help) sed -n '2,38p' "$0"; exit 0 ;;
    --) shift; break ;;
    -*) echo "unknown flag: $1" >&2; exit 64 ;;
    *) break ;;
  esac
done
VERB="${1:-}"; [ -n "$VERB" ] || { echo "usage: super-board-card.sh <move|status|item-id|ids|items> …" >&2; exit 64; }
shift

if [ -n "$CONFIG" ]; then
  [ -r "$CONFIG" ] || { echo "config not found: $CONFIG" >&2; exit 66; }
  CJ=$(cat "$CONFIG")
  [ -n "$OWNER" ]  || OWNER=$(echo "$CJ" | jq -r '.project.owner // ""')
  [ -n "$NUMBER" ] || NUMBER=$(echo "$CJ" | jq -r '.project.number // ""')
  [ -n "$REPO" ]   || REPO=$(echo "$CJ" | jq -r '.repo.remote // ""')
fi
[ -n "$REPO" ] || REPO=$(git remote get-url origin 2>/dev/null || true)
REPO=$(echo "$REPO" | sed -E 's#^(https?://github\.com/|git@github\.com:)##; s#\.git$##')
[ -n "$OWNER" ] && [ -n "$NUMBER" ] || { echo "project owner/number unknown: pass --config or --owner/--number" >&2; exit 66; }

# Reads go through the kit's bounded retry helper when it is installed, so a
# board read shares the run's halt file; plain gh otherwise.
gh_read() {
  if [ -f "$HERE/super-board-github-read.py" ]; then
    python3 "$HERE/super-board-github-read.py" --kind json -- "$@"
  else
    gh "$@"
  fi
}
no_errors() { jq -e 'if type == "array" then all(.[]; (.errors // null) == null) else (.errors // null) == null end' >/dev/null; }

# ── cache ───────────────────────────────────────────────────────────────
cache_dir() {
  if [ -n "${SB_CARD_CACHE_DIR:-}" ]; then echo "$SB_CARD_CACHE_DIR"; return; fi
  local common
  common=$(git rev-parse --path-format=absolute --git-common-dir 2>/dev/null || true)
  if [ -n "$common" ]; then echo "$(dirname "$common")/.claude/super-board/cache"
  else echo "$PWD/.claude/super-board/cache"; fi
}
CACHE_DIR=$(cache_dir)
CACHE="$CACHE_DIR/board-${OWNER}-${NUMBER}.json"
cache_get() { [ -s "$CACHE" ] && jq -r "($1) // empty" "$CACHE" 2>/dev/null || true; }
cache_put() {  # $1 = jq filter applied to the current cache, with --arg/--argjson in "$@"
  local filter="$1"; shift
  mkdir -p "$CACHE_DIR"
  [ -f "$CACHE_DIR/.gitignore" ] || echo '*' > "$CACHE_DIR/.gitignore"
  local cur tmp
  cur=$(cat "$CACHE" 2>/dev/null || echo '{}'); echo "$cur" | jq -e . >/dev/null 2>&1 || cur='{}'
  tmp=$(mktemp "$CACHE_DIR/.board.XXXXXX")
  echo "$cur" | jq "$@" "$filter" > "$tmp" && mv "$tmp" "$CACHE" || rm -f "$tmp"
}
cache_drop() { rm -f "$CACHE"; }

# ── reads ───────────────────────────────────────────────────────────────
load_ids() {  # fills PROJECT_ID FIELD_ID OPTIONS_JSON — 0 points when cached, else 1
  PROJECT_ID=$(cache_get .projectId); FIELD_ID=$(cache_get .fieldId)
  OPTIONS_JSON=$(cache_get '.options // empty | tojson')
  [ -n "$PROJECT_ID" ] && [ -n "$FIELD_ID" ] && [ -n "$OPTIONS_JSON" ] && return 0
  local out
  out=$(gh_read api graphql -f query='query($owner:String!,$number:Int!){
      repositoryOwner(login:$owner){ ... on ProjectV2Owner { projectV2(number:$number){ id
        field(name:"Status"){ ... on ProjectV2SingleSelectField { id options { id name } } } } } } }' \
      -F owner="$OWNER" -F number="$NUMBER") || return $?
  echo "$out" | no_errors || { echo "Status field read returned errors" >&2; return 69; }
  PROJECT_ID=$(echo "$out" | jq -r '.data.repositoryOwner.projectV2.id // empty')
  FIELD_ID=$(echo "$out" | jq -r '.data.repositoryOwner.projectV2.field.id // empty')
  OPTIONS_JSON=$(echo "$out" | jq -c '[.data.repositoryOwner.projectV2.field.options[]? | {(.name): .id}] | add // {}')
  [ -n "$PROJECT_ID" ] && [ -n "$FIELD_ID" ] || { echo "project $OWNER/$NUMBER or its Status field not found" >&2; return 69; }
  cache_put '.projectId = $p | .fieldId = $f | .options = $o' --arg p "$PROJECT_ID" --arg f "$FIELD_ID" --argjson o "$OPTIONS_JSON"
}

# One targeted query (1 point): this issue's item on this board, and its Status.
read_card() {  # $1 = issue; sets ITEM_ID STATUS_NAME
  [ -n "$REPO" ] || { echo "repo unknown: pass --repo or a config with repo.remote" >&2; return 66; }
  local out
  out=$(gh_read api graphql -f query='query($owner:String!,$name:String!,$issue:Int!){
      repository(owner:$owner,name:$name){ issueOrPullRequest(number:$issue){
        ... on Issue { projectItems(first:20){ nodes{ id project{ number owner{ ... on User{login} ... on Organization{login} } }
          fieldValueByName(name:"Status"){ ... on ProjectV2ItemFieldSingleSelectValue{ name } } } } }
        ... on PullRequest { projectItems(first:20){ nodes{ id project{ number owner{ ... on User{login} ... on Organization{login} } }
          fieldValueByName(name:"Status"){ ... on ProjectV2ItemFieldSingleSelectValue{ name } } } } } } } }' \
      -F owner="${REPO%%/*}" -F name="${REPO##*/}" -F issue="$1") || return $?
  echo "$out" | no_errors || { echo "card read for #$1 returned errors" >&2; return 69; }
  local node
  node=$(echo "$out" | jq -c --argjson n "$NUMBER" --arg o "$OWNER" '
    [.data.repository.issueOrPullRequest.projectItems.nodes[]?
     | select(.project.number == $n and ((.project.owner.login // "") | ascii_downcase) == ($o | ascii_downcase))][0] // empty')
  [ -n "$node" ] || { echo "#$1 is not on project $OWNER/$NUMBER" >&2; return 3; }
  ITEM_ID=$(echo "$node" | jq -r .id)
  STATUS_NAME=$(echo "$node" | jq -r '.fieldValueByName.name // ""')
  cache_put '.items[$k] = $v' --arg k "$1" --arg v "$ITEM_ID"
}

item_id() {  # $1 = issue
  ITEM_ID=$(cache_get ".items[\"$1\"]")
  [ -n "$ITEM_ID" ] || read_card "$1"
}

set_status() {  # $1 = item id, $2 = option id — one mutation
  local out
  out=$(gh api graphql -f query='mutation($p:ID!,$i:ID!,$f:ID!,$o:String!){
      updateProjectV2ItemFieldValue(input:{projectId:$p,itemId:$i,fieldId:$f,value:{singleSelectOptionId:$o}}){ projectV2Item{ id } } }' \
      -f p="$PROJECT_ID" -f i="$1" -f f="$FIELD_ID" -f o="$2" 2>&1) || { echo "$out" >&2; return 69; }
  echo "$out" | no_errors || { echo "$out" >&2; return 69; }
}

move() {  # $1 = issue, $2 = Status name
  local issue="$1" name="$2" opt attempt
  for attempt in 1 2; do
    load_ids || return $?
    opt=$(echo "$OPTIONS_JSON" | jq -r --arg n "$name" '.[$n] // empty')
    if [ -z "$opt" ]; then
      [ "$attempt" = 1 ] && { cache_drop; continue; }
      echo "Status option '$name' is not on project $OWNER/$NUMBER" >&2; return 3
    fi
    item_id "$issue" || return $?
    if set_status "$ITEM_ID" "$opt"; then echo "moved #$issue → $name"; return 0; fi
    [ "$attempt" = 1 ] && { echo "move failed; re-reading board ids once" >&2; cache_drop; }
  done
  return 69
}

items() {  # whole board, gh item-list shape, ~1 point per 100 cards
  local pages
  pages=$(gh_read api graphql --paginate --slurp -f query='query($owner:String!,$number:Int!,$endCursor:String){
      repositoryOwner(login:$owner){ ... on ProjectV2Owner { projectV2(number:$number){
        items(first:100, after:$endCursor){ totalCount pageInfo{ hasNextPage endCursor }
          nodes{ id fieldValueByName(name:"Status"){ ... on ProjectV2ItemFieldSingleSelectValue{ name } }
            content{ __typename
              ... on Issue { number title url repository{ nameWithOwner } labels(first:30){ nodes{ name } } }
              ... on PullRequest { number title url repository{ nameWithOwner } labels(first:30){ nodes{ name } } }
              ... on DraftIssue { title } } } } } } } }' \
      -F owner="$OWNER" -F number="$NUMBER") || return $?
  echo "$pages" | no_errors || { echo "board read returned errors" >&2; return 69; }
  echo "$pages" | jq -e '
    [ .[].data.repositoryOwner.projectV2.items ] as $p
    | ($p[0].totalCount) as $total
    | [ $p[].nodes[] | select(.content != null)
        | { id,
            title: .content.title,
            content: ({ type: .content.__typename, title: .content.title }
                      + (if .content.__typename == "DraftIssue" then {} else
                          { number: .content.number, url: .content.url,
                            repository: .content.repository.nameWithOwner } end)) }
          + (if .fieldValueByName.name then { status: .fieldValueByName.name } else {} end)
          + (if ((.content.labels.nodes // []) | length) > 0
             then { labels: [ .content.labels.nodes[].name ] } else {} end) ] as $items
    | if ($items | length) == ([ $p[].nodes[] ] | length) and ([ $p[].nodes[] ] | length) == $total
      then { items: $items, totalCount: $total }
      else error("board read incomplete: \([ $p[].nodes[] ] | length) of \($total) items") end' \
    || { echo "board read incomplete" >&2; return 69; }
}

case "$VERB" in
  move)    [ $# -eq 2 ] || { echo "usage: move <issue> <Status>" >&2; exit 64; }; move "$1" "$2" ;;
  status)  [ $# -eq 1 ] || { echo "usage: status <issue>" >&2; exit 64; }; read_card "$1"; echo "$STATUS_NAME" ;;
  item-id) [ $# -eq 1 ] || { echo "usage: item-id <issue>" >&2; exit 64; }; item_id "$1"; echo "$ITEM_ID" ;;
  ids)     load_ids; jq -n --arg p "$PROJECT_ID" --arg f "$FIELD_ID" --argjson o "$OPTIONS_JSON" '{projectId:$p, fieldId:$f, options:$o}' ;;
  items)   items ;;
  *) echo "unknown verb: $VERB" >&2; exit 64 ;;
esac
