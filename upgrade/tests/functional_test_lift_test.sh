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

printf 'yes\n' > "$tmp/tx-no"
chmod 644 "$tmp/tx-no"
sudo chown 0:0 "$tmp/tx-no"
php -r '
require $argv[1] . "/includes/classes/BenchGuard.php";
putenv("ORP_BENCH_TEST_HARNESS=1");
putenv("ORP_BENCH_HOSTNAME_FILE=" . $argv[2]);
putenv("ORP_OPERATING_MODE_FILE=" . $argv[3]);
putenv("ORP_TX_ARMED_FILE=" . $argv[4]);
$guard = BenchGuard::detect();
if ($guard->txArmed()) {
	fwrite(STDERR, "FAIL: tx-armed accepted contents other than armed\n");
	exit(1);
}
echo "ok: tx-armed contents must be exactly armed\n";
' "$ROOT_DIR" "$host" "$mode" "$tmp/tx-no"

layout="$tmp/root"
mkdir -p "$layout/etc/openrepeater"
printf 'orp-test\n' > "$layout/etc/hostname"
printf 'functional-test\n' > "$layout/etc/openrepeater/operating-mode"
chmod 644 "$layout/etc/openrepeater/operating-mode"
sudo chown 0:0 "$layout/etc/openrepeater" "$layout/etc/openrepeater/operating-mode"
sudo chmod 755 "$layout/etc/openrepeater"
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
sudo -n chown 0:0 "$gpio_up" "$gpio_down"
run_helper() {
	ORP_BENCH_TEST_HARNESS=1 ORP_ROOT="$layout" ORP_SYSTEMCTL="$ctl" ORP_SYSTEMCTL_LOG="$log" \
		ORP_BENCH_HOSTNAME_FILE="$host" ORP_BENCH_MARKER="$marker" \
		SVXLINK_GPIO_UP_BIN="$gpio_up" SVXLINK_GPIO_DOWN_BIN="$gpio_down" \
		"$HELPER" "$@"
}
: > "$log"
set +e
start_out=$(run_helper svxlink start)
start_rc=$?
restart_out=$(run_helper svxlink restart)
restart_rc=$?
set -e
[ "$start_rc" -ne 0 ]
printf '%s\n' "$start_out" | grep -q 'refused:'
[ "$restart_rc" -ne 0 ]
printf '%s\n' "$restart_out" | grep -q 'refused:'
if grep -q 'start svxlink.service' "$log" || grep -q 'restart svxlink.service' "$log"; then
	echo "FAIL: unarmed start ran without a disconnected snapshot" >&2
	exit 1
fi
echo "ok: unarmed svxlink start and restart stay refused without the disconnected snapshot"
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
user_gpio="$tmp/gpio-user"
cp "$gpio_up" "$user_gpio"
sudo -n chown "$(id -u):$(id -g)" "$user_gpio"
chmod 755 "$user_gpio"
set +e
user_out=$(ORP_BENCH_TEST_HARNESS=1 ORP_ROOT="$layout" ORP_TX_ARMED_FILE="$tmp/tx-armed" \
	ORP_BENCH_HOSTNAME_FILE="$host" ORP_BENCH_MARKER="$marker" \
	SVXLINK_GPIO_UP_BIN="$user_gpio" SVXLINK_GPIO_DOWN_BIN="$gpio_down" \
	"$HELPER" svxlink gpio_up)
user_rc=$?
set -e
[ "$user_rc" -ne 0 ]
printf '%s\n' "$user_out" | grep -q 'not owned by root'
out=$(ORP_TX_ARMED_FILE="$tmp/tx-armed" run_helper svxlink gpio_down)
printf '%s\n' "$out" | grep -q 'gpio-down'
mkdir -p "$layout/etc/systemd/system/multi-user.target.wants" \
	"$layout/etc/systemd/system/remotetrx.service.requires" \
	"$layout/etc/systemd/system/remotetrx.service.upholds"
