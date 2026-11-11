#!/bin/bash
# Trusted functional-test token lifts bench blocks. No token keeps them.
set -euo pipefail

ROOT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
# shellcheck source=lib/fixture_tmpdir.sh
. "$ROOT_DIR/upgrade/tests/lib/fixture_tmpdir.sh"
orp_use_fixture_tmpdir
tmp=$(orp_mktemp_dir)
trap 'sudo -n chown -R "$(id -u):$(id -g)" "$tmp" 2>/dev/null || true; orp_cleanup_fixture "$tmp"' EXIT

host="$tmp/hostname"
mode="$tmp/operating-mode"
marker="$tmp/bench-mode"
printf 'orp-test\n' > "$host"
printf 'functional-test\n' > "$mode"
chmod 644 "$mode"
sudo chown 0:0 "$mode"
printf 'bench\n' > "$marker"
printf 'armed\n' > "$tmp/tx-armed"
chmod 644 "$tmp/tx-armed"
sudo chown 0:0 "$tmp/tx-armed"
preview=$(mktemp -d "$(orp_fixture_root)/orp-preview-lift.XXXXXX")
chmod 755 "$preview"
trap 'sudo -n chown -R "$(id -u):$(id -g)" "$tmp" 2>/dev/null || true; orp_cleanup_fixture "$tmp" "$preview"' EXIT

