#!/usr/bin/env bash
# Publication boundary: local/remote tag mismatch must never call gh release create.
# git/gh are stubbed; no tag, release, or network writes.
set -euo pipefail
PACK=$(cd "$(dirname "$0")/.." && pwd)
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT
mkdir -p "$WORK/bin"
export RELEASE_LOG="$WORK/gh.log"
export STUB_SHA=1111111111111111111111111111111111111111
export STUB_OTHER=2222222222222222222222222222222222222222
export STUB_TAG=v3.0.2
export STUB_MODE=lightweight
cat > "$WORK/bin/git" <<'STUB'
#!/usr/bin/env bash
case "$1" in
  rev-parse) printf '%s\n' "${STUB_CHECKOUT:-$STUB_SHA}" ;;
  ls-remote)
    case "$STUB_MODE" in
      lightweight) printf '%s\trefs/tags/%s\n' "$STUB_SHA" "$STUB_TAG" ;;
      annotated)
        printf '%s\trefs/tags/%s\n' "$STUB_OTHER" "$STUB_TAG"
        printf '%s\trefs/tags/%s^{}\n' "$STUB_SHA" "$STUB_TAG" ;;
      moved) printf '%s\trefs/tags/%s\n' "$STUB_OTHER" "$STUB_TAG" ;;
      missing) exit 2 ;;
      unavailable) exit 128 ;;
    esac ;;
  *) exit 99 ;;
esac
STUB
cat > "$WORK/bin/gh" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$@" > "$RELEASE_LOG"
exit "${STUB_RELEASE_RC:-0}"
STUB
chmod +x "$WORK/bin/"*
export PATH="$WORK/bin:$PATH"
cd "$WORK"
printf '3.0.2\n' > VERSION
fail() { echo "FAIL: $1" >&2; exit 1; }
publish() { bash "$PACK/.github/scripts/publish-release.sh" "$1" "$2"; }
refused() {
  rm -f "$RELEASE_LOG"
  if publish "$1" "$2" >/dev/null 2>&1; then fail "accepted: $STUB_MODE $1 $2"; fi
  [ ! -e "$RELEASE_LOG" ] || fail 'reached publication after rejected precondition'
}
for mode in lightweight annotated; do
  export STUB_MODE=$mode
  publish "$STUB_TAG" "$STUB_SHA" >/dev/null || fail "$mode rejected"
  python3 - "$RELEASE_LOG" "$STUB_SHA" <<'PY'
import pathlib, sys
args = pathlib.Path(sys.argv[1]).read_text().splitlines()
assert args == ['release', 'create', 'v3.0.2', '--verify-tag', '--target', sys.argv[2],
                '--title', 'super-board v3.0.2', '--generate-notes'], args
PY
done
for mode in moved missing unavailable; do
  export STUB_MODE=$mode
  refused "$STUB_TAG" "$STUB_SHA"
done
export STUB_MODE=lightweight STUB_CHECKOUT=$STUB_OTHER
refused "$STUB_TAG" "$STUB_SHA"
unset STUB_CHECKOUT
refused 'v3.0.3' "$STUB_SHA"
refused 'v3.0.2; echo unexpected' "$STUB_SHA"
refused "$STUB_TAG" main
export STUB_RELEASE_RC=1
if publish "$STUB_TAG" "$STUB_SHA" >/dev/null 2>&1; then fail 'release failure was swallowed'; fi
echo 'PASS: test-release.sh (matching tags, moved/missing tags, checkout, version, arguments, failure)'