ln -sfn /lib/systemd/system/remotetrx.service "$layout/etc/systemd/system/multi-user.target.wants/remotetrx.service"
ln -sfn /lib/systemd/system/remotetrx.service "$layout/etc/systemd/system/remotetrx.service.requires/remotetrx.service"
ln -sfn /lib/systemd/system/remotetrx.service "$layout/etc/systemd/system/remotetrx.service.upholds/remotetrx.service"
out=$(run_helper remotetrx unmask)
grep -q 'unmask remotetrx.service' "$log"
grep -q 'disable remotetrx.service' "$log"
printf '%s\n' "$out" | grep -q 'is-enabled=disabled remotetrx.service'
[ ! -e "$layout/etc/systemd/system/multi-user.target.wants/remotetrx.service" ]
[ ! -e "$layout/etc/systemd/system/remotetrx.service.requires/remotetrx.service" ]
[ ! -e "$layout/etc/systemd/system/remotetrx.service.upholds/remotetrx.service" ]
out=$(run_helper svxreflector start)
grep -q 'start svxreflector.service' "$log"
out=$(run_helper system restart)
printf '%s\n' "$out" | grep -q '^host-action-accepted system restart$'
out=$(run_helper system stop)
printf '%s\n' "$out" | grep -q '^host-action-accepted system stop$'
echo "ok: the helper refuses unarmed start, runs armed GPIO and host actions, and refuses enable"

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
mkdir -p "$unmask_root/etc/openrepeater" \
	"$unmask_root/etc/systemd/system/multi-user.target.wants" \
	"$unmask_root/etc/systemd/system/svxlink.service.requires" \
	"$unmask_root/etc/systemd/system/svxlink.service.upholds"
printf 'orp-test\n' > "$unmask_root/etc/hostname"
printf 'functional-test\n' > "$unmask_root/etc/openrepeater/operating-mode"
chmod 644 "$unmask_root/etc/openrepeater/operating-mode"
sudo chown 0:0 "$unmask_root/etc/openrepeater" "$unmask_root/etc/openrepeater/operating-mode"
sudo chmod 755 "$unmask_root/etc/openrepeater"
for unit in svxlink.service remotetrx.service svxreflector.service; do
	ln -sfn /dev/null "$unmask_root/etc/systemd/system/$unit"
	ln -sfn "/lib/systemd/system/$unit" "$unmask_root/etc/systemd/system/multi-user.target.wants/$unit"
	ln -sfn "/lib/systemd/system/$unit" "$unmask_root/etc/systemd/system/svxlink.service.requires/$unit"
	ln -sfn "/lib/systemd/system/$unit" "$unmask_root/etc/systemd/system/svxlink.service.upholds/$unit"
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
	[ ! -e "$unmask_root/etc/systemd/system/svxlink.service.requires/$unit" ]
	[ ! -e "$unmask_root/etc/systemd/system/svxlink.service.upholds/$unit" ]
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
echo "ok: a trusted token unmasks, disables, and clears wants, requires, and upholds links"

php -d disable_functions=shell_exec,exec,proc_open,popen -r '
require $argv[1] . "/includes/classes/BenchGuard.php";
putenv("ORP_BENCH_TEST_HARNESS=1");
putenv("ORP_BENCH_HOSTNAME_FILE=" . $argv[2]);
putenv("ORP_OPERATING_MODE_FILE=" . $argv[3]);
$guard = BenchGuard::detect();
if (!$guard->trustedFunctionalTest()) {
	fwrite(STDERR, "FAIL: a root-owned token was refused with shell_exec disabled\n");
	exit(1);
}
echo "ok: the token check does not spawn a helper\n";
' "$ROOT_DIR" "$host" "$mode"

# shellcheck source=lib/native_layout.sh
. "$ROOT_DIR/upgrade/tests/lib/native_layout.sh"
pubroot="$tmp/publish"
db="$tmp/publish.db"
plant_native_layout "$pubroot"
mkdir -p "$pubroot/var/backups/orp-ui"
chmod 755 "$pubroot" "$pubroot/etc" "$pubroot/etc/svxlink" \
	"$pubroot/var" "$pubroot/var/backups" "$pubroot/var/backups/orp-ui"
orp_copy_writable "$ROOT_DIR/install/sql/openrepeater.db" "$db"
apply_ident_profile "$db"
sqlite3 "$db" "UPDATE settings SET value='FIXTURE' WHERE keyID='callSign'; UPDATE settings SET value='repeater' WHERE keyID='orp_Mode';"
mkdir -p "$pubroot/etc/openrepeater" "$pubroot/var/lib/openrepeater/bench-preview"
printf 'orp-test\n' > "$pubroot/etc/hostname"
printf 'functional-test\n' > "$pubroot/etc/openrepeater/operating-mode"
chmod 644 "$pubroot/etc/openrepeater/operating-mode"
sudo chown 0:0 "$pubroot/etc/openrepeater" "$pubroot/etc/openrepeater/operating-mode"
sudo chmod 755 "$pubroot/etc/openrepeater"
printf '%s\n' 'LOGICS=ORP_RepeaterLogic_Port1' '[Tx1]' 'PTT_TYPE=GPIO' 'PTT_PIN=gpio26' '[Tx2]' 'PTT_TYPE=NONE' \
	> "$pubroot/var/lib/openrepeater/bench-preview/svxlink.conf"
