#!/bin/bash
# Install the pinned Heather 25.05 pack. The Python program checks the
# digest before writing and materializes in-archive symlinks as regular files.
set -euo pipefail
SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
exec python3 "$SCRIPT_DIR/install_heather_sounds.py" "$@"
