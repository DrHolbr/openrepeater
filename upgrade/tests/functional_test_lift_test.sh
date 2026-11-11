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

actions='
svxlink start
svxlink restart
svxlink gpio_up
svxlink gpio_down
svxlink unmask
system restart
system stop
remotetrx start
remotetrx enable
remotetrx unmask
svxreflector start
svxreflector enable
svxreflector unmask
alsa backup
set_mixer set_mixer
'

php -r '
require $argv[1] . "/includes/classes/BenchGuard.php";
require $argv[1] . "/includes/classes/RequestGuard.php";
function fail($msg) { fwrite(STDERR, "FAIL: {$msg}\n"); exit(1); }
$actions = array(
	array("svxlink", "start"),
	array("svxlink", "restart"),
	array("svxlink", "gpio_up"),
	array("svxlink", "gpio_down"),
	array("svxlink", "unmask"),
	array("system", "restart"),
	array("system", "stop"),
	array("remotetrx", "start"),
	array("remotetrx", "enable"),
	array("remotetrx", "unmask"),
	array("svxreflector", "start"),
	array("svxreflector", "enable"),
	array("svxreflector", "unmask"),
	array("alsa", "backup"),
	array("set_mixer", "set_mixer"),
);
putenv("ORP_BENCH_TEST_HARNESS=1");
putenv("ORP_BENCH_HOSTNAME_FILE=" . $argv[2]);
putenv("ORP_OPERATING_MODE_FILE=" . $argv[3]);
putenv("ORP_BENCH_MARKER=" . $argv[4]);
$guard = BenchGuard::detect();
if ($guard->uiBlocksLifted() !== true) fail("trusted token did not lift UI blocks");
foreach ($actions as $pair) {
	if ($guard->commandAllowed($pair[0], $pair[1]) !== true) {
		fail("token refused {$pair[0]} {$pair[1]}");
	}
	if (RequestGuard::helperActionAllowed($pair[0], $pair[1]) !== true) {
		fail("helper allowlist refused {$pair[0]} {$pair[1]} with the token");
	}
}
putenv("ORP_OPERATING_MODE_FILE=" . $argv[5]);
file_put_contents($argv[5], "bench\n");
chmod($argv[5], 0644);
$blocked = BenchGuard::detect();
if ($blocked->uiBlocksLifted() !== false) fail("bench token lifted UI blocks");
foreach ($actions as $pair) {
	if ($blocked->commandAllowed($pair[0], $pair[1]) !== false) {
		fail("bench allowed {$pair[0]} {$pair[1]}");
	}
	if ($pair[0] === "svxlink" && ($pair[1] === "start" || $pair[1] === "restart")) {
		if (RequestGuard::helperActionAllowed($pair[0], $pair[1]) !== true) {
			fail("svxlink {$pair[1]} left the base allowlist");
		}
	} elseif (RequestGuard::helperActionAllowed($pair[0], $pair[1]) !== false) {
		fail("helper allowlist allowed {$pair[0]} {$pair[1]} without the token");
	}
}
echo "ok: each lifted action is allowed with the trusted token and refused without it\n";
' "$ROOT_DIR" "$host" "$mode" "$marker" "$tmp/bench-mode"

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
out=$(run_helper svxlink gpio_up)
printf '%s\n' "$out" | grep -q 'gpio-up'
out=$(run_helper svxlink gpio_down)
printf '%s\n' "$out" | grep -q 'gpio-down'
out=$(run_helper remotetrx unmask)
grep -q 'unmask remotetrx.service' "$log"
out=$(run_helper svxreflector start)
grep -q 'start svxreflector.service' "$log"
out=$(run_helper system restart)
printf '%s\n' "$out" | grep -q '^host-action-accepted system restart$'
out=$(run_helper system stop)
printf '%s\n' "$out" | grep -q '^host-action-accepted system stop$'
echo "ok: the helper runs start, GPIO, unmask, and host actions with the trusted token"

printf 'bench\n' > "$tmp/bench-only"
chmod 644 "$tmp/bench-only"
: > "$log"
set +e
ORP_BENCH_TEST_HARNESS=1 ORP_SYSTEMCTL="$ctl" ORP_SYSTEMCTL_LOG="$log" \
	ORP_OPERATING_MODE_FILE="$tmp/bench-only" ORP_BENCH_HOSTNAME_FILE="$host" ORP_BENCH_MARKER="$marker" \
	"$HELPER" svxlink gpio_up >"$tmp/gpio-off.out" 2>"$tmp/gpio-off.err"
gpio_rc=$?
ORP_BENCH_TEST_HARNESS=1 ORP_SYSTEMCTL="$ctl" ORP_SYSTEMCTL_LOG="$log" \
	ORP_OPERATING_MODE_FILE="$tmp/bench-only" ORP_BENCH_HOSTNAME_FILE="$host" ORP_BENCH_MARKER="$marker" \
	"$HELPER" svxlink unmask >"$tmp/unmask-off.out" 2>"$tmp/unmask-off.err"
unmask_rc=$?
ORP_BENCH_TEST_HARNESS=1 ORP_OPERATING_MODE_FILE="$tmp/bench-only" ORP_BENCH_HOSTNAME_FILE="$host" \
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
mkdir -p "$unmask_root/etc/openrepeater" "$unmask_root/etc/systemd/system"
printf 'orp-test\n' > "$unmask_root/etc/hostname"
printf 'functional-test\n' > "$unmask_root/etc/openrepeater/operating-mode"
chmod 644 "$unmask_root/etc/openrepeater/operating-mode"
sudo chown 0:0 "$unmask_root/etc/openrepeater/operating-mode"
for unit in svxlink.service remotetrx.service svxreflector.service; do
	ln -sfn /dev/null "$unmask_root/etc/systemd/system/$unit"
done
: > "$tmp/unmask.log"
(
	export ROOT="$unmask_root"
	export ORP_SYSTEMCTL="$ctl"
	export ORP_SYSTEMCTL_LOG="$tmp/unmask.log"
	# shellcheck source=../lib/bench-target.sh
	. "$ROOT_DIR/upgrade/lib/bench-target.sh"
	bench_unmask_radio_units
)
for unit in svxlink.service remotetrx.service svxreflector.service; do
	[ ! -L "$unmask_root/etc/systemd/system/$unit" ]
	grep -q "unmask ${unit}" "$tmp/unmask.log"
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
echo "ok: a trusted token unmasks the radio units and a bench token does not"
echo "functional-test lift checks passed"
