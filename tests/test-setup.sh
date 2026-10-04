#!/usr/bin/env bash
# Tests scripts/super-board-setup.py — onboard's 🔍 Checks, the upgrade path, config
# migration, board names, branch detection, and the GitHub board ranking / migration.
# Offline: `gh` is a stateful stub on PATH (board state in a JSON file, every call
# logged), install.sh comes from this checkout, helper skills are skipped.
#
#   bash tests/test-setup.sh
set -euo pipefail
cd "$(dirname "$0")/.."
PACK="$PWD"
SETUP="$PACK/scripts/super-board-setup.py"
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT
fail() { echo "FAIL: $1" >&2; exit 1; }
export HOME="$WORK/home"; mkdir -p "$HOME"
export SUPER_BOARD_PACK="$PACK"
q() { jq -e "$@" >/dev/null; }

# 1 — a bare folder: check is red and lists what is missing; fix installs every
#     must-have with no question, runs git init, and the re-check is green.
T="$WORK/bare"; mkdir -p "$T"
OUT=$(python3 "$SETUP" check --root "$T" || true)
echo "$OUT" | q '.green == false and (.missing | index("skill super-board")) and .git == false' \
  || fail "bare folder should be red with super-board missing: $OUT"
OUT=$(python3 "$SETUP" fix --root "$T" --no-helpers || true)
echo "$OUT" | q '.fixed | index("super-board skills, scripts and board engine installed")' || fail "fix should install: $OUT"
echo "$OUT" | q '.fixed | index("git repo created (git init)")' || fail "fix should git init: $OUT"
echo "$OUT" | q '.missing == [] and .git == true and .upgraded == false' || fail "re-check after fix should have nothing missing: $OUT"
[ -x "$T/.claude/bin/super-board-setup.py" ] || fail "the setup script installs itself into .claude/bin"
TXT=$(python3 "$SETUP" check --root "$T" --text || true)
echo "$TXT" | grep -q "✓ super-board skills, scripts and board engine present" || fail "text report should list what is present: $TXT"

# 1b — missing safety helpers must trigger a repair even on a current installation.
for helper in super-board-approval.py super-board-github-read.py; do
  rm "$T/.claude/bin/$helper"
  OUT=$(python3 "$SETUP" check --root "$T" || true)
  echo "$OUT" | q --arg helper "script $helper" '.missing | index($helper)' \
    || fail "missing $helper must be reported: $OUT"
  OUT=$(python3 "$SETUP" fix --root "$T" --no-helpers || true)
  [ -x "$T/.claude/bin/$helper" ] || fail "repair must restore $helper"
  echo "$OUT" | q '.missing == []' || fail "repair must leave no missing scripts: $OUT"
done

# 2 — upgrade: an older super-board (VERSION 1.8.2, removed skill folders, a qa-only
#     config with Skipped, old collect keys, telegram) is detected and upgraded with
#     no question, backed up first, and listed as "Upgraded for you".
T="$WORK/old"; mkdir -p "$T/.claude/skills/super-board" "$T/.claude/super-board/configs"
git -C "$T" init -q
echo "1.8.2" > "$T/.claude/skills/super-board/VERSION"
for d in super-refine cleanup-wt arch-loop; do mkdir -p "$T/.claude/skills/$d"; echo x > "$T/.claude/skills/$d/SKILL.md"; done
cat > "$T/.claude/super-board/configs/books.json" <<'JSON'
{"version":1,"variant":"qa-only","project":{"owner":"eric","number":2},
 "columns":["Ready","QA","Review","Done","Blocked","Skipped"],
 "repo":{"path":".","remote":"https://github.com/eric/books.git"},
 "collect":{"window_days":14,"errors":"auto","feedback_paths":["docs/feedback"],"lookback_runs":10},
 "refine":{"rounds":10,"qa_hook_rounds":3},"human_approves_merge":true,
 "notifications":{"channel":"telegram","chat_id":"auto","bot_identity":"eric"}}
JSON
OUT=$(python3 "$SETUP" check --root "$T" || true)
echo "$OUT" | q '.upgrade == true and .from == "1.8.2" and .old_dirs == ["super-refine","cleanup-wt","arch-loop"]' \
  || fail "older install should be detected: $OUT"