printf 'GPIOCONF\n' > "$pubroot/var/lib/openrepeater/bench-preview/gpio.conf"
printf 'LOGICTCL\n' > "$pubroot/var/lib/openrepeater/bench-preview/Logic.tcl"
printf 'PORT1\n' > "$pubroot/var/lib/openrepeater/bench-preview/ORP_RepeaterLogic_Port1.tcl"
printf 'PORT2\n' > "$pubroot/var/lib/openrepeater/bench-preview/ORP_RepeaterLogic_Port2.tcl"
chmod 644 "$pubroot/var/lib/openrepeater/bench-preview/svxlink.conf" \
	"$pubroot/var/lib/openrepeater/bench-preview/gpio.conf" \
	"$pubroot/var/lib/openrepeater/bench-preview/Logic.tcl" \
	"$pubroot/var/lib/openrepeater/bench-preview/ORP_RepeaterLogic_Port1.tcl" \
	"$pubroot/var/lib/openrepeater/bench-preview/ORP_RepeaterLogic_Port2.tcl"
printf 'STALE\n' > "$pubroot/usr/local/share/svxlink/events.d/ORP_RepeaterLogic_Port9.tcl"
orp_fixture_traverse "$tmp"
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
if [ -e "$pubroot/etc/svxlink/gpio.conf" ] || [ -e "$pubroot/usr/local/share/svxlink/events.d/ORP_RepeaterLogic_Port1.tcl" ]; then
	echo "FAIL: unarmed publish installed staged companions" >&2
	exit 1
fi
none_sum=$(sha256sum "$pubroot/etc/svxlink/svxlink.conf")
start_log="$tmp/start.log"
: > "$start_log"
start_pub=$(sudo -n env ORP_BENCH_TEST_HARNESS=1 ORP_ROOT="$pubroot" ORP_DB_PATH="$db" \
	ORP_OPERATING_MODE_FILE="$pubroot/etc/openrepeater/operating-mode" \
	ORP_BENCH_HOSTNAME_FILE="$pubroot/etc/hostname" \
	ORP_SYSTEMCTL="$ctl" ORP_SYSTEMCTL_LOG="$start_log" \
	ORP_TEST_TMPDIR="${ORP_TEST_TMPDIR:-}" TMPDIR="${TMPDIR:-}" \
	"$HELPER" svxlink start)
printf '%s\n' "$start_pub" | grep -q 'start svxlink.service' || grep -q 'start svxlink.service' "$start_log"
printf 'PTT_TYPE=GPIO\n' | sudo -n tee -a "$pubroot/etc/svxlink/svxlink.conf" >/dev/null
: > "$start_log"
set +e
bad_start=$(sudo -n env ORP_BENCH_TEST_HARNESS=1 ORP_ROOT="$pubroot" ORP_DB_PATH="$db" \
	ORP_OPERATING_MODE_FILE="$pubroot/etc/openrepeater/operating-mode" \
	ORP_BENCH_HOSTNAME_FILE="$pubroot/etc/hostname" \
	ORP_SYSTEMCTL="$ctl" ORP_SYSTEMCTL_LOG="$start_log" \
	ORP_TEST_TMPDIR="${ORP_TEST_TMPDIR:-}" TMPDIR="${TMPDIR:-}" \
	"$HELPER" svxlink start)
bad_start_rc=$?
set -e
[ "$bad_start_rc" -ne 0 ]
printf '%s\n' "$bad_start" | grep -q 'PTT_TYPE other than NONE'
if grep -q 'start svxlink.service' "$start_log"; then
	echo "FAIL: unarmed start ran with PTT_TYPE=GPIO" >&2
	exit 1
fi
printf 'PTT_TYPE=GPIO\n' > "$pubroot/etc/svxlink/remotetrx.conf"
chmod 644 "$pubroot/etc/svxlink/remotetrx.conf"
set +e
bad_rtx=$(sudo -n env ORP_BENCH_TEST_HARNESS=1 ORP_ROOT="$pubroot" ORP_DB_PATH="$db" \
	ORP_OPERATING_MODE_FILE="$pubroot/etc/openrepeater/operating-mode" \
	ORP_BENCH_HOSTNAME_FILE="$pubroot/etc/hostname" \
	ORP_SYSTEMCTL="$ctl" ORP_SYSTEMCTL_LOG="$start_log" \
	ORP_TEST_TMPDIR="${ORP_TEST_TMPDIR:-}" TMPDIR="${TMPDIR:-}" \
	"$HELPER" remotetrx start)
