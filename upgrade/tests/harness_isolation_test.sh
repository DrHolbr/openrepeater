#!/bin/bash
# A harness helper call must not open the live hostname or a mode file, and
# must not start the host service when no fixture root is named.
set -euo pipefail

ROOT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
# shellcheck source=lib/fixture_tmpdir.sh
. "$ROOT_DIR/upgrade/tests/lib/fixture_tmpdir.sh"
orp_use_fixture_tmpdir
tmp=$(orp_mktemp_dir)
trap 'orp_cleanup_fixture "$tmp"' EXIT
HELPER="$ROOT_DIR/install/scripts/orp_helper"
log="$tmp/live-etc.log"
: > "$log"

set +e
out=$(ORP_BENCH_TEST_HARNESS=1 ORP_LIVE_ETC_LOG="$log" \
	env -u ORP_ROOT "$HELPER" svxlink start 2>&1)
rc=$?
set -e
[ "$rc" -ne 0 ]
printf '%s\n' "$out" | grep -q 'refused:'
if [ -s "$log" ]; then
	echo "FAIL: a harness call without ORP_ROOT read a live path" >&2
	cat "$log" >&2
	exit 1
fi
if printf '%s\n' "$out" | grep -q 'host-action-accepted\|harness: svxlink start'; then
	echo "FAIL: a harness call without ORP_ROOT started svxlink" >&2
	exit 1
fi

root="$tmp/root"
mkdir -p "$root/etc"
printf 'fixture-host\n' > "$root/etc/hostname"
ORP_BENCH_TEST_HARNESS=1 ORP_LIVE_ETC_LOG="$log" ORP_ROOT="$root" \
	"$HELPER" svxlink start >/dev/null 2>&1 || true
if [ -s "$log" ]; then
	echo "FAIL: a fixture start read a live path" >&2
	cat "$log" >&2
	exit 1
fi

# Production native_path returns the real path when the harness is unset.
if ! awk '
	/^function native_path/ { in_fn=1 }
	in_fn && /ORP_BENCH_TEST_HARNESS/ { saw_harness=1 }
	in_fn && /printf .%s. "\$1"/ { saw_live=1 }
	in_fn && /^}/ { if (in_fn) exit }
	END { exit !(saw_harness && saw_live) }
' "$HELPER"; then
	echo "FAIL: production native_path no longer returns the live path" >&2
	exit 1
fi

: > "$log"
set +e
slash=$(ORP_BENCH_TEST_HARNESS=1 ORP_LIVE_ETC_LOG="$log" ORP_ROOT=// \
	"$HELPER" svxlink start 2>&1)
slash_rc=$?
set -e
[ "$slash_rc" -ne 0 ]
if [ -s "$log" ]; then
	echo "FAIL: ORP_ROOT=// read a live path" >&2
	cat "$log" >&2
	exit 1
fi
if printf '%s\n' "$slash" | grep -q 'host-action-accepted\|harness: svxlink start'; then
	echo "FAIL: ORP_ROOT=// started svxlink" >&2
	exit 1
fi
echo "ok: harness helper calls do not read live paths or start the host service"
echo "harness isolation checks passed"