OUT=$(python3 "$SETUP" fix --root "$T" --no-helpers || true)
echo "$OUT" | q '.upgraded == true and .from == "1.8.2"' || fail "fix should report the upgrade: $OUT"
echo "$OUT" | q '.fixed | any(test("^skills updated; added .*super-collect"))' || fail "upgrade should name the added skills: $OUT"
echo "$OUT" | q '.fixed | index("removed old folders: super-refine, cleanup-wt, arch-loop")' || fail "old folders line missing: $OUT"
echo "$OUT" | q '.fixed | any(test("^config moved to the new keys"))' || fail "config line missing: $OUT"
for d in super-refine cleanup-wt arch-loop; do [ ! -e "$T/.claude/skills/$d" ] || fail "$d should be removed"; done
B=$(echo "$OUT" | jq -r .backup)
[ -f "$T/$B/.claude/skills/arch-loop/SKILL.md" ] && [ -f "$T/$B/.claude/super-board/configs/books.json" ] \
  || fail "old folders and config must be backed up first (backup: $B)"
C="$T/.claude/super-board/configs/books.json"
q '(has("variant") | not) and ._qa_all == true' "$C" || fail "variant must go, qa-only remembered for the board: $(cat "$C")"
q '.columns == ["Backlog","Ready","Building","QA","Review","Blocked","Done"]' "$C" || fail "columns must be the v3 seven"
q '.collect.sources == ["sentry","github","prs","architecture"] and (.collect | has("lookback_runs") | not)' "$C" || fail "collect keys not migrated"
q '.merge_policy.default == "human" and .notifications.channel == "session" and (.refine | has("qa_hook_rounds") | not)' "$C" \
  || fail "merge rule / notifications / refine not migrated: $(cat "$C")"
[ ! -e "$T/.claude/super-board/upgrade.json" ] || fail "upgrade.json should be cleared once the upgrade is done"
TXT=$(python3 "$SETUP" check --root "$T" --text || true)
echo "$TXT" | grep -q "Upgraded for you" && fail "a finished upgrade must not be reported again"

# 3 — migrate-config is idempotent: a second pass changes nothing.
OUT=$(python3 "$SETUP" migrate-config "$C")
echo "$OUT" | q '.changes == [] and .written == false' || fail "second migration should be a no-op: $OUT"

# 4 — system tools are never installed silently: a missing one comes back in `needs`
#     with the exact command for this OS.
#     A curated PATH, not "/usr/bin:/bin": GitHub's ubuntu runners ship gh in /usr/bin.
NOBIN="$WORK/nobin"; mkdir -p "$NOBIN"
for t in git apt-get dnf; do p=$(command -v "$t" || true); [ -n "$p" ] && ln -sf "$p" "$NOBIN/$t"; done
OUT=$(PATH="$NOBIN" "$(command -v python3)" "$SETUP" check --root "$T" || true)
echo "$OUT" | q '.needs | map(.name) | index("gh")' || fail "missing gh should be in needs: $OUT"
case "$(uname)" in Darwin) echo "$OUT" | q '.needs[] | select(.name == "gh") | .command == "brew install gh"' || fail "mac command should be brew: $OUT" ;; esac
echo "$OUT" | q '.needs[] | select(.name == "node") | .command | test("skills@latest add mattpocock/skills")' \
  || fail "the node command should also add Matt Pocock's skills: $OUT"

# 5 — board names from package.json / README; an empty folder falls back to its name.
T="$WORK/ledgerly"; mkdir -p "$T"
echo '{"name":"ledgerly"}' > "$T/package.json"; printf '# Ledgerly — bookkeeping for freelancers\n' > "$T/README.md"
python3 "$SETUP" names --root "$T" | q '.names == ["Ledgerly board","Ledgerly build board"]' || fail "names from package.json/README wrong"
mkdir -p "$WORK/my-app"
python3 "$SETUP" names --root "$WORK/my-app" | q '.names[0] == "my-app board"' || fail "empty folder should use its name"