bad_rtx_rc=$?
set -e
[ "$bad_rtx_rc" -ne 0 ]
printf '%s\n' "$bad_rtx" | grep -q 'NONE or Dummy'
printf 'PTT_TYPE=Dummy\n' > "$pubroot/etc/svxlink/remotetrx.conf"
dummy_rtx=$(sudo -n env ORP_BENCH_TEST_HARNESS=1 ORP_ROOT="$pubroot" ORP_DB_PATH="$db" \
	ORP_OPERATING_MODE_FILE="$pubroot/etc/openrepeater/operating-mode" \
	ORP_BENCH_HOSTNAME_FILE="$pubroot/etc/hostname" \
	ORP_SYSTEMCTL="$ctl" ORP_SYSTEMCTL_LOG="$start_log" \
	ORP_TEST_TMPDIR="${ORP_TEST_TMPDIR:-}" TMPDIR="${TMPDIR:-}" \
	"$HELPER" remotetrx start)
grep -q 'start remotetrx.service' "$start_log"
printf 'armed\n' | sudo -n tee "$pubroot/etc/openrepeater/tx-armed" >/dev/null
sudo -n chmod 644 "$pubroot/etc/openrepeater/tx-armed"
sudo -n chown 0:0 "$pubroot/etc/openrepeater/tx-armed"
on_pub=$(sudo -n env ORP_BENCH_TEST_HARNESS=1 ORP_ROOT="$pubroot" ORP_DB_PATH="$db" \
	ORP_OPERATING_MODE_FILE="$pubroot/etc/openrepeater/operating-mode" \
	ORP_BENCH_HOSTNAME_FILE="$pubroot/etc/hostname" \
	ORP_TEST_TMPDIR="${ORP_TEST_TMPDIR:-}" TMPDIR="${TMPDIR:-}" \
	"$HELPER" config publish)
printf '%s\n' "$on_pub" | grep -q '^runtime=stored-wiring PTT_TYPE=GPIO PTT_PIN=gpio26$'
printf '%s\n' "$on_pub" | grep -q '^tx-section=\[Tx1\] PTT_TYPE=GPIO PTT_PIN=gpio26$'
printf '%s\n' "$on_pub" | grep -q '^tx-section=\[Tx2\] PTT_TYPE=NONE$'
grep -q '^PTT_TYPE=GPIO$' "$pubroot/etc/svxlink/svxlink.conf"
grep -q '^PTT_PIN=gpio26$' "$pubroot/etc/svxlink/svxlink.conf"
grep -q '^GPIOCONF$' "$pubroot/etc/svxlink/gpio.conf"
grep -q '^LOGICTCL$' "$pubroot/usr/local/share/svxlink/events.d/local/Logic.tcl"
grep -q '^PORT1$' "$pubroot/usr/local/share/svxlink/events.d/ORP_RepeaterLogic_Port1.tcl"
[ ! -e "$pubroot/usr/local/share/svxlink/events.d/ORP_RepeaterLogic_Port2.tcl" ]
[ ! -e "$pubroot/usr/local/share/svxlink/events.d/ORP_RepeaterLogic_Port9.tcl" ]
printf 'STALE\n' > "$pubroot/usr/local/share/svxlink/events.d/ORP_RepeaterLogic_Port9.tcl"
purge_pub=$(sudo -n env ORP_BENCH_TEST_HARNESS=1 ORP_ROOT="$pubroot" ORP_DB_PATH="$db" \
	ORP_OPERATING_MODE_FILE="$pubroot/etc/openrepeater/operating-mode" \
	ORP_BENCH_HOSTNAME_FILE="$pubroot/etc/hostname" \
	ORP_TEST_TMPDIR="${ORP_TEST_TMPDIR:-}" TMPDIR="${TMPDIR:-}" \
	"$HELPER" config publish)
