#!/usr/bin/env bash
# Tests get.sh, the one-line installer, offline: the pack is served as a local
# file:// tarball (SUPER_BOARD_TARBALL), and npx is a stub on PATH that logs its
# arguments instead of reaching the network. Each case installs into a fresh
# temp target and checks what landed.
set -euo pipefail
cd "$(dirname "$0")/.."
PACK="$PWD"
GET="$PACK/get.sh"

fail() { echo "FAIL: $1" >&2; exit 1; }
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

# A tarball shaped like GitHub's: one top-level folder holding the pack.
mkdir -p "$WORK/src/super-board-test"
tar -cf - --exclude ./.git --exclude ./evals --exclude ./docs . | tar -xf - -C "$WORK/src/super-board-test"
tar -czf "$WORK/pack.tgz" -C "$WORK/src" super-board-test
export SUPER_BOARD_TARBALL="file://$WORK/pack.tgz"

# Stubs: npx records its argv; gh and jq exist so no warnings fire.
mkdir -p "$WORK/bin"
cat > "$WORK/bin/npx" <<'EOF'
#!/usr/bin/env bash
echo "$*" >> "$NPX_LOG"
EOF
printf '#!/bin/sh\nexit 0\n' > "$WORK/bin/gh"
printf '#!/bin/sh\nexit 0\n' > "$WORK/bin/jq"
chmod +x "$WORK/bin/"*
export PATH="$WORK/bin:$PATH"
export NPX_LOG="$WORK/npx.log"
export HOME="$WORK/home"; mkdir -p "$HOME"   # keep the real ~/.claude/skills out of the "already present" check

bash -n "$GET" || fail "get.sh has a syntax error"

# 1 — default install into --target: pack lands, hooks wired, helper skills called.
T="$WORK/t1"; mkdir -p "$T"; : > "$NPX_LOG"
out=$(bash "$GET" --target "$T" 2>&1) || fail "default install exited non-zero: $out"
for s in super-board super-build super-qa super-review super-collect visual git-sync ui-refine-loop; do
  [ -f "$T/.claude/skills/$s/SKILL.md" ] || fail "skill $s not installed"
done
[ -x "$T/.claude/bin/super-board-run.sh" ] || fail "dispatcher script not installed"
[ -f "$T/.claude/workflows/super-board-wave.js" ] || fail "workflow not installed"
[ -f "$T/.claude/settings.json" ] || fail "hooks were not merged into settings.json"
grep -q 'add mattpocock/skills' "$NPX_LOG" || fail "helper skills step not called (npx log: $(cat "$NPX_LOG"))"
echo "$out" | grep -q '/super-board onboard' || fail "summary is missing the next step"
n=$(printf '%s\n' "$out" | grep -c '/super-board onboard' || true)
[ "$n" -eq 1 ] || fail "the next step should be printed once, got $n times: $out"

# 2 — flags pass through to install.sh, positional target works from piped stdin.
T="$WORK/t2"; mkdir -p "$T"; : > "$NPX_LOG"
bash -s -- --protect-main --no-helper-skills "$T" < "$GET" >/dev/null 2>&1 || fail "piped install with --protect-main failed"
grep -q 'guard-protected-push' "$T/.claude/settings.json" || fail "--protect-main was not passed through to install.sh"
[ ! -s "$NPX_LOG" ] || fail "--no-helper-skills still called npx"

# 3 — --no-hooks passes through: no settings.json, no hooks dir.
T="$WORK/t3"; mkdir -p "$T"
bash "$GET" --no-hooks --no-helper-skills --target "$T" >/dev/null 2>&1 || fail "--no-hooks install failed"
[ ! -e "$T/.claude/settings.json" ] || fail "--no-hooks still wrote settings.json"
[ -f "$T/.claude/skills/super-board/SKILL.md" ] || fail "--no-hooks install skipped the skills"