php -r '
require $argv[1] . "/includes/classes/BenchGuard.php";
require $argv[1] . "/includes/classes/RequestGuard.php";
require $argv[1] . "/includes/classes/SVXLink.php";
function fail($msg) { fwrite(STDERR, "FAIL: {$msg}\n"); exit(1); }
$allowed = array(
	array("svxlink", "start"),
	array("svxlink", "stop"),
	array("svxlink", "restart"),
	array("svxlink", "unmask"),
	array("system", "restart"),
	array("system", "stop"),
	array("remotetrx", "start"),
	array("remotetrx", "stop"),
	array("remotetrx", "restart"),
	array("remotetrx", "unmask"),
	array("svxreflector", "start"),
	array("svxreflector", "stop"),
	array("svxreflector", "restart"),
	array("svxreflector", "unmask"),
	array("alsa", "backup"),
	array("alsa", "restore"),
);
$refused = array(
	array("svxlink", "enable"),
	array("remotetrx", "enable"),
	array("svxreflector", "enable"),
	array("svxlink", "gpio_up"),
	array("svxlink", "gpio_down"),
	array("set_mixer", "set_mixer"),
);
putenv("ORP_BENCH_TEST_HARNESS=1");
putenv("ORP_BENCH_HOSTNAME_FILE=" . $argv[2]);
putenv("ORP_OPERATING_MODE_FILE=" . $argv[3]);
putenv("ORP_BENCH_MARKER=" . $argv[4]);
$guard = BenchGuard::detect();
if ($guard->uiBlocksLifted() !== true) fail("trusted token did not lift UI blocks");
if ($guard->txArmed() !== false) fail("tx-armed was present by default");
foreach ($allowed as $pair) {
	if ($guard->commandAllowed($pair[0], $pair[1]) !== true) {
		fail("token refused {$pair[0]} {$pair[1]}");
	}
	if (RequestGuard::helperActionAllowed($pair[0], $pair[1]) !== true) {
		fail("helper allowlist refused {$pair[0]} {$pair[1]} with the token");
	}
}
foreach ($refused as $pair) {
	if ($guard->commandAllowed($pair[0], $pair[1]) !== false) {
		fail("token allowed {$pair[0]} {$pair[1]}");
	}
	if (RequestGuard::helperActionAllowed($pair[0], $pair[1]) !== false) {
		fail("helper allowlist allowed {$pair[0]} {$pair[1]}");
	}
}
$preview = $argv[7];
putenv("ORP_BENCH_PREVIEW=" . $preview);
$settings = array(
	"orp_Mode" => "repeater",
	"callSign" => "TEST",
	"txTailValueSec" => "1",
	"rxTone" => "",
	"txTone" => "",
);
$ports = array(1 => array(
	"rxAudioDev" => "plughw:0|0",
	"txAudioDev" => "plughw:0|0",
	"rxMode" => "cos",
	"rxGPIO" => "23",
	"txGPIO" => "26",
));
$svx = new SVXLink($settings, $ports, array());
$dest = $svx->configDestination("ORP_RepeaterLogic_Port1.tcl");
if ($dest !== $preview . "/ORP_RepeaterLogic_Port1.tcl") fail("repeater logic destination was " . var_export($dest, true));
if ($svx->configDestination("ORP_SimplexLogic_Port2.tcl") !== $preview . "/ORP_SimplexLogic_Port2.tcl") fail("simplex logic destination was missing");
if ($svx->configDestination("gpio.conf") !== $preview . "/gpio.conf") fail("gpio.conf was not staged");
if ($svx->configDestination("Logic.tcl") !== $preview . "/Logic.tcl") fail("Logic.tcl was not staged");
$off = $svx->build_tx(1);
if (!isset($off["Tx1"]["PTT_TYPE"]) || $off["Tx1"]["PTT_TYPE"] !== "NONE") fail("unarmed repeater build_tx was not PTT_TYPE=NONE");
putenv("ORP_TX_ARMED_FILE=" . $argv[6]);
$armed = BenchGuard::detect();
if ($armed->txArmed() !== true) fail("root tx-armed flag was not trusted");
if ($armed->commandAllowed("svxlink", "gpio_up") !== true) fail("tx-armed still blocked gpio_up");
if (RequestGuard::helperActionAllowed("svxlink", "gpio_up") !== true) fail("tx-armed helper still blocked gpio_up");
if ($armed->commandAllowed("svxlink", "enable") !== false) fail("tx-armed allowed enable");
$wired = (new SVXLink($settings, $ports, array()))->build_tx(1);
if (!isset($wired["TX_Port1"]["PTT_TYPE"]) || $wired["TX_Port1"]["PTT_TYPE"] !== "GPIO") fail("armed build_tx was not GPIO");
if (!isset($wired["TX_Port1"]["PTT_PIN"]) || $wired["TX_Port1"]["PTT_PIN"] !== "gpio26") fail("armed build_tx pin was not gpio26");
if ($svx->write_config("namespace eval Logic {}\n", "Logic.tcl", "text") !== true) fail("Logic.tcl was not written");
if ($svx->write_config("GPIO\n", "gpio.conf", "text") !== true) fail("gpio.conf was not written");
if ($svx->write_config("proc {}\n", "ORP_RepeaterLogic_Port1.tcl", "text") !== true) fail("repeater logic was not written");
putenv("ORP_OPERATING_MODE_FILE=" . $argv[5]);
file_put_contents($argv[5], "bench\n");
chmod($argv[5], 0644);
$blocked = BenchGuard::detect();
if ($blocked->uiBlocksLifted() !== false) fail("bench token lifted UI blocks");
foreach (array_merge($allowed, $refused) as $pair) {
	$benchAllowsStop = ($pair[1] === "stop" && in_array($pair[0], array("svxlink", "remotetrx", "svxreflector"), true));
	if (!$benchAllowsStop && $blocked->commandAllowed($pair[0], $pair[1]) !== false) {
		fail("bench allowed {$pair[0]} {$pair[1]}");
	}
	if ($pair[0] === "svxlink" && ($pair[1] === "start" || $pair[1] === "restart" || $pair[1] === "stop")) {
		if (RequestGuard::helperActionAllowed($pair[0], $pair[1]) !== true) {
			fail("svxlink {$pair[1]} left the base allowlist");
		}
	} elseif (RequestGuard::helperActionAllowed($pair[0], $pair[1]) !== false) {
		fail("helper allowlist allowed {$pair[0]} {$pair[1]} without the token");
	}
}
echo "ok: lifted actions stay available, enable and mixer stay refused, and repeater wiring needs tx-armed\n";
' "$ROOT_DIR" "$host" "$mode" "$marker" "$tmp/bench-mode" "$tmp/tx-armed" "$preview"

