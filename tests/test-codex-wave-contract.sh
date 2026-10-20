#!/usr/bin/env bash
# The Codex wave hands the orchestrator the same {cards:[summary...], halted} contract as
# workflows/super-board-wave.js. Expected summary keys are read from the workflow itself.
# Stubbed Codex only (tests/fixtures/fake_codex.py). No network.
set -euo pipefail
KIT=$(cd "$(dirname "$0")/.." && pwd)
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
mkdir -p "$T/bin" "$T/repo" "$T/bare" "$T/home"
git init -q "$T/repo"
git init -q "$T/bare"
python3 "$KIT/tests/fixtures/install_worker_skills.py" "$T/repo"
export SUPER_BOARD_SKILLS_HOME="$T/home"
cat > "$T/bin/gh" <<'PYGH'
#!/usr/bin/env python3
import json,sys,os,re
from pathlib import Path
args=sys.argv[1:]
store=Path(os.environ['SB_REPAIR_FIXTURE_DIR'])
if args and args[0]=='api' and '--slurp' in args:
    issue=re.search(r'/issues/(\d+)/comments', ' '.join(args)).group(1)
    file=store/('repair-'+issue+'.json')
    print('['+(file.read_text() if file.exists() else '[]')+']')
elif args[:2]==['api','-X']:
    endpoint=args[3]; issue=endpoint.split('/')[-2] if args[2]=='POST' else endpoint.split('/')[-1]
    body=json.load(sys.stdin)['body']
    (store/('repair-'+issue+'.json')).write_text(json.dumps([{'id':int(issue),'body':body,'user':{'login':'fixture'},'created_at':'2026-10-20T00:00:00Z','updated_at':'2026-10-20T00:00:00Z'}]))
elif args[:2] in (['label','create'],['issue','edit']): pass
elif args[:2]==['issue','view']:
    print(json.dumps({'labels':[]} if args[args.index('--json')+1] == 'labels' else {'number':int(args[2]),'title':'fixture','body':''}))
else:
    sys.exit('unexpected gh fixture call: '+str(args))
PYGH
cp "$KIT/tests/fixtures/fake_codex.py" "$T/bin/codex"
chmod +x "$T/bin/gh" "$T/bin/codex"
export SB_REPAIR_FIXTURE_DIR="$T"
export SB_CODEX_TEST_LOG="$T/calls.jsonl"
export PATH="$T/bin:$PATH"
CARDS='[{"number":1,"status":"Ready","title":"one"},{"number":2,"status":"Review"}]'
echo '{"max_workers":1,"verify_commands":["git diff --check"]}' > "$T/config.json"
echo '{"max_workers":1}' > "$T/unready.json"
fail() { echo "FAIL: $*" >&2; cat "$T/stderr" >&2 2>/dev/null || true; exit 1; }
wave() { bash "$KIT/scripts/super-board-codex-wave.sh" --cards "$CARDS" "$@" 2>"$T/stderr"; }

# The summary object literal in the workflow is the one source of the key set.
python3 - "$KIT/workflows/super-board-wave.js" > "$T/keys.json" <<'PY'
import json, re, sys
text = open(sys.argv[1]).read()
block = re.search(r'const summary = .*?return \{\n(.*?)\n\s*\}\n', text, re.S)
assert block, 'summary object not found in workflows/super-board-wave.js'
keys = re.findall(r'^\s*(\w+):', block.group(1), re.M)
assert 'number' in keys and 'finalStatus' in keys, keys
print(json.dumps(sorted(keys)))
PY

check() {  # check <path-name> <expected-halted>
  python3 - "$T/keys.json" "$T/out" "$1" "$2" <<'PY' || fail "$1 wave summary drifts from the workflow's"
import json, sys
keys = json.load(open(sys.argv[1]))
result = json.load(open(sys.argv[2]))
assert sorted(result) == ['cards', 'halted'], sorted(result)
assert type(result['halted']) is bool and result['halted'] == (sys.argv[4] == 'true'), result['halted']
assert result['cards'], 'no cards'
for card in result['cards']:
    missing, extra = sorted(set(keys) - set(card)), sorted(set(card) - set(keys))
    assert not missing and not extra, f'{sys.argv[3]}: card #{card.get("number")} missing {missing} extra {extra}'
PY
}

cd "$T/repo"
wave --config "$T/config.json" --codex >"$T/out" || fail 'normal wave'
jq -e '.cards[0].finalStatus == "advanced"' "$T/out" >/dev/null || fail 'normal path advances'
check normal false

SB_CODEX_TEST_STATUS=bounced wave --config "$T/config.json" --codex >"$T/out" || fail 'bounced wave'
jq -e '.cards[0].finalStatus == "bounced"' "$T/out" >/dev/null || fail 'bounced path bounces'
check bounced false

RC=0; SB_CODEX_TEST_GRADE_EXIT=79 wave --config "$T/config.json" --codex >"$T/out" || RC=$?
[ "$RC" -eq 79 ] && jq -e '.cards[0].detail | contains("while grading")' "$T/out" >/dev/null || fail 'halted while grading'
check halted-grading true

RC=0; wave --config "$T/unready.json" --codex >"$T/out" || RC=$?
[ "$RC" -eq 9 ] || fail "verification-readiness halt exits 9, got $RC"
check halted-readiness true

cd "$T/bare"
RC=0; wave --config "$T/config.json" --codex >"$T/out" || RC=$?
[ "$RC" -eq 10 ] || fail "skills-readiness halt exits 10, got $RC"
check halted-skills true
echo 'PASS: test-codex-wave-contract.sh (normal/bounced/halted summaries carry the workflow keys)'
