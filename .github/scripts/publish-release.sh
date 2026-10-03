#!/usr/bin/env bash
# Only called by release.yml after the checks for this event's commit pass.
set -euo pipefail
TAG=${1:?release tag required}
EXPECTED_SHA=${2:?tested commit required}
fail() { echo "Release refused: $1" >&2; exit 1; }
[[ "$TAG" =~ ^v[0-9]+\.[0-9]+\.[0-9]+$ ]] || fail 'tag must be vMAJOR.MINOR.PATCH'
[[ "$EXPECTED_SHA" =~ ^[0-9a-f]{40}$ ]] || fail 'expected a full tested commit SHA'
[ "$(git rev-parse HEAD)" = "$EXPECTED_SHA" ] || fail 'checkout differs from tested commit'
[ "$TAG" = "v$(cat VERSION)" ] || fail 'tag differs from VERSION'

# A moved/deleted tag must not reuse checks for an older revision. Peel annotated
# tags; lightweight tags already point to the commit. Tag rules must prevent a
# concurrent update after this check (see RELEASING.md).
refs=$(git ls-remote --exit-code origin "refs/tags/$TAG" "refs/tags/$TAG^{}") \
  || fail 'cannot read release tag from origin'
actual=$(printf '%s\n' "$refs" | awk -v tag="refs/tags/$TAG" '$2 == tag { sha=$1 } $2 == tag "^{}" { peeled=$1 } END { print peeled ? peeled : sha }')
[ "$actual" = "$EXPECTED_SHA" ] || fail 'remote tag differs from tested commit'

# --verify-tag refuses implicit tag creation. gh also refuses an existing release.
gh release create "$TAG" --verify-tag --target "$EXPECTED_SHA" \
  --title "super-board $TAG" --generate-notes