layout="$tmp/root"
mkdir -p "$layout/etc/openrepeater"
printf 'orp-test\n' > "$layout/etc/hostname"
printf 'functional-test\n' > "$layout/etc/openrepeater/operating-mode"
chmod 644 "$layout/etc/openrepeater/operating-mode"
sudo chown 0:0 "$layout/etc/openrepeater/operating-mode"
HELPER="$ROOT_DIR/install/scripts/orp_helper"
ctl="$tmp/systemctl"
cat > "$ctl" <<'EOF'
#!/bin/bash
printf '%s\n' "$*" >> "${ORP_SYSTEMCTL_LOG:?}"
if [ "$1" = "is-enabled" ]; then
	echo disabled
	exit 1
fi
exit 0
EOF
chmod 755 "$ctl"
log="$tmp/systemctl.log"
: > "$log"
gpio_up="$tmp/gpio-up"
gpio_down="$tmp/gpio-down"
printf '#!/bin/bash\necho gpio-up\n' > "$gpio_up"
printf '#!/bin/bash\necho gpio-down\n' > "$gpio_down"
chmod 755 "$gpio_up" "$gpio_down"
run_helper() {
	ORP_BENCH_TEST_HARNESS=1 ORP_ROOT="$layout" ORP_SYSTEMCTL="$ctl" ORP_SYSTEMCTL_LOG="$log" \
		ORP_BENCH_HOSTNAME_FILE="$host" ORP_BENCH_MARKER="$marker" \
		SVXLINK_GPIO_UP_BIN="$gpio_up" SVXLINK_GPIO_DOWN_BIN="$gpio_down" \
		"$HELPER" "$@"
}
out=$(run_helper svxlink start)
grep -q 'start svxlink.service' "$log"
out=$(run_helper svxlink restart)
grep -q 'restart svxlink.service' "$log"
set +e
blocked_gpio=$(run_helper svxlink gpio_up)
blocked_gpio_rc=$?
enable_out=$(run_helper svxlink enable)
enable_rc=$?
rtx_enable=$(run_helper remotetrx enable)
rtx_rc=$?
ref_enable=$(run_helper svxreflector enable)
ref_rc=$?
set -e
[ "$blocked_gpio_rc" -ne 0 ]
printf '%s\n' "$blocked_gpio" | grep -q 'refused:'
[ "$enable_rc" -ne 0 ]
printf '%s\n' "$enable_out" | grep -q 'enable stays blocked'
[ "$rtx_rc" -ne 0 ]
printf '%s\n' "$rtx_enable" | grep -q 'enable stays blocked'
[ "$ref_rc" -ne 0 ]
printf '%s\n' "$ref_enable" | grep -q 'enable stays blocked'
out=$(ORP_TX_ARMED_FILE="$tmp/tx-armed" run_helper svxlink gpio_up)
printf '%s\n' "$out" | grep -q 'gpio-up'
out=$(ORP_TX_ARMED_FILE="$tmp/tx-armed" run_helper svxlink gpio_down)
printf '%s\n' "$out" | grep -q 'gpio-down'
out=$(run_helper remotetrx unmask)
grep -q 'unmask remotetrx.service' "$log"
out=$(run_helper svxreflector start)
grep -q 'start svxreflector.service' "$log"
out=$(run_helper system restart)
printf '%s\n' "$out" | grep -q '^host-action-accepted system restart$'
out=$(run_helper system stop)
printf '%s\n' "$out" | grep -q '^host-action-accepted system stop$'
echo "ok: the helper runs start, armed GPIO, and host actions, and refuses enable"

printf 'bench\n' > "$tmp/bench-only"
chmod 644 "$tmp/bench-only"
bare="$tmp/bare-root"
mkdir -p "$bare/etc"
printf 'fixture-host\n' > "$bare/etc/hostname"
: > "$log"
set +e
ORP_BENCH_TEST_HARNESS=1 ORP_ROOT="$bare" ORP_SYSTEMCTL="$ctl" ORP_SYSTEMCTL_LOG="$log" \
	ORP_OPERATING_MODE_FILE="$tmp/bench-only" ORP_BENCH_HOSTNAME_FILE="$host" ORP_BENCH_MARKER="$marker" \
	"$HELPER" svxlink gpio_up >"$tmp/gpio-off.out" 2>"$tmp/gpio-off.err"