# 6 — branch: main + vercel.json, no staging → recommend creating staging from main.
T="$WORK/br"; mkdir -p "$T"; git -C "$T" init -q -b main; echo '{}' > "$T/vercel.json"
git -C "$T" add . && git -C "$T" -c user.email=t@t -c user.name=t commit -qm init
OUT=$(python3 "$SETUP" branch --root "$T")
echo "$OUT" | q '.create_staging == true and .deploy == "Vercel deploys main" and .create_command == "git push origin main:staging"' \
  || fail "no staging should recommend creating it: $OUT"
git -C "$T" branch staging
python3 "$SETUP" branch --root "$T" | q '.staging == "staging" and .create_staging == false' || fail "existing staging should be used"

# ── gh stub: state in $GH_STATE, calls in $GH_LOG ──────────────────────────────
mkdir -p "$WORK/bin"
cat > "$WORK/bin/gh" <<'PY'
#!/usr/bin/env python3
import json, os, sys
a = sys.argv[1:]
st = json.load(open(os.environ["GH_STATE"]))
open(os.environ["GH_LOG"], "a").write(" ".join(a) + "\n")
def save(): json.dump(st, open(os.environ["GH_STATE"], "w"))
def page(rows, cursor=None):
    start = int(cursor or 0); end = start + 100
    return {"nodes": rows[start:end], "totalCount": len(rows),
            "pageInfo": {"hasNextPage": end < len(rows), "endCursor": str(end)}}
def node(it):
    status = None if it.get("status") is None else {"name": it["status"], "optionId": next(o["id"] for o in st["options"]["2"] if o["name"] == it["status"])}
    n = it["content"]["number"]
    return {"id": it["id"], "updatedAt": it.get("updatedAt", "t0"), "type": "ISSUE", "status": status,
            "content": {"__typename": "Issue", "id": "ISS"+str(n), "number": n, "repository": {"nameWithOwner": "eric/books"},
                        "labels": page([{"name": n} for n in it.get("labels", [])])}}
if a[:2] == ["project", "list"]:
    print(json.dumps({"projects": st["projects"]}))
elif a[:2] == ["project", "field-list"]:
    n = a[2]
    print(json.dumps({"fields": [{"id": "F" + n, "name": "Status", "type": "ProjectV2SingleSelectField",
                                  "options": [{"id": o["id"], "name": o["name"]} for o in st["options"].get(n, [])]}]}))
elif a[:2] == ["project", "view"]:
    print(json.dumps({"id": "P" + a[2], "url": "https://github.com/users/eric/projects/" + a[2]}))
elif a[:2] == ["project", "item-list"]:
    items = st["items"]
    if st.get("hide_status"):  # a gh that does not surface the Status column
        items = [{k: v for k, v in it.items() if k != "status"} for it in items]
    else:  # like gh: no key on a card with no status
        items = [{k: v for k, v in it.items() if not (k == "status" and v is None)} for it in items]
    print(json.dumps({"items": items}))
elif a[:2] == ["project", "item-edit"]:
    item, opt = a[a.index("--id") + 1], a[a.index("--single-select-option-id") + 1]
    name = next(o["name"] for o in st["options"]["2"] if o["id"] == opt)
    for it in st["items"]:
        if it["id"] == item: it["status"], it["updatedAt"] = name, it.get("updatedAt", "t0") + "w"
    save()
elif a[:2] == ["api", "graphql"]:
    body = json.loads(sys.stdin.read())
    if body["query"].startswith("query"):
        query, v = body["query"], body["variables"]
        if "items(first:" in query:
            value = {"items": page([node(it) for it in st["items"]], v.get("after"))}
        elif "... on ProjectV2Item{" in query:
            value = node(next(it for it in st["items"] if it["id"] == v["id"]))
        elif "... on Issue{" in query:
            it = next(it for it in st["items"] if "ISS"+str(it["content"]["number"]) == v["id"])
            value = {"labels": page([{"name": n} for n in it.get("labels", [])], v.get("after"))}
        else:
            value = {"options": st["options"]["2"]}
        print(json.dumps({"data": {"node": value}}))
    else:
        st["gen"] = st.get("gen", 0) + 1
        new = [{"id": f"o{st['gen']}-{i}", "name": o["name"], "color": o["color"], "description": o["description"]}
               for i, o in enumerate(body["variables"]["opts"])]
        st["options"]["2"] = new
        names = {o["name"] for o in new}
        # Rewriting options can clear every card status; early scenarios only clear Ready.
        for it in st["items"]:
            if st.get("wipe_all") or it.get("status") == "Ready" or it.get("status") not in names: it["status"] = None
        save()
        print(json.dumps({"data": {"updateProjectV2Field": {"projectV2Field": {"options": [{"id": o["id"], "name": o["name"]} for o in new]}}}}))
