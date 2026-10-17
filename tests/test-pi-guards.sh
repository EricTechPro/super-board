#!/usr/bin/env bash
# Node's type stripping runs extensions/super-board-guards.ts against a stub Pi
# extension API and fake guard scripts (tests/fixtures/pi_guards.mjs): the Pi
# payload mapping, fail-open contract, opt-in push guard and session start.
set -euo pipefail
KIT=$(cd "$(dirname "$0")/.." && pwd)
exec node "$KIT/tests/fixtures/pi_guards.mjs" "$KIT"
