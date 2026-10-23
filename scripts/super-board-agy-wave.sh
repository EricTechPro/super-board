#!/usr/bin/env bash
# Dispatch an explicitly selected Antigravity wave. Thin entry point: the wave
# engine is shared with Codex (super-board-codex-wave.sh), which picks
# super-board-agy-lane.sh as the lane launcher when it sees --agy. One engine keeps
# one PID marker, one cancellation path and one stop protocol.
# Usage: --config f --cards '<JSON array>' [--agy[=model]] [--tier low|medium|high] [--output f]
# --agy is added when absent, so this script always runs an Antigravity wave.
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
for arg in "$@"; do
  case "$arg" in
    --codex|--codex=*) echo "super-board-agy-wave.sh: --codex belongs to super-board-codex-wave.sh" >&2; exit 64 ;;
    --agy|--agy=*) exec bash "$HERE/super-board-codex-wave.sh" "$@" ;;
  esac
done
exec bash "$HERE/super-board-codex-wave.sh" "$@" --agy