printf '%s\n' "$purge_pub" | grep -q 'removed .*/ORP_RepeaterLogic_Port9.tcl (backup: '
purge_backup=$(printf '%s\n' "$purge_pub" | sed -n 's/.*backup: \(.*\))$/\1/p' | head -n 1)
[ -f "$purge_backup/ORP_RepeaterLogic_Port9.tcl" ]
grep -q '^STALE$' "$purge_backup/ORP_RepeaterLogic_Port9.tcl"
[ ! -e "$pubroot/usr/local/share/svxlink/events.d/ORP_RepeaterLogic_Port9.tcl" ]
grep -q '^PORT1$' "$pubroot/usr/local/share/svxlink/events.d/ORP_RepeaterLogic_Port1.tcl"
sudo -n rm -f "$pubroot/etc/openrepeater/tx-armed"
pre_disarm=$(sha256sum "$pubroot/etc/svxlink/svxlink.conf")
# Companion backups end in Z-<pid>. The one-second svxlink.conf copy does not.
backup_before=$(find "$pubroot/var/backups/orp-ui" -mindepth 1 -maxdepth 1 -type d -printf '%p\n' | grep -E 'Z-[0-9]+$' | LC_ALL=C sort || true)
gpio_canary="$pubroot/gpio-link-target"
printf 'LIVE-GPIO\n' > "$gpio_canary"
sudo -n rm -f "$pubroot/etc/svxlink/gpio.conf"
sudo -n ln -s "$gpio_canary" "$pubroot/etc/svxlink/gpio.conf"
port1_before=$(sha256sum "$pubroot/usr/local/share/svxlink/events.d/ORP_RepeaterLogic_Port1.tcl")
courtesy_before=""
if [ -f "$pubroot/usr/local/share/svxlink/events.d/local/Logic.tcl" ]; then
	courtesy_before=$(sha256sum "$pubroot/usr/local/share/svxlink/events.d/local/Logic.tcl")
fi
set +e
unarmed_roll=$(sudo -n env ORP_BENCH_TEST_HARNESS=1 ORP_ROOT="$pubroot" ORP_DB_PATH="$db" \
	ORP_OPERATING_MODE_FILE="$pubroot/etc/openrepeater/operating-mode" \
	ORP_BENCH_HOSTNAME_FILE="$pubroot/etc/hostname" \
	ORP_TEST_TMPDIR="${ORP_TEST_TMPDIR:-}" TMPDIR="${TMPDIR:-}" \
	"$HELPER" config publish 2>&1)
unarmed_roll_rc=$?
set -e
[ "$unarmed_roll_rc" -ne 0 ]
printf '%s\n' "$unarmed_roll" | grep -q 'is a symbolic link'
if printf '%s\n' "$unarmed_roll" | grep -q 'rolled back'; then
	echo "FAIL: unarmed symlink refusal wrote and then rolled back" >&2
	printf '%s\n' "$unarmed_roll" >&2
	exit 1
fi
[ "$(sha256sum "$pubroot/etc/svxlink/svxlink.conf")" = "$pre_disarm" ]
[ "$(sha256sum "$pubroot/usr/local/share/svxlink/events.d/ORP_RepeaterLogic_Port1.tcl")" = "$port1_before" ]
if [ -n "$courtesy_before" ]; then
	[ "$(sha256sum "$pubroot/usr/local/share/svxlink/events.d/local/Logic.tcl")" = "$courtesy_before" ]
fi
grep -q '^LIVE-GPIO$' "$gpio_canary"
[ -L "$pubroot/etc/svxlink/gpio.conf" ]
[ "$(readlink -f "$pubroot/etc/svxlink/gpio.conf")" = "$(readlink -f "$gpio_canary")" ]
backup_after=$(find "$pubroot/var/backups/orp-ui" -mindepth 1 -maxdepth 1 -type d -printf '%p\n' | grep -E 'Z-[0-9]+$' | LC_ALL=C sort || true)
if [ "$backup_after" != "$backup_before" ]; then
	echo "FAIL: unarmed symlink refusal wrote a backup directory" >&2
	printf 'before:\n%s\nafter:\n%s\n' "$backup_before" "$backup_after" >&2
	exit 1
fi
echo "ok: an unarmed symlink is refused before any publish write"
sudo -n rm -f "$pubroot/etc/svxlink/gpio.conf"
printf 'GPIOCONF\n' > "$pubroot/etc/svxlink/gpio.conf"
disarm_pub=$(sudo -n env ORP_BENCH_TEST_HARNESS=1 ORP_ROOT="$pubroot" ORP_DB_PATH="$db" \
	ORP_OPERATING_MODE_FILE="$pubroot/etc/openrepeater/operating-mode" \
	ORP_BENCH_HOSTNAME_FILE="$pubroot/etc/hostname" \
	ORP_TEST_TMPDIR="${ORP_TEST_TMPDIR:-}" TMPDIR="${TMPDIR:-}" \
	"$HELPER" config publish)
