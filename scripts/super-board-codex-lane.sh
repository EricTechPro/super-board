#!/usr/bin/env bash
# Compatibility shim: the Codex lane is super-board-lane.sh --backend codex (same flags).
exec bash "$(dirname "${BASH_SOURCE[0]}")/super-board-lane.sh" --backend codex "$@"
