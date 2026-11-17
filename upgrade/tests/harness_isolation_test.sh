#!/bin/bash
# A harness helper call must not open the live token or hostname.
# Production still reads /etc when the harness flag is unset.
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
marker="$tmp/marker"
printf 'bench\n' > "$marker"

set +e
out=$(ORP_BENCH_TEST_HARNESS=1 ORP_LIVE_ETC_LOG="$log" ORP_BENCH_MARKER="$marker" \
	env -u ORP_ROOT "$HELPER" svxlink start 2>&1)
rc=$?
set -e
[ "$rc" -ne 0 ]
printf '%s\n' "$out" | grep -q 'refused:'
grep -qx '/etc/openrepeater/operating-mode' "$log"
grep -qx '/etc/hostname' "$log"
if printf '%s\n' "$out" | grep -q 'host-action-accepted\|harness: svxlink start'; then
	echo "FAIL: a harness call without ORP_ROOT followed the live token" >&2
	exit 1
fi

root="$tmp/root"
mkdir -p "$root/etc"
printf 'fixture-host\n' > "$root/etc/hostname"
before=$(wc -l < "$log")
ORP_BENCH_TEST_HARNESS=1 ORP_LIVE_ETC_LOG="$log" ORP_ROOT="$root" ORP_BENCH_MARKER="$marker" \
	"$HELPER" svxlink start >/dev/null 2>&1 || true
after=$(wc -l < "$log")
[ "$before" = "$after" ]

# The production predicate is the harness-unset branch. Do not invoke it
# against the live files. The function must still return the real path then.
if ! awk '
	/^function native_token_path/ { in_fn=1 }
	in_fn && /ORP_BENCH_TEST_HARNESS/ { saw_harness=1 }
	in_fn && /printf .%s. "\$rel"/ { saw_live=1 }
	in_fn && /^}/ { if (in_fn) exit }
	END { exit !(saw_harness && saw_live) }
' "$HELPER"; then
	echo "FAIL: production native_token_path no longer returns the live path" >&2
	exit 1
fi

: > "$log"
set +e
slash=$(ORP_BENCH_TEST_HARNESS=1 ORP_LIVE_ETC_LOG="$log" ORP_ROOT=// ORP_BENCH_MARKER="$marker" \
	"$HELPER" svxlink start 2>&1)
slash_rc=$?
set -e
[ "$slash_rc" -ne 0 ]
grep -qx '/etc/hostname' "$log"
if printf '%s\n' "$slash" | grep -q 'host-action-accepted\|harness: svxlink start'; then
	echo "FAIL: ORP_ROOT=// followed the live token" >&2
	exit 1
fi
echo "ok: harness helper calls do not read live /etc/openrepeater or /etc/hostname"
echo "harness isolation checks passed"