gpio_rc=$?
ORP_BENCH_TEST_HARNESS=1 ORP_ROOT="$bare" ORP_SYSTEMCTL="$ctl" ORP_SYSTEMCTL_LOG="$log" \
	ORP_OPERATING_MODE_FILE="$tmp/bench-only" ORP_BENCH_HOSTNAME_FILE="$host" ORP_BENCH_MARKER="$marker" \
	"$HELPER" svxlink unmask >"$tmp/unmask-off.out" 2>"$tmp/unmask-off.err"
unmask_rc=$?
ORP_BENCH_TEST_HARNESS=1 ORP_ROOT="$bare" ORP_OPERATING_MODE_FILE="$tmp/bench-only" ORP_BENCH_HOSTNAME_FILE="$host" \
	ORP_BENCH_MARKER="$marker" "$HELPER" system restart >"$tmp/reboot-off.out" 2>"$tmp/reboot-off.err"
reboot_rc=$?
set -e
[ "$gpio_rc" -ne 0 ]
grep -q 'refused:' "$tmp/gpio-off.out"
[ "$unmask_rc" -ne 0 ]
grep -q 'refused:' "$tmp/unmask-off.out"
[ "$reboot_rc" -ne 0 ]
grep -q 'refused:' "$tmp/reboot-off.out"
if grep -q 'unmask ' "$log"; then
	echo "FAIL: unmask ran without the trusted token" >&2
	exit 1
fi
echo "ok: GPIO, unmask, and host restart are refused without the trusted token"

unmask_root="$tmp/unmask-root"
mkdir -p "$unmask_root/etc/openrepeater" "$unmask_root/etc/systemd/system/multi-user.target.wants"
printf 'orp-test\n' > "$unmask_root/etc/hostname"
printf 'functional-test\n' > "$unmask_root/etc/openrepeater/operating-mode"
chmod 644 "$unmask_root/etc/openrepeater/operating-mode"
sudo chown 0:0 "$unmask_root/etc/openrepeater/operating-mode"
for unit in svxlink.service remotetrx.service svxreflector.service; do
	ln -sfn /dev/null "$unmask_root/etc/systemd/system/$unit"
	ln -sfn "/lib/systemd/system/$unit" "$unmask_root/etc/systemd/system/multi-user.target.wants/$unit"
done
: > "$tmp/unmask.log"
unmask_out=$(
	export ROOT="$unmask_root"
	export ORP_SYSTEMCTL="$ctl"
	export ORP_SYSTEMCTL_LOG="$tmp/unmask.log"
	# shellcheck source=../lib/bench-target.sh
	. "$ROOT_DIR/upgrade/lib/bench-target.sh"
	bench_unmask_radio_units
)
for unit in svxlink.service remotetrx.service svxreflector.service; do
	[ ! -e "$unmask_root/etc/systemd/system/$unit" ]
	[ ! -e "$unmask_root/etc/systemd/system/multi-user.target.wants/$unit" ]
	grep -q "unmask ${unit}" "$tmp/unmask.log"
	grep -q "disable ${unit}" "$tmp/unmask.log"
	printf '%s\n' "$unmask_out" | grep -q "is-enabled=disabled ${unit}"
done
printf 'bench\n' | sudo tee "$unmask_root/etc/openrepeater/operating-mode" >/dev/null
sudo chown 0:0 "$unmask_root/etc/openrepeater/operating-mode"
ln -sfn /dev/null "$unmask_root/etc/systemd/system/svxlink.service"
(
	export ROOT="$unmask_root"
	export ORP_SYSTEMCTL="$ctl"
	export ORP_SYSTEMCTL_LOG="$tmp/unmask.log"
	. "$ROOT_DIR/upgrade/lib/bench-target.sh"
	bench_unmask_radio_units
)
[ -L "$unmask_root/etc/systemd/system/svxlink.service" ]
echo "ok: a trusted token unmasks, disables, and clears wants links"

php -d disable_functions=shell_exec -r '
require $argv[1] . "/includes/classes/BenchGuard.php";
putenv("ORP_BENCH_TEST_HARNESS=1");
putenv("ORP_BENCH_HOSTNAME_FILE=" . $argv[2]);
putenv("ORP_OPERATING_MODE_FILE=" . $argv[3]);
$guard = BenchGuard::detect();
if ($guard->trustedFunctionalTest()) {
	fwrite(STDERR, "FAIL: shell_exec disabled still trusted the token\n");
	exit(1);
}
echo "ok: extended ACL check fails closed when shell_exec is disabled\n";
' "$ROOT_DIR" "$host" "$mode"