printf '%s\n' "$disarm_pub" | grep -q 'PTT_TYPE=NONE'
printf '%s\n' "$disarm_pub" | grep -q 'removed .*/gpio.conf (backup: '
printf '%s\n' "$disarm_pub" | grep -q 'removed .*/ORP_RepeaterLogic_Port1.tcl (backup: '
backup_dir=$(printf '%s\n' "$disarm_pub" | sed -n 's/.*backup: \(.*\))$/\1/p' | head -n 1)
[ -f "$backup_dir/gpio.conf" ]
[ -f "$backup_dir/ORP_RepeaterLogic_Port1.tcl" ]
[ ! -e "$pubroot/etc/svxlink/gpio.conf" ]
[ ! -e "$pubroot/usr/local/share/svxlink/events.d/ORP_RepeaterLogic_Port1.tcl" ]
printf 'GPIO\n' > "$pubroot/etc/svxlink/gpio.conf"
: > "$start_log"
set +e
wired_start=$(sudo -n env ORP_BENCH_TEST_HARNESS=1 ORP_ROOT="$pubroot" ORP_DB_PATH="$db" \
	ORP_OPERATING_MODE_FILE="$pubroot/etc/openrepeater/operating-mode" \
	ORP_BENCH_HOSTNAME_FILE="$pubroot/etc/hostname" \
	ORP_SYSTEMCTL="$ctl" ORP_SYSTEMCTL_LOG="$start_log" \
	ORP_TEST_TMPDIR="${ORP_TEST_TMPDIR:-}" TMPDIR="${TMPDIR:-}" \
	"$HELPER" svxlink start)
wired_rc=$?
set -e
[ "$wired_rc" -ne 0 ]
printf '%s\n' "$wired_start" | grep -q 'armed wiring'
rm -f "$pubroot/etc/svxlink/gpio.conf"
printf 'armed\n' | sudo -n tee "$pubroot/etc/openrepeater/tx-armed" >/dev/null
sudo -n chmod 644 "$pubroot/etc/openrepeater/tx-armed"
sudo -n chown 0:0 "$pubroot/etc/openrepeater/tx-armed"
armed_sum=$(sha256sum "$pubroot/etc/svxlink/svxlink.conf")
canary="$pubroot/gpio-canary"
printf 'CANARY\n' > "$canary"
sudo -n rm -f "$pubroot/etc/svxlink/gpio.conf"
sudo -n ln -s "$canary" "$pubroot/etc/svxlink/gpio.conf"
printf 'STALE\n' > "$pubroot/usr/local/share/svxlink/events.d/ORP_RepeaterLogic_Port9.tcl"
printf '%s\n' '[Tx1]' 'PTT_TYPE=GPIO' 'PTT_PIN=gpio23' > "$pubroot/var/lib/openrepeater/bench-preview/svxlink.conf"
chmod 644 "$pubroot/var/lib/openrepeater/bench-preview/svxlink.conf"
set +e
roll=$(sudo -n env ORP_BENCH_TEST_HARNESS=1 ORP_ROOT="$pubroot" ORP_DB_PATH="$db" \
	ORP_OPERATING_MODE_FILE="$pubroot/etc/openrepeater/operating-mode" \
	ORP_BENCH_HOSTNAME_FILE="$pubroot/etc/hostname" \
	ORP_TEST_TMPDIR="${ORP_TEST_TMPDIR:-}" TMPDIR="${TMPDIR:-}" \
	"$HELPER" config publish)
roll_rc=$?
set -e
[ "$roll_rc" -ne 0 ]
printf '%s\n' "$roll" | grep -q 'rolled back'
[ "$(sha256sum "$pubroot/etc/svxlink/svxlink.conf")" = "$armed_sum" ]
[ "$(stat -c %u "$canary")" = "$(id -u)" ]
grep -q '^CANARY$' "$canary"
if grep -q 'gpio23' "$pubroot/etc/svxlink/svxlink.conf"; then
	echo "FAIL: rolled-back publish left the new svxlink.conf in place" >&2
	exit 1
fi
grep -q '^STALE$' "$pubroot/usr/local/share/svxlink/events.d/ORP_RepeaterLogic_Port9.tcl"
echo "ok: tx-armed publish installs the staged set and rolls it back"
failcp="$tmp/fail-cp"
mkdir -p "$failcp"
port9="$pubroot/usr/local/share/svxlink/events.d/ORP_RepeaterLogic_Port9.tcl"
cat > "$failcp/cp" <<EOF
#!/bin/bash
dest="\${@: -1}"
if [ "\$dest" = "$port9" ]; then
	echo "refused: restore copy failed" >&2
	exit 1