elif a[0] == "api" and a[1].startswith("repos/"):
    print(json.dumps([[{"name": n} for n in st["labels"]]]))
elif a[:2] == ["label", "list"]:
    print(json.dumps([{"name": n} for n in st["labels"]]))
elif a[:2] == ["label", "create"]:
    st["labels"].append(a[2]); save()
elif a[:2] == ["issue", "edit"]:
    it = next(it for it in st["items"] if str(it["content"]["number"]) == a[2])
    labels = set(it.get("labels", []))
    if "--add-label" in a: labels.update(a[a.index("--add-label")+1].split(","))
    if "--remove-label" in a: labels.difference_update(a[a.index("--remove-label")+1].split(","))
    it["labels"] = sorted(labels); save()
else:
    sys.exit(f"unexpected gh call: {a}")
PY
chmod +x "$WORK/bin/gh"
export GH_STATE="$WORK/gh.json" GH_LOG="$WORK/gh.log"

# 7 — board-rank: open boards ranked by matching columns; the best is recommended only
#     with ≥ 4 of 7, and missing columns are named.
cat > "$GH_STATE" <<'JSON'
{"projects":[{"number":2,"title":"Old","url":"u2","items":{"totalCount":3}},
             {"number":4,"title":"Ledgerly Roadmap","url":"u4","items":{"totalCount":31}},
             {"number":7,"title":"Closed","url":"u7","closed":true,"items":{"totalCount":9}}],
 "options":{"2":[{"id":"a","name":"Todo"},{"id":"b","name":"Done"}],
            "4":[{"id":"1","name":"Backlog"},{"id":"2","name":"Ready"},{"id":"3","name":"Building"},
                 {"id":"4","name":"Review"},{"id":"5","name":"Blocked"},{"id":"6","name":"Done"}]},
 "items":[],"labels":[]}
JSON
OUT=$(PATH="$WORK/bin:$PATH" python3 "$SETUP" board-rank --owner eric)
echo "$OUT" | q '.recommend == 4 and .boards[0].number == 4 and .boards[0].matches == 6 and .boards[0].missing == ["QA"]' \
  || fail "best board should be #4 with QA missing: $OUT"
echo "$OUT" | q '[.boards[].number] | index(7) | not' || fail "closed boards are not offered: $OUT"
jq '.projects = [.projects[0]]' "$GH_STATE" > "$WORK/s" && mv "$WORK/s" "$GH_STATE"
PATH="$WORK/bin:$PATH" python3 "$SETUP" board-rank --owner eric | q '.recommend == null' \
  || fail "a board with 1 of 7 columns should not be recommended"

# 8 — board-migrate: adds missing columns, creates the three labels, maps old labels,
#     labels a qa-only board's cards qa, moves Skipped cards to Done, removes Skipped,
#     and restores every status the option rewrite cleared. No card is lost.
cat > "$GH_STATE" <<'JSON'
{"projects":[],"labels":["bug"],
 "options":{"2":[{"id":"r","name":"Ready","color":"BLUE","description":"go"},{"id":"q","name":"QA","color":"ORANGE","description":""},
                 {"id":"v","name":"Review","color":"PURPLE","description":""},{"id":"d","name":"Done","color":"GREEN","description":""},
                 {"id":"b","name":"Blocked","color":"RED","description":""},{"id":"s","name":"Skipped","color":"GRAY","description":""}]},
 "items":[{"id":"I1","status":"Skipped","content":{"type":"Issue","number":1}},
          {"id":"I2","status":"Ready","labels":["build"],"content":{"type":"Issue","number":2}},
          {"id":"I3","status":"Ready","content":{"type":"Issue","number":3}},
          {"id":"I4","status":"Review","labels":["qa"],"content":{"type":"Issue","number":4}}]}
