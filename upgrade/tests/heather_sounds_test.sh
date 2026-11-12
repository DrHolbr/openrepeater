#!/bin/bash
set -euo pipefail
ROOT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
python3 "$ROOT_DIR/upgrade/tests/heather_sounds_test.py"