fi
exec /bin/cp "\$@"
EOF
chmod 755 "$failcp/cp"
conf_before=$(sha256sum "$pubroot/etc/svxlink/svxlink.conf")
courtesy_path="$pubroot/usr/local/share/svxlink/events.d/local/Logic.tcl"
cp -p "$courtesy_path" "$tmp/courtesy-before.tcl"
set +e
bad_cp=$(sudo -n env PATH="$failcp:/usr/bin:/bin" ORP_BENCH_TEST_HARNESS=1 ORP_ROOT="$pubroot" ORP_DB_PATH="$db" \
	ORP_OPERATING_MODE_FILE="$pubroot/etc/openrepeater/operating-mode" \
	ORP_BENCH_HOSTNAME_FILE="$pubroot/etc/hostname" \
	ORP_TEST_TMPDIR="${ORP_TEST_TMPDIR:-}" TMPDIR="${TMPDIR:-}" \
	"$HELPER" config publish 2>&1)
bad_cp_rc=$?
set -e
[ "$bad_cp_rc" -ne 0 ]
printf '%s\n' "$bad_cp" | grep -q 'Backup remains at '
kept_backup=$(printf '%s\n' "$bad_cp" | sed -n 's/.*Backup remains at \(.*\) companion .*/\1/p' | head -n 1)
kept_companion=$(printf '%s\n' "$bad_cp" | sed -n 's/.* companion //p' | head -n 1)
[ -n "$kept_backup" ] && [ -d "$kept_backup" ]
[ -n "$kept_companion" ] && [ -d "$kept_companion" ]
grep -q '^STALE$' "$kept_backup/ORP_RepeaterLogic_Port9.tcl"
[ "$(sha256sum "$pubroot/etc/svxlink/svxlink.conf")" = "$conf_before" ]
cmp -s "$tmp/courtesy-before.tcl" "$courtesy_path"
echo "ok: a failed restore keeps the functional-test backup"
echo "ok: a failed companion rollback restores the conf and courtesy and prints both kept paths"
ptt_sample="$tmp/ptt-sample"
for sample in ' PTT_TYPE=GPIO' 'PTT_TYPE = GPIO' 'PTT_TYPE="GPIO"'; do
	printf '%s\n' "$sample" > "$ptt_sample"
	if ORP_HELPER_SOURCE_ONLY=1 bash -c '. "$1"; ptt_lines_are "$2" NONE' _ "$HELPER" "$ptt_sample"; then
		echo "FAIL: shell treated [$sample] as disconnected" >&2
		exit 1
	fi
