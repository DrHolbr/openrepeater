#!/bin/bash
# Root-owned operating mode and preset output support. No radio is started.
set -euo pipefail

ROOT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
host="$tmp/hostname"
marker="$tmp/bench-mode"
mode="$tmp/operating-mode"
missing="$tmp/no-marker"
printf 'orp-test\n' > "$host"
: > "$marker"
: > "$missing"
rm -f "$missing"

php -r '
require $argv[1] . "/includes/classes/BenchGuard.php";
require $argv[1] . "/includes/classes/GpioMap.php";
function fail($msg) { fwrite(STDERR, "FAIL: {$msg}\n"); exit(1); }
putenv("ORP_BENCH_TEST_HARNESS=1");
putenv("ORP_BENCH_HOSTNAME_FILE=" . $argv[2]);
putenv("ORP_BENCH_MARKER=" . $argv[3]);
putenv("ORP_OPERATING_MODE_FILE=" . $argv[4]);
file_put_contents($argv[4], "functional-test\n");
chmod($argv[4], 0644);
$guard = BenchGuard::detect();
if ($guard->operatingMode() !== "functional-test") fail("trusted functional-test token was not read");
if ($guard->isBench() !== true) fail("functional-test was treated as legacy operation");
if ($guard->commandAllowed("svxlink", "start") !== false) fail("functional-test allowed svxlink start");
if ($guard->commandAllowed("svxlink", "unmask") !== false) fail("functional-test allowed unmask");
if ($guard->commandAllowed("svxlink", "gpio_up") !== false) fail("functional-test allowed gpio_up");
if ($guard->commandAllowed("system", "stop") !== false) fail("functional-test allowed shutdown");
chmod($argv[4], 0666);
if (BenchGuard::detect()->operatingMode() !== "bench") fail("world-writable mode file was trusted");
chmod($argv[4], 0644);
$link = $argv[4] . ".link";
symlink($argv[4], $link);
putenv("ORP_OPERATING_MODE_FILE=" . $link);
if (BenchGuard::detect()->operatingMode() !== "bench") fail("symlink mode file was trusted");
putenv("ORP_OPERATING_MODE_FILE=" . $argv[5]);
if (BenchGuard::detect()->operatingMode() !== "bench") fail("deleting the mode file left orp-test");
putenv("ORP_BENCH_HOSTNAME_FILE=" . $argv[6]);
putenv("ORP_BENCH_MARKER=" . $argv[5]);
file_put_contents($argv[6], "other\n");
if (BenchGuard::detect()->operatingMode() !== "legacy") fail("a non-bench host without a marker was forced into bench");
if (BenchGuard::detect()->commandAllowed("svxlink", "start") !== true) fail("legacy start was blocked");
$defs = GpioMap::loadDefinitions($argv[1] . "/includes/board_definitions.php");
if (count($defs) !== 5) fail("board preset count was " . count($defs));
$saw498 = false;
$saw26 = false;
foreach (GpioMap::fromDefinitions($defs) as $row) {
	if ($row["drivable"] !== false || $row["output_supported"] !== false) fail("a preset row was marked drivable");
	if ($row["stored_number"] === "498" && $row["logical_name"] === "txGPIO") {
		$saw498 = true;
		if ($row["class"] !== "unresolved_sysfs_number" || $row["chip_candidate"] !== null) {
			fail("TX 498 was given a chip");
		}
	}
	if ($row["stored_number"] === "26" && $row["logical_name"] === "rxGPIO") {
		$saw26 = true;
		if ($row["chip_candidate"] !== "gpiochip0" || $row["line_offset_candidate"] !== 26) {
			fail("RX 26 was not recorded as gpiochip0 offset 26");
		}
	}
}
if (!$saw498 || !$saw26) fail("preset rows for 498 and 26 were missing");
echo "ok: functional-test token does not unmask or drive, and unresolved preset outputs stay unsupported\n";
' "$ROOT_DIR" "$host" "$marker" "$mode" "$missing" "$tmp/other-host"

printf 'functional-test\n' > "$mode"
chmod 644 "$mode"
export ORP_BENCH_TEST_HARNESS=1
export ORP_BENCH_HOSTNAME_FILE="$host"
export ORP_BENCH_MARKER="$missing"
export ORP_OPERATING_MODE_FILE="$mode"
set +e
out=$("$ROOT_DIR/install/scripts/orp_helper" svxlink start 2>&1)
set -e
printf '%s\n' "$out" | grep -q 'refused:'
if printf '%s\n' "$out" | grep -q 'systemctl'; then
	echo "FAIL: functional-test start reached systemctl" >&2
	exit 1
fi
echo "ok: helper refuses svxlink start in functional-test without calling systemctl"

mkdir -p "$tmp/root/etc/openrepeater"
printf 'orp-test\n' > "$tmp/root/etc/hostname"
if [ "$(id -u)" -eq 0 ]; then
	ORP_ROOT="$tmp/root" "$ROOT_DIR/upgrade/set-operating-mode.sh" functional-test >"$tmp/switch.out"
	grep -q 'operating-mode=functional-test' "$tmp/switch.out"
	grep -q 'no unit was unmasked' "$tmp/switch.out"
	[ "$(tr -d '[:space:]' < "$tmp/root/etc/openrepeater/operating-mode")" = "functional-test" ]
	echo "ok: root switch writes functional-test and does not unmask"
else
	set +e
	denied=$("$ROOT_DIR/upgrade/set-operating-mode.sh" functional-test 2>&1)
	denied_rc=$?
	set -e
	[ "$denied_rc" -eq 1 ]
	printf '%s\n' "$denied" | grep -q 'refused: operating mode is set by root'
	echo "ok: non-root cannot switch operating mode"
fi
echo "operating mode checks passed"
