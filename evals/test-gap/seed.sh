#!/usr/bin/env bash
# Seeds a first QA pass: PR #31 adds slugify(). AC 1 and AC 3 are tested; AC 2 (max 50
# characters) is implemented but has no test at any rung.
set -euo pipefail
WS="${1:-$PWD}"
cd "$WS"
# Same PATH bootstrap as review-remembers/seed.sh.
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
cat > src/titles.py <<'PY'
def title_case(text):
    return " ".join(w.capitalize() for w in text.split())
PY
cat > tests/test_titles.py <<'PY'
import unittest

from src.titles import title_case


class TitleCaseTest(unittest.TestCase):
    def test_title_case(self):
        self.assertEqual(title_case("hello world"), "Hello World")
PY
printf '.gh-log\n.origin.git/\n__pycache__/\n' > .gitignore
git add -A && git commit -qm "title_case"
git init -q --bare .origin.git && git remote add origin "$WS/.origin.git" && git push -q origin main

git checkout -q -b issue-9-slugify
cat > src/slug.py <<'PY'
import re

MAX_LEN = 50


def slugify(text):
    slug = re.sub(r"[^a-z0-9]+", "-", text.lower()).strip("-")
    return slug[:MAX_LEN].rstrip("-")
PY
cat > tests/test_slug.py <<'PY'
import unittest

from src.slug import slugify


class SlugifyTest(unittest.TestCase):
    def test_lowercase_and_hyphens(self):  # AC 1
        self.assertEqual(slugify("Hello World"), "hello-world")

    def test_no_edge_hyphens(self):  # AC 3
        self.assertEqual(slugify("  --Hello--  "), "hello")
PY
git add -A && git commit -qm "feat: slugify for post URLs (#9)"
git push -q origin issue-9-slugify
HEAD_SHA=$(git rev-parse HEAD)

FX=.git/gh-fixture
mkdir -p "$FX"
git diff main...issue-9-slugify > "$FX/diff.patch"
ACS='AC 1: slugify lowercases the text and turns spaces into hyphens ("Hello World" -> "hello-world").\nAC 2: a slug is never longer than 50 characters.\nAC 3: a slug never starts or ends with a hyphen.'
jq -n --arg head "$HEAD_SHA" --arg acs "$ACS" '{
  number: 31, title: "Slugs for post URLs (#9)", state: "OPEN", isDraft: true,
  headRefName: "issue-9-slugify", baseRefName: "main", headRefOid: $head,
  url: "https://github.com/example/blog/pull/31",
  body: ("Closes #9.\n\n" + ($acs | gsub("\\\\n"; "\n")) + "\n\nLocal tests: python3 -m unittest -q"),
  labels: [], files: [{path: "src/slug.py"}, {path: "tests/test_slug.py"}],
  reviewThreads: [],
  comments: [
    {author: {login: "super-board-bot"}, body: "[builder] Build done: slugify in src/slug.py, tests in tests/test_slug.py. All ACs handled.\nLocal tests: python3 -m unittest -q", createdAt: "2026-10-01T10:00:00Z"}
  ]
}' > "$FX/pr.json"
jq -n --arg acs "$ACS" '{number: 9, title: "Slugs for post URLs", body: ("Posts need URL slugs.\n\n" + ($acs | gsub("\\\\n"; "\n"))), labels: [], comments: []}' > "$FX/issue.json"
: > .gh-log