JSON
: > "$GH_LOG"
CFG="$WORK/books.json"
echo '{"project":{"owner":"eric","number":2},"repo":{"remote":"https://github.com/eric/books.git"},"_qa_all":true}' > "$CFG"
OUT=$(PATH="$WORK/bin:$PATH" python3 "$SETUP" board-migrate --root "$WORK/board8" --config "$CFG")
echo "$OUT" | q '.added_columns == ["Backlog","Building"] and .labels_created == ["qa","feature"]' || fail "columns/labels wrong: $OUT"
echo "$OUT" | q '.labels_mapped == 1 and .qa_labelled == 1 and .skipped_moved == 1 and .skipped_removed == true' \
  || fail "mapping / qa-all / Skipped counts wrong: $OUT"
grep -q -- "issue edit 2 --repo eric/books --add-label feature --remove-label build" "$GH_LOG" || fail "build should map to feature"
grep -q -- "issue edit 3 --repo eric/books --add-label qa" "$GH_LOG" || fail "an unlabelled card on a qa-only board gets qa"
q '[.options["2"][].name] == ["Backlog","Ready","Building","QA","Review","Blocked","Done"]' "$GH_STATE" \
  || fail "options should be the v3 seven, Skipped gone: $(jq -c '.options["2"]' "$GH_STATE")"
q '[.items[] | {(.id): .status}] | add == {"I1":"Done","I2":"Ready","I3":"Ready","I4":"Review"}' "$GH_STATE" \
  || fail "every card must keep its column (Skipped → Done): $(jq -c .items "$GH_STATE")"
echo "$OUT" | q '.restored >= 2' || fail "cleared statuses must be restored: $OUT"
q '. == {"I1":"Skipped","I2":"Ready","I3":"Ready","I4":"Review"}' "$(echo "$OUT" | jq -r .status_backup)" \
  || fail "the pre-rewrite snapshot is saved to disk: $OUT"
q 'has("_qa_all") | not' "$CFG" || fail "the qa-all marker is dropped once applied"

# 9 — a brand-new board: --prune-empty swaps GitHub's default Todo / In Progress for the seven.
cat > "$GH_STATE" <<'JSON'
{"projects":[],"labels":["qa","bug","feature"],
 "options":{"2":[{"id":"t","name":"Todo","color":"GRAY","description":""},{"id":"p","name":"In Progress","color":"YELLOW","description":""},
                 {"id":"d","name":"Done","color":"GREEN","description":""}]},"items":[]}
JSON
OUT=$(PATH="$WORK/bin:$PATH" python3 "$SETUP" board-migrate --root "$WORK/board9" --owner eric --number 2 --repo eric/books --prune-empty)
q '[.options["2"][].name] == ["Backlog","Ready","Building","QA","Review","Blocked","Done"]' "$GH_STATE" \
  || fail "a new board should end with exactly the seven: $(jq -c '.options["2"]' "$GH_STATE")"
echo "$OUT" | q '.labels_created == []' || fail "existing labels are not created again: $OUT"

# 10 — --prune-empty on a live board that already has the seven: the option rewrite wipes
#      EVERY card's status (as GitHub does), and the restore must still run — it used to
#      run only for added columns or Skipped, so 114 cards fell to "No status".
cat > "$GH_STATE" <<'JSON'
{"projects":[],"labels":["qa","bug","feature"],"wipe_all":true,
 "options":{"2":[{"id":"k","name":"Backlog","color":"GRAY","description":""},{"id":"r","name":"Ready","color":"BLUE","description":""},
                 {"id":"u","name":"Building","color":"YELLOW","description":""},{"id":"q","name":"QA","color":"ORANGE","description":""},
                 {"id":"v","name":"Review","color":"PURPLE","description":""},{"id":"b","name":"Blocked","color":"RED","description":""},
                 {"id":"d","name":"Done","color":"GREEN","description":""},{"id":"t","name":"Todo","color":"GRAY","description":""}]},
 "items":[{"id":"I1","status":"Done","content":{"type":"Issue","number":1}},
          {"id":"I2","status":"Building","content":{"type":"Issue","number":2}},
          {"id":"I3","status":"Review","content":{"type":"Issue","number":3}},
          {"id":"I4","status":null,"content":{"type":"Issue","number":4}}]}
