#!/usr/bin/env bash
# Tests super-board-env-check.sh — key names in, present/empty/missing out, and
# never a byte of any value on stdout or stderr.
set -euo pipefail
cd "$(dirname "$0")"
EC="$PWD/../scripts/super-board-env-check.sh"
fail() { echo "FAIL: $1" >&2; exit 1; }
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
SECRET="sk_$(printf 'live')_$(printf 'abc123')"
D=.env
printf 'A=%s\nexport B="%s"\nC=\n# DCOMMENT=%s\n  E = x\n' "$SECRET" "$SECRET" "$SECRET" > "$T/$D"

# 1 — states per key, exit 1 because one is not present.
RC=0; OUT=$(cd "$T" && "$EC" A B C DCOMMENT E Z 2>&1) || RC=$?
[ "$RC" -eq 1 ] || fail "a missing key should exit 1, got $RC"
echo "$OUT" | grep -qx "A present"   || fail "A present: $OUT"
echo "$OUT" | grep -qx "B present"   || fail "export B present: $OUT"
echo "$OUT" | grep -qx "C empty"     || fail "C empty: $OUT"
echo "$OUT" | grep -qx "DCOMMENT missing" || fail "a commented key is missing: $OUT"
echo "$OUT" | grep -qx "Z missing"   || fail "Z missing: $OUT"

# 2 — THE POINT: the value never appears.
echo "$OUT" | grep -q "abc123" && fail "a value leaked: $OUT"

# 3 — all present exits 0; --file picks another file; .env.local wins by default.
(cd "$T" && "$EC" A B >/dev/null) || fail "all present should exit 0"
printf 'ONLYLOCAL=1\n' > "$T/${D}.local"
(cd "$T" && "$EC" ONLYLOCAL | grep -qx "ONLYLOCAL present") || fail ".env.local should be the default when present"
(cd "$T" && "$EC" --file "$D" A | grep -qx "A present") || fail "--file should select the file"

# 4 — no file at all: every key is missing, no crash.
E=$(mktemp -d); OUT=$(cd "$E" && "$EC" A || true); rm -rf "$E"
[ "$OUT" = "A missing" ] || fail "no dotenv should read missing, got: $OUT"

# 5 — usage: no keys, or a key name that could smuggle a pattern.
RC=0; "$EC" >/dev/null 2>&1 || RC=$?; [ "$RC" -eq 64 ] || fail "no keys should exit 64, got $RC"
RC=0; (cd "$T" && "$EC" 'A.*' >/dev/null 2>&1) || RC=$?; [ "$RC" -eq 64 ] || fail "a bad key name should exit 64, got $RC"

echo "PASS: test-env-check.sh (5 scenarios)"