done
ptt_root="$tmp/ptt-root"
mkdir -p "$ptt_root/etc/svxlink/rtx.d"
printf '%s\n' ' PTT_TYPE=GPIO' > "$ptt_root/etc/svxlink/remotetrx.conf"
php -r '
require $argv[1] . "/includes/classes/BenchGuard.php";
putenv("ORP_BENCH_TEST_HARNESS=1");
putenv("ORP_ROOT=" . $argv[2]);
if (BenchGuard::harnessPathAllowed("//etc/hostname")) {
	fwrite(STDERR, "FAIL: harness path allowed //etc\n");
	exit(1);
}
if (BenchGuard::detect()->remotetrxPttDisconnected()) {
	fwrite(STDERR, "FAIL: PHP treated a spaced PTT_TYPE as disconnected\n");
	exit(1);
}
file_put_contents($argv[2] . "/etc/svxlink/remotetrx.conf", "PTT_TYPE = \"GPIO\"\nCFG_DIR=/etc/svxlink/rtx.d\n");
file_put_contents($argv[2] . "/etc/svxlink/rtx.d/extra.conf", "PTT_TYPE=\"GPIO\"\n");
if (BenchGuard::detect()->remotetrxPttDisconnected()) {
	fwrite(STDERR, "FAIL: PHP ignored a quoted PTT_TYPE under CFG_DIR\n");
	exit(1);
}
echo "ok: PTT_TYPE whitespace and quotes are real wiring\n";
' "$ROOT_DIR" "$ptt_root"
cfg_root="$tmp/cfg-root"
mkdir -p "$cfg_root/etc/openrepeater" "$cfg_root/etc/svxlink/remotetrx.d" "$cfg_root/etc/svxlink/functional-test.d"
printf 'orp-test\n' > "$cfg_root/etc/hostname"
printf 'functional-test\n' > "$cfg_root/etc/openrepeater/operating-mode"
chmod 644 "$cfg_root/etc/openrepeater/operating-mode"
sudo chown 0:0 "$cfg_root/etc/openrepeater" "$cfg_root/etc/openrepeater/operating-mode"
sudo chmod 755 "$cfg_root/etc/openrepeater"
printf '%s\n' 'PTT_TYPE=NONE' 'CFG_DIR=remotetrx.d' > "$cfg_root/etc/svxlink/remotetrx.conf"
printf 'PTT_TYPE=GPIO\n' > "$cfg_root/etc/svxlink/remotetrx.d/radio.conf"
ctl_cfg="$tmp/cfg-systemctl"
printf '%s\n' '#!/bin/bash' 'printf "%s\n" "$*" >> "${ORP_SYSTEMCTL_LOG:?}"' 'exit 0' > "$ctl_cfg"
chmod 755 "$ctl_cfg"
: > "$tmp/cfg-systemctl.log"
nopy="$tmp/nopy"
mkdir -p "$nopy"
for bin in /usr/bin/* /bin/*; do
	base=$(basename "$bin")
	case "$base" in
		python|python3|python3.*) continue ;;
	esac
	ln -s "$bin" "$nopy/$base" 2>/dev/null || true
done
if PATH="$nopy" command -v python3 >/dev/null 2>&1; then
	echo "FAIL: python3 was still on PATH" >&2
	exit 1
fi
py_pub=$(PATH="$nopy" ORP_BENCH_TEST_HARNESS=1 ORP_ROOT="$pubroot" ORP_DB_PATH="$db" \
	ORP_OPERATING_MODE_FILE="$pubroot/etc/openrepeater/operating-mode" \
	ORP_BENCH_HOSTNAME_FILE="$pubroot/etc/hostname" \
	"$HELPER" config publish 2>&1 || true)
printf '%s\n' "$py_pub" | grep -q 'refused: python3 is required (installer and orp_helper)'
joined=$(PATH="$nopy" ORP_HELPER_SOURCE_ONLY=1 bash -c '. "$1"; resolve_cfg_dir remotetrx.d "$2"' _ "$HELPER" "$cfg_root/etc/svxlink/remotetrx.conf")
[ "$joined" = "$cfg_root/etc/svxlink/remotetrx.d" ]
set +e
cfg_out=$(cd / && PATH="$nopy" ORP_BENCH_TEST_HARNESS=1 ORP_ROOT="$cfg_root" ORP_SYSTEMCTL="$ctl_cfg" \
	ORP_SYSTEMCTL_LOG="$tmp/cfg-systemctl.log" "$HELPER" remotetrx start 2>&1)
cfg_rc=$?
set -e
[ "$cfg_rc" -ne 0 ]
printf '%s\n' "$cfg_out" | grep -q 'CFG_DIR'
if grep -q 'start remotetrx.service' "$tmp/cfg-systemctl.log"; then
	echo "FAIL: relative CFG_DIR was resolved from cwd /" >&2
	exit 1
fi
printf '%s\n' 'PTT_TYPE=NONE' 'CFG_DIR=functional-test.d' > "$cfg_root/etc/svxlink/svxlink.conf"
printf 'PTT_TYPE=GPIO\n' > "$cfg_root/etc/svxlink/functional-test.d/radio.conf"
set +e
svx_cfg=$(cd / && ORP_BENCH_TEST_HARNESS=1 ORP_ROOT="$cfg_root" ORP_SYSTEMCTL="$ctl_cfg" \
	ORP_SYSTEMCTL_LOG="$tmp/cfg-systemctl.log" "$HELPER" svxlink start 2>&1)
svx_cfg_rc=$?
set -e
[ "$svx_cfg_rc" -ne 0 ]
printf '%s\n' "$svx_cfg" | grep -q 'CFG_DIR is not empty'
printf '%s\n' 'PTT_TYPE=NONE' 'CFG_DIR=empty.d' 'CFG_DIR=remotetrx.d' > "$cfg_root/etc/svxlink/remotetrx.conf"
mkdir -p "$cfg_root/etc/svxlink/empty.d"
set +e
multi=$(cd / && ORP_BENCH_TEST_HARNESS=1 ORP_ROOT="$cfg_root" "$HELPER" remotetrx start 2>&1)
multi_rc=$?
set -e
[ "$multi_rc" -ne 0 ]
printf '%s\n' "$multi" | grep -q 'more than once'
printf '%s\n' 'PTT_TYPE=NONE' 'CFG_DIR=remotetrx.d' > "$cfg_root/etc/svxlink/remotetrx.conf"
php -r '
require $argv[1] . "/includes/classes/BenchGuard.php";
putenv("ORP_BENCH_TEST_HARNESS=1");
putenv("ORP_ROOT=" . $argv[2]);
if (BenchGuard::detect()->remotetrxPttDisconnected()) {
	fwrite(STDERR, "FAIL: PHP resolved a relative CFG_DIR from the wrong directory\n");
	exit(1);
}
echo "ok: a relative CFG_DIR is resolved beside the conf file\n";
' "$ROOT_DIR" "$cfg_root"
echo "functional-test lift checks passed"
