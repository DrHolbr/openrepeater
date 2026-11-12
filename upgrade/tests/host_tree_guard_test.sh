#!/bin/bash
# The sha listing is one null-delimited pass and keeps spaces in names.
set -euo pipefail
ROOT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
# shellcheck source=lib/fixture_tmpdir.sh
. "$ROOT_DIR/upgrade/tests/lib/fixture_tmpdir.sh"
# shellcheck source=lib/host_tree_guard.sh
. "$ROOT_DIR/upgrade/tests/lib/host_tree_guard.sh"
orp_use_fixture_tmpdir
tmp=$(orp_mktemp_dir)
trap 'orp_cleanup_fixture "$tmp"' EXIT
dir="$tmp/spaced dir"
mkdir -p "$dir"
printf 'spaced-bytes\n' > "$dir/a file"
out=$(mktemp)
host_tree_sha "$out" "$dir"
expect=$(sha256sum "$dir/a file" | awk '{print $1}')
if ! grep -F "$expect  $dir/a file" "$out" >/dev/null; then
	echo "FAIL: sha listing dropped the spaced filename" >&2
	cat "$out" >&2
	exit 1
fi
echo "ok: live-tree sha listing keeps a spaced filename"
