#!/bin/bash
# A functional-test rebuild writes svxlink.conf and gpio.conf as separate files.
set -euo pipefail

ROOT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
# shellcheck source=lib/fixture_tmpdir.sh
. "$ROOT_DIR/upgrade/tests/lib/fixture_tmpdir.sh"
orp_use_fixture_tmpdir
tmp=$(orp_mktemp_dir)
preview=$(mktemp -d "$(orp_fixture_root)/orp-preview-split.XXXXXX")
chmod 755 "$preview"
trap 'sudo -n chown -R "$(id -u):$(id -g)" "$tmp" 2>/dev/null || true; orp_cleanup_fixture "$tmp" "$preview"' EXIT

host="$tmp/hostname"
mode="$tmp/operating-mode"
printf 'orp-test\n' > "$host"
printf 'functional-test\n' > "$mode"
chmod 644 "$mode"
sudo -n chown 0:0 "$mode"

php -r '
require $argv[1] . "/includes/classes/BenchGuard.php";
require $argv[1] . "/includes/classes/SVXLink.php";
function fail($msg) { fwrite(STDERR, "FAIL: {$msg}\n"); exit(1); }
putenv("ORP_BENCH_TEST_HARNESS=1");
putenv("ORP_BENCH_HOSTNAME_FILE=" . $argv[2]);
putenv("ORP_OPERATING_MODE_FILE=" . $argv[3]);
putenv("ORP_BENCH_MARKER=" . $argv[3] . ".missing");
putenv("ORP_BENCH_PREVIEW=" . $argv[4]);
$svx = new SVXLink(array("callSign" => "FIXTURE", "ID_Short_Mode" => "disabled", "ID_Long_Mode" => "disabled"), array(), array());
if ($svx->configDestination("svxlink.conf") !== $argv[4] . "/svxlink.conf") fail("svxlink.conf destination");
if ($svx->configDestination("gpio.conf") !== $argv[4] . "/gpio.conf") fail("gpio.conf destination");
$ini = array(
	"GLOBAL" => array("LOGICS" => "RepeaterLogic", "MODULE_PATH" => "/usr/local/lib/svxlink"),
	"RepeaterLogic" => array("TYPE" => "Repeater", "CALLSIGN" => "FIXTURE"),
);
if ($svx->write_config($ini, "svxlink.conf", "ini") !== true) fail("svxlink.conf was not written");
if ($svx->write_config("GPIO_OUT_HIGH=\"gpio498\"\nGPIO_OUT_LOW=\"\"\n", "gpio.conf", "text") !== true) fail("gpio.conf was not written");
$conf = file_get_contents($argv[4] . "/svxlink.conf");
$gpio = file_get_contents($argv[4] . "/gpio.conf");
if (strpos($conf, "[GLOBAL]") === false || strpos($conf, "LOGICS=RepeaterLogic") === false || strpos($conf, "[RepeaterLogic]") === false) {
	fail("svxlink.conf is missing the logic document");
}
if (strpos($conf, "GPIO_OUT_HIGH") !== false || strpos($conf, "gpio498") !== false) {
	fail("gpio.conf content was written into svxlink.conf");
}
if (strpos($gpio, "GPIO_OUT_HIGH=\"gpio498\"") === false) {
	fail("gpio.conf did not keep the pin list");
}
if (strpos($gpio, "[GLOBAL]") !== false || strpos($gpio, "LOGICS=") !== false) {
	fail("svxlink.conf content was written into gpio.conf");
}
echo "ok: svxlink.conf keeps the logic document and gpio.conf keeps the pin list\n";
' "$ROOT_DIR" "$host" "$mode" "$preview"
echo "preview split checks passed"