JSON
: > "$GH_LOG"
OUT=$(PATH="$WORK/bin:$PATH" python3 "$SETUP" board-migrate --owner eric --number 2 --repo eric/books --prune-empty --root "$WORK")
q '[.options["2"][].name] == ["Backlog","Ready","Building","QA","Review","Blocked","Done"]' "$GH_STATE" \
  || fail "the unused Todo should be pruned: $(jq -c '.options["2"]' "$GH_STATE")"
q '[.items[] | {(.id): .status}] | add == {"I1":"Done","I2":"Building","I3":"Review","I4":null}' "$GH_STATE" \
  || fail "prune-empty must put every wiped status back: $(jq -c .items "$GH_STATE")"
echo "$OUT" | q '.restored == 3' || fail "three cards should be restored: $OUT"
BK=$(echo "$OUT" | jq -r .status_backup)
case "$BK" in "$WORK/.claude/super-board/backup/board-2-"*.json) ;; *) fail "backup path wrong: $BK" ;; esac
q '. == {"I1":"Done","I2":"Building","I3":"Review","I4":null}' "$BK" || fail "backup must hold the pre-rewrite statuses: $(cat "$BK")"

# 11 — a gh that does not surface `status`: the snapshot falls back to GraphQL
#      fieldValueByName("Status"), so the restore still has something to restore.
jq '.items = [{"id":"I1","status":"Done","content":{"type":"Issue","number":1}},{"id":"I2","status":"Building","content":{"type":"Issue","number":2}}] | .hide_status = true
    | .options["2"] += [{"id":"t","name":"Todo","color":"GRAY","description":""}]' "$GH_STATE" > "$WORK/s" && mv "$WORK/s" "$GH_STATE"
OUT=$(PATH="$WORK/bin:$PATH" python3 "$SETUP" board-migrate --owner eric --number 2 --repo eric/books --prune-empty --root "$WORK")
q '[.items[] | {(.id): .status}] | add == {"I1":"Done","I2":"Building"}' "$GH_STATE" \
  || fail "statuses read over GraphQL must be restored: $(jq -c .items "$GH_STATE") $OUT"
echo "$OUT" | q '.restored == 2' || fail "two cards restored via the GraphQL snapshot: $OUT"

# 12 — --dry-run writes nothing: no option rewrite, no card move, no label, no backup file.
jq '.items = [{"id":"I1","status":"Skipped","content":{"type":"Issue","number":1}},
              {"id":"I2","status":"Ready","labels":["build"],"content":{"type":"Issue","number":2}}]
    | .hide_status = false | .labels = [] | del(.gen)
    | .options["2"] = [{"id":"r","name":"Ready","color":"BLUE","description":""},{"id":"s","name":"Skipped","color":"GRAY","description":""}]' \
  "$GH_STATE" > "$WORK/s" && mv "$WORK/s" "$GH_STATE"
cp "$GH_STATE" "$WORK/before.json"; : > "$GH_LOG"; rm -rf "$WORK/dry"; mkdir -p "$WORK/dry"
OUT=$(PATH="$WORK/bin:$PATH" python3 "$SETUP" board-migrate --owner eric --number 2 --repo eric/books --prune-empty --qa-all --dry-run --root "$WORK/dry")
cmp -s "$GH_STATE" "$WORK/before.json" || fail "dry-run changed board state: $(cat "$GH_STATE")"
! grep -Eq '^(project item-edit|label create|issue edit)' "$GH_LOG" || fail "dry-run made a write: $(cat "$GH_LOG")"
[ "$(grep -c '^api graphql' "$GH_LOG")" = 2 ] || fail "dry-run should only read options and the complete card snapshot over GraphQL: $(cat "$GH_LOG")"
[ ! -e "$WORK/dry/.claude" ] || fail "dry-run must not write a backup file"
echo "$OUT" | q '.status_backup == null and .restored == 0 and .added_columns != []' || fail "dry-run report wrong: $OUT"

echo "PASS: test-setup.sh (12 scenarios)"