# shellcheck source=lib/native_layout.sh
. "$ROOT_DIR/upgrade/tests/lib/native_layout.sh"
pubroot="$tmp/publish"
db="$tmp/publish.db"
plant_native_layout "$pubroot"
chmod 755 "$pubroot" "$pubroot/etc" "$pubroot/etc/svxlink"
orp_copy_writable "$ROOT_DIR/install/sql/openrepeater.db" "$db"
apply_ident_profile "$db"
sqlite3 "$db" "UPDATE settings SET value='FIXTURE' WHERE keyID='callSign'; UPDATE settings SET value='repeater' WHERE keyID='orp_Mode';"
mkdir -p "$pubroot/etc/openrepeater" "$pubroot/var/lib/openrepeater/bench-preview"
printf 'orp-test\n' > "$pubroot/etc/hostname"
printf 'functional-test\n' > "$pubroot/etc/openrepeater/operating-mode"
chmod 644 "$pubroot/etc/openrepeater/operating-mode"
sudo chown 0:0 "$pubroot/etc/openrepeater/operating-mode"
printf '%s\n' 'PTT_TYPE=GPIO' 'PTT_PIN=gpio26' > "$pubroot/var/lib/openrepeater/bench-preview/svxlink.conf"
chmod 644 "$pubroot/var/lib/openrepeater/bench-preview/svxlink.conf"
dir="$tmp"
while [ -n "$dir" ] && [ "$dir" != "/" ]; do
	chmod a+x "$dir"
	case "$dir" in
		/tmp|/var/tmp) break ;;
	esac
	dir=$(dirname "$dir")
done
chmod -R a+rX "$pubroot/var/lib/openrepeater"
off_pub=$(sudo -n env ORP_BENCH_TEST_HARNESS=1 ORP_ROOT="$pubroot" ORP_DB_PATH="$db" \
	ORP_OPERATING_MODE_FILE="$pubroot/etc/openrepeater/operating-mode" \
	ORP_BENCH_HOSTNAME_FILE="$pubroot/etc/hostname" \
	ORP_TEST_TMPDIR="${ORP_TEST_TMPDIR:-}" TMPDIR="${TMPDIR:-}" \
	"$HELPER" config publish)
printf '%s\n' "$off_pub" | grep -q 'PTT_TYPE=NONE'
if printf '%s\n' "$off_pub" | grep -q 'stored-wiring'; then
	echo "FAIL: unarmed publish used stored wiring" >&2
	exit 1
fi
grep -q '^PTT_TYPE=NONE$' "$pubroot/etc/svxlink/svxlink.conf"
mkdir -p "$pubroot/var/backups/orp-ui"
chmod 755 "$pubroot/var" "$pubroot/var/backups" "$pubroot/var/backups/orp-ui"
printf 'armed\n' > "$pubroot/etc/openrepeater/tx-armed"
chmod 644 "$pubroot/etc/openrepeater/tx-armed"
sudo chown 0:0 "$pubroot/etc/openrepeater/tx-armed"
on_pub=$(sudo -n env ORP_BENCH_TEST_HARNESS=1 ORP_ROOT="$pubroot" ORP_DB_PATH="$db" \
	ORP_OPERATING_MODE_FILE="$pubroot/etc/openrepeater/operating-mode" \
	ORP_BENCH_HOSTNAME_FILE="$pubroot/etc/hostname" \
	ORP_TEST_TMPDIR="${ORP_TEST_TMPDIR:-}" TMPDIR="${TMPDIR:-}" \
	"$HELPER" config publish)
printf '%s\n' "$on_pub" | grep -q '^runtime=stored-wiring PTT_TYPE=GPIO PTT_PIN=gpio26$'
grep -q '^PTT_TYPE=GPIO$' "$pubroot/etc/svxlink/svxlink.conf"
grep -q '^PTT_PIN=gpio26$' "$pubroot/etc/svxlink/svxlink.conf"
echo "ok: tx-armed publish prints the stored PTT type and pin"
echo "functional-test lift checks passed"
