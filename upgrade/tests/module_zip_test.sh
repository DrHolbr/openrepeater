#!/bin/bash
# ZipArchive refusal and hostile module archives. Nothing is installed.
set -euo pipefail

ROOT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
# shellcheck source=lib/fixture_tmpdir.sh
. "$ROOT_DIR/upgrade/tests/lib/fixture_tmpdir.sh"
orp_use_fixture_tmpdir

php -n "$ROOT_DIR/upgrade/tests/module_zip_test.php" missing
set +e
php "$ROOT_DIR/upgrade/tests/module_zip_test.php" hostile
rc=$?
set -e
sudo -n chown -R "$(id -u):$(id -g)" "$(orp_fixture_root)" || true
if [ "$rc" -ne 0 ]; then
	exit "$rc"
fi

HELPER="$ROOT_DIR/install/scripts/orp_helper"
fix=$(orp_mktemp_dir)
share="$fix/usr/local/share/svxlink"
mkdir -p "$share/events.d" "$fix/modules/HardMod/svxlink/events.d" \
	"$fix/modules/FifoMod/svxlink/events.d" "$fix/modules/SwapMod/svxlink/events.d" \
	"$fix/var/lib/openrepeater/module-install"
printf 'events\n' > "$share/events.tcl"
printf 'orphan\n' > "$share/events.d/ModuleOrphan.tcl"
printf 'keep\n' > "$share/events.d/Keep.tcl"
printf 'events.d/ModuleOrphan.tcl\n' > "$fix/var/lib/openrepeater/module-install/OrphanMod.list"
secret="$fix/root-secret"
printf 'root-secret\n' > "$secret"
sudo chown root:root "$secret"
sudo chmod 644 "$secret"
sudo ln "$secret" "$fix/modules/HardMod/svxlink/events.d/ModuleHard.tcl"
[ "$(stat -c %h "$secret")" = "2" ]
set +e
sudo -n env ORP_BENCH_TEST_HARNESS=1 ORP_ROOT="$fix" ORP_MODULES_PATH="$fix/modules" \
	"$HELPER" module activate HardMod >"$fix/hard.out" 2>"$fix/hard.err"
hard_rc=$?
set -e
[ "$hard_rc" -ne 0 ]
grep -q 'private regular file' "$fix/hard.err"
[ ! -e "$share/events.d/ModuleHard.tcl" ]
[ "$(cat "$secret")" = "root-secret" ]
echo "ok: a hardlink to a root-owned file is refused"

mkfifo "$fix/modules/FifoMod/svxlink/events.d/ModuleFifo.tcl"
set +e
timeout 5 sudo -n env ORP_BENCH_TEST_HARNESS=1 ORP_ROOT="$fix" ORP_MODULES_PATH="$fix/modules" \
	"$HELPER" module activate FifoMod >"$fix/fifo.out" 2>"$fix/fifo.err"
fifo_rc=$?
set -e
[ "$fifo_rc" -ne 0 ]
[ "$fifo_rc" -ne 124 ]
[ ! -e "$share/events.d/ModuleFifo.tcl" ]
echo "ok: a fifo module file is refused without blocking"

printf 'regular\n' > "$fix/modules/SwapMod/svxlink/events.d/ModuleSwap.tcl"
set +e
sudo -n env ORP_BENCH_TEST_HARNESS=1 ORP_MODULE_SWAP_WAIT=1 ORP_ROOT="$fix" ORP_MODULES_PATH="$fix/modules" \
	"$HELPER" module activate SwapMod >"$fix/swap.out" 2>"$fix/swap.err" &
swap_pid=$!
swapped=0
for _ in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 19 20; do
	if [ -f "$fix/var/lib/openrepeater/module-install/SwapMod.list" ]; then
		rm -f "$fix/modules/SwapMod/svxlink/events.d/ModuleSwap.tcl"
		mkfifo "$fix/modules/SwapMod/svxlink/events.d/ModuleSwap.tcl"
		swapped=1
		break
	fi
	sleep 0.1
done
wait "$swap_pid"
swap_rc=$?
set -e
[ "$swapped" = "1" ]
[ "$swap_rc" -ne 0 ]
grep -q 'private regular file' "$fix/swap.err"
[ ! -e "$share/events.d/ModuleSwap.tcl" ]
echo "ok: a fifo swapped in after the name check is refused"

sudo -n env ORP_BENCH_TEST_HARNESS=1 ORP_ROOT="$fix" ORP_MODULES_PATH="$fix/modules" \
	"$HELPER" module deactivate OrphanMod
[ ! -e "$share/events.d/ModuleOrphan.tcl" ]
[ ! -e "$fix/var/lib/openrepeater/module-install/OrphanMod.list" ]
[ "$(cat "$share/events.d/Keep.tcl")" = "keep" ]
echo "ok: deactivation removes an orphan recorded in the intent journal"

sudo -n chown -R "$(id -u):$(id -g)" "$(orp_fixture_root)" || true
echo "module zip checks passed"