# 4 — helper skills already present (lock file lists them): npx is not called.
T="$WORK/t4"; mkdir -p "$T"; : > "$NPX_LOG"
printf '{"skills":{"tdd":{"source":"mattpocock/skills"}}}\n' > "$T/skills-lock.json"
out=$(bash "$GET" --target "$T" 2>&1) || fail "install with helpers present failed"
[ ! -s "$NPX_LOG" ] || fail "helper skills already present, but npx was called"
echo "$out" | grep -q 'already' || fail "summary should say helper skills are already installed"

# 5 — a target that isn't a directory is refused, and nothing is written.
: > "$WORK/a-file"
if bash "$GET" --target "$WORK/a-file" >/dev/null 2>&1; then fail "a file as target was accepted"; fi
if bash "$GET" --target "$WORK/missing" >/dev/null 2>&1; then fail "a missing target was accepted"; fi
[ ! -e "$WORK/missing" ] || fail "a refused target was created"

# 6 — an unknown flag reaches install.sh, which rejects it; get.sh fails.
T="$WORK/t6"; mkdir -p "$T"
if bash "$GET" --bogus --no-helper-skills --target "$T" >/dev/null 2>&1; then fail "unknown flag was swallowed"; fi

# 7 — a bad tarball URL fails cleanly and leaves no temp folder behind.
T="$WORK/t7"; mkdir -p "$T"
mkdir -p "$WORK/tmp7"
if TMPDIR="$WORK/tmp7" SUPER_BOARD_TARBALL="file://$WORK/nope.tgz" bash "$GET" --no-helper-skills --target "$T" >/dev/null 2>&1; then
  fail "missing tarball was accepted"
fi
[ -z "$(ls -A "$WORK/tmp7")" ] || fail "temp folder was left behind after a failed download"

# 8 — grouped output, in the spec's order: header · checks · download · installing ·
#     helper skills · 🎉 · 👉. One line per group of files, no per-file list.
T="$WORK/t8"; mkdir -p "$T"; printf '# Rules\n- pnpm\n' > "$T/CLAUDE.md"; : > "$NPX_LOG"
out=$(bash "$GET" --target "$T" 2>&1) || fail "grouped-output install failed: $out"
order=$(printf '%s\n' "$out" | grep -oE '^(🧩|🔍|📦|🔧|🧠|🎉|👉)' | tr -d '\n')
[ "$order" = "🧩🔍📦🔧🧠🎉👉" ] || fail "groups out of order ($order): $out"
printf '%s\n' "$out" | grep -q '^   ✓ curl · tar · python3 · gh · jq · node$' || fail "checks line wrong: $out"
printf '%s\n' "$out" | grep -q '^   🛡️  6 guard hooks → .claude/settings.json (new file)$' || fail "guard line wrong: $out"
printf '%s\n' "$out" | grep -q '^   ! CLAUDE.md holds its own rules — onboard offers a merge$' || fail "CLAUDE.md hint missing: $out"
printf '%s\n' "$out" | grep -q '^🧠 helper skills: installed$' || fail "helper line wrong: $out"
[ "$(printf '%s\n' "$out" | wc -l | tr -d ' ')" -le 12 ] || fail "output should stay ≤ 12 lines: $out"

# 9 — Node missing: the checks line marks it ✗ and helper skills wait for 🔍 Checks.
T="$WORK/t9"; mkdir -p "$T"
# /usr/bin can contain node on Linux. Keep only the tools this install uses.
NOBIN="$WORK/bin-nonode"; mkdir -p "$NOBIN"
for t in bash id curl tar gzip python3 mktemp mkdir rm dirname tr cp chmod grep basename sed gh jq; do
  ln -s "$(command -v "$t")" "$NOBIN/$t"
done
out=$(PATH="$NOBIN" bash "$GET" --target "$T" 2>&1) || fail "install without node failed: $out"
printf '%s\n' "$out" | grep -q '✗ node' || fail "missing node should be marked ✗: $out"
printf '%s\n' "$out" | grep -q '^🧠 helper skills: skipped — 🔍 Checks will fix this$' || fail "helper line should defer to Checks: $out"

echo "PASS: test-get.sh (9 cases)"
