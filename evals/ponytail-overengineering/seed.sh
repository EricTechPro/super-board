#!/usr/bin/env bash
# Seeds a first review: PR #21 adds format_price(cents). It is correct and tested, but
# wraps one f-string in a strategy ABC, a registry, a factory and a JSON config.
set -euo pipefail
WS="${1:-$PWD}"
cd "$WS"
# Same PATH bootstrap as review-remembers/seed.sh: the agent's Bash does not inherit the
# caller's PATH, so copy the stubs into the run's HOME and prepend them from the rc files.
STUBS="$(dirname "$(command -v gh)")"
[ -f "$STUBS/_real" ] || { echo "seed: put evals/_stubs/bin first on PATH (see evals/README.md)" >&2; exit 1; }
BIN="$HOME/.eval-bin"
mkdir -p "$BIN"
cp -P "$STUBS"/* "$BIN"/
for rc in .zshenv .zshrc .bashrc .bash_profile .profile; do
  printf 'export PATH="%s:$PATH"\n' "$BIN" >> "$HOME/$rc"
done

git init -q -b main .
git config user.email eval@example.com
git config user.name eval
mkdir -p src tests
touch src/__init__.py tests/__init__.py
cat > src/cart.py <<'PY'
def subtotal_cents(items):
    return sum(price * qty for price, qty in items)
PY
cat > tests/test_cart.py <<'PY'
import unittest

from src.cart import subtotal_cents


class CartTest(unittest.TestCase):
    def test_subtotal(self):
        self.assertEqual(subtotal_cents([(250, 2), (100, 1)]), 600)
PY
printf '.gh-log\n.origin.git/\n__pycache__/\n' > .gitignore
git add -A && git commit -qm "cart subtotal"
git init -q --bare .origin.git && git remote add origin "$WS/.origin.git" && git push -q origin main

git checkout -q -b issue-11-format-price
mkdir -p src/formatting config
touch src/formatting/__init__.py
cat > src/formatting/base.py <<'PY'
from abc import ABC, abstractmethod


class PriceFormatter(ABC):
    """Strategy interface so new currency formats can be plugged in later."""

    @abstractmethod
    def format(self, cents: int) -> str:
        raise NotImplementedError
PY
cat > src/formatting/dollar.py <<'PY'
from src.formatting.base import PriceFormatter


class DollarFormatter(PriceFormatter):
    def __init__(self, symbol="$", decimals=2):
        self.symbol = symbol
        self.decimals = decimals

    def format(self, cents: int) -> str:
        return f"{self.symbol}{cents / 100:.{self.decimals}f}"
PY
cat > src/formatting/registry.py <<'PY'
_REGISTRY = {}


def register(name):
    def wrap(cls):
        _REGISTRY[name] = cls
        return cls
    return wrap


def lookup(name):
    if name not in _REGISTRY:
        raise KeyError(f"no formatter registered as {name!r}")
    return _REGISTRY[name]
PY
cat > src/formatting/factory.py <<'PY'
import json
from pathlib import Path

from src.formatting import registry
from src.formatting.dollar import DollarFormatter

registry.register("dollar")(DollarFormatter)

CONFIG = Path(__file__).resolve().parents[2] / "config" / "formatters.json"


class FormatterFactory:
    @staticmethod
    def create(name=None):
        settings = json.loads(CONFIG.read_text())
        name = name or settings["default"]
        options = settings["formatters"][name]
        return registry.lookup(name)(**options)
PY
cat > config/formatters.json <<'JSON'
{
  "default": "dollar",
  "formatters": {
    "dollar": { "symbol": "$", "decimals": 2 }
  }
}
JSON
cat > src/pricing.py <<'PY'
from src.formatting.factory import FormatterFactory


def format_price(cents):
    return FormatterFactory.create().format(cents)
PY
cat > tests/test_pricing.py <<'PY'
import unittest

from src.pricing import format_price


class FormatPriceTest(unittest.TestCase):
    def test_dollars_and_cents(self):  # AC 1
        self.assertEqual(format_price(1234), "$12.34")

    def test_under_a_dollar(self):  # AC 2
        self.assertEqual(format_price(5), "$0.05")
PY
git add -A && git commit -qm "feat: format_price via pluggable formatter registry (#11)"
git push -q origin issue-11-format-price
HEAD_SHA=$(git rev-parse HEAD)

FX=.git/gh-fixture
mkdir -p "$FX"
git diff main...issue-11-format-price > "$FX/diff.patch"
jq -n --arg head "$HEAD_SHA" '{
  number: 21, title: "Format prices for display (#11)", state: "OPEN", isDraft: false,
  headRefName: "issue-11-format-price", baseRefName: "main", headRefOid: $head,
  url: "https://github.com/example/shop/pull/21",
  body: "Closes #11.\n\nAC 1: format_price(1234) returns \"$12.34\".\nAC 2: format_price(5) returns \"$0.05\".\n\nLocal tests: python3 -m unittest -q",
  labels: [],
  files: [{path: "config/formatters.json"}, {path: "src/formatting/__init__.py"}, {path: "src/formatting/base.py"}, {path: "src/formatting/dollar.py"}, {path: "src/formatting/factory.py"}, {path: "src/formatting/registry.py"}, {path: "src/pricing.py"}, {path: "tests/test_pricing.py"}],
  reviewThreads: [],
  comments: [
    {author: {login: "super-board-bot"}, body: "[builder] Build done: format_price behind a pluggable formatter registry so other currencies can be added later. Both ACs tested.\nLocal tests: python3 -m unittest -q", createdAt: "2026-10-01T10:00:00Z"},
    {author: {login: "super-board-bot"}, body: "🔍 QA pass: AC 1 and AC 2 green (tests/test_pricing.py:7, :10).\nLocal tests: python3 -m unittest -q", createdAt: "2026-10-01T11:00:00Z"}
  ]
}' > "$FX/pr.json"
jq -n '{number: 11, title: "Format prices for display", body: "Show prices as dollars.\n\nAC 1: format_price(1234) returns \"$12.34\".\nAC 2: format_price(5) returns \"$0.05\".", labels: [], comments: []}' > "$FX/issue.json"
: > .gh-log
