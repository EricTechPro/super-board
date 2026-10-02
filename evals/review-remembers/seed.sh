#!/usr/bin/env bash
# Seeds a re-review: PR #12 was bounced with findings R1 and R2, the builder
# rebuilt it. R1 (empty-cart crash) is really fixed; R2 (discount not clamped)
# is not — its thread was resolved without a code change.
set -euo pipefail
WS="${1:-$PWD}"
cd "$WS"
# The eval child's Bash does not inherit the caller's PATH, so the offline gh stub
# (and the git/python3 shim bypass) would be invisible. The scaffold DOES inherit it,
# and shares the run's temp HOME: copy the stubs in and prepend them from the rc files
# the agent's shell snapshot reads.
STUBS="$(dirname "$(command -v gh)")"
[ -f "$STUBS/_real" ] || { echo "seed: put evals/_stubs/bin first on PATH (see evals/README.md)" >&2; exit 1; }
BIN="$HOME/.eval-bin"
mkdir -p "$BIN"
cp -P "$STUBS"/* "$BIN"/
for rc in .zshenv .zshrc .bashrc .bash_profile .profile; do
  printf 'export PATH="%s:$PATH"\n' "$BIN" >> "$HOME/$rc"
done
echo "seed: HOME=$HOME WS=$WS" >&2

git init -q -b main .
git config user.email eval@example.com
git config user.name eval
mkdir -p src tests
cat > src/cart.py <<'PY'
def total(prices, discount_pct=0):
    subtotal = sum(prices)
    return subtotal - subtotal * discount_pct / 100
PY
touch src/__init__.py tests/__init__.py
cat > tests/test_cart.py <<'PY'
import unittest

from src.cart import total


class TotalTest(unittest.TestCase):
    def test_total(self):
        self.assertEqual(total([10, 20]), 30)
PY
printf '.gh-log\n.origin.git/\n__pycache__/\n' > .gitignore
git add -A && git commit -qm "cart total"
git init -q --bare .origin.git && git remote add origin "$WS/.origin.git" && git push -q origin main

git checkout -q -b issue-7-cart-discount
cat > src/cart.py <<'PY'
def average_price(prices):
    return sum(prices) / len(prices)


def total(prices, discount_pct=0):
    subtotal = sum(prices)
    return subtotal - subtotal * discount_pct / 100
PY
git commit -qam "add average_price"
BASE_SHA=$(git rev-parse HEAD)

# Round-1 rebuild: the builder fixed R1 only.
cat > src/cart.py <<'PY'
def average_price(prices):
    if not prices:
        return 0
    return sum(prices) / len(prices)


def total(prices, discount_pct=0):
    subtotal = sum(prices)
    return subtotal - subtotal * discount_pct / 100
PY
cat >> tests/test_cart.py <<'PY'

    def test_average_price_empty(self):
        from src.cart import average_price
        self.assertEqual(average_price([]), 0)
PY
git commit -qam "fix: guard empty cart in average_price (R1)"
git push -q origin issue-7-cart-discount

FX=.git/gh-fixture
mkdir -p "$FX"
git diff main...issue-7-cart-discount > "$FX/diff.patch"
PRIOR=$(cat <<MD
<!-- super-review:report -->
🧐 Reviewer — bounced
Round:     1
Findings:
  • R1 [builder] src/cart.py:2 — average_price divides by zero on an empty cart
  • R2 [builder] src/cart.py:7 — discount_pct is not clamped to 0-100; 150 gives a negative total (AC 1)
Next:      Ready
MD
)
jq -n --arg prior "$PRIOR" --arg base "$BASE_SHA" '{
  number: 12, title: "Cart discount (#7)", state: "OPEN", isDraft: false,
  headRefName: "issue-7-cart-discount", baseRefName: "main",
  url: "https://github.com/example/shop/pull/12",
  body: "Closes #7.\n\nAC 1: discount percent is clamped to 0-100.\nAC 2: an empty cart has an average price of 0.\n\nLocal tests: python3 -m unittest -q",
  labels: [{name: "loop:rebuild-1"}],
  files: [{path: "src/cart.py"}, {path: "tests/test_cart.py"}],
  reviewThreads: [],
  comments: [
    {author: {login: "super-board-bot"}, body: $prior, createdAt: "2026-10-01T10:00:00Z"},
    {author: {login: "super-board-bot"}, body: "[builder] Rebuild done: R1 fixed (empty-cart guard), R2 thread resolved.\nLocal tests: python3 -m unittest -q", createdAt: "2026-10-01T12:00:00Z"}
  ]
}' > "$FX/pr.json"
: > .gh-log
