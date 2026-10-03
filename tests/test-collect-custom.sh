#!/usr/bin/env bash
# Runs the super-collect custom-source tests (onboard's "➕ Add another source"). No network.
#   bash tests/test-collect-custom.sh
set -euo pipefail
exec python3 "$(cd "$(dirname "$0")" && pwd)/test_collect_custom.py"
