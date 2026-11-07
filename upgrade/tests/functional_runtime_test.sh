#!/bin/bash
# Publish a no-PTT SvxLink config and load it with the svxlink process.
# The cloud binary is not the Pi 26.05.2 build. GPIOD is not used.
set -euo pipefail

ROOT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
if [ ! -x /usr/bin/svxlink ]; then
	echo "FAIL: /usr/bin/svxlink is not installed; the process test cannot run" >&2
	exit 1
fi
tmp=$(mktemp -d)
preview=$(mktemp -d /tmp/orp-preview-runtime.XXXXXX)
trap 'rm -rf "$tmp" "$preview"' EXIT
live="$tmp/live"
db="$tmp/openrepeater.db"
host="$tmp/hostname"
mode="$tmp/operating-mode"
log="$tmp/svx.log"
pid="$tmp/svx.pid"
mkdir -p "$live/etc/svxlink/svxlink.d" "$live/var/backups/orp-ui"
printf 'orp-test\n' > "$host"
printf 'functional-test\n' > "$mode"
chmod 644 "$mode"
cp "$ROOT_DIR/install/sql/openrepeater.db" "$db"
php "$ROOT_DIR/upgrade/tests/functional_runtime_prepare.php" "$ROOT_DIR" "$db" "$host" "$tmp/no-marker" "$mode" "$preview" "$tmp/stored-tx"
before=$(sha256sum "$db" | awk '{print $1}')

export ORP_BENCH_TEST_HARNESS=1
export ORP_BENCH_HOSTNAME_FILE="$host"
export ORP_BENCH_MARKER="$tmp/no-marker"
export ORP_OPERATING_MODE_FILE="$mode"
export ORP_BENCH_PREVIEW="$preview"
export ORP_SVXLINK_PREFIX=/usr
export ORP_DB_PATH="$db"
export ORP_FLAG_STORE=sqlite

export ORP_ROOT="$live"
export ORP_STAGED_CONFIG="$preview/svxlink.conf"
printf 'PTT_PIN=gpio498\nEVENT_HANDLER=/tmp/attacker.tcl\nAUDIO_DEV=udp:10.1.1.1:9\n' > "$preview/svxlink.conf"
set +e
pub=$("$ROOT_DIR/install/scripts/orp_helper" config publish 2>&1)
pub_rc=$?
set -e
if [ "$pub_rc" -ne 0 ]; then
	echo "FAIL: config publish rc=$pub_rc" >&2
	printf '%s\n' "$pub" >&2
	exit 1
fi
printf '%s\n' "$pub" | grep -q 'published'
printf '%s\n' "$pub" | grep -q 'simulation/dummy-path'
grep -q '^PTT_TYPE=NONE$' "$live/etc/svxlink/svxlink.conf"
if grep -E -q '^[^#].*(PTT_PIN|GPIO_)' "$live/etc/svxlink/svxlink.conf"; then
	echo "FAIL: published config contains GPIO or PTT" >&2
	exit 1
fi
after=$(sha256sum "$db" | awk '{print $1}')
if [ "$before" != "$after" ]; then
	echo "FAIL: publishing changed the database" >&2
	exit 1
fi
stored=$(cat "$tmp/stored-tx")
now=$(php -r 'echo (new SQLite3($argv[1]))->querySingle("SELECT txGPIO FROM ports");' "$db")
if [ "$now" != "$stored" ]; then
	echo "FAIL: stored TX wiring changed" >&2
	exit 1
fi

timeout 4 /usr/bin/svxlink --config="$live/etc/svxlink/svxlink.conf" --logfile="$log" --pidfile="$pid" || true
grep -q 'Event handler script successfully loaded' "$log"
grep -q 'Shutting down application' "$log"
if grep -E -q 'GPIO|PTT_PIN|gpio498' "$log"; then
	echo "FAIL: svxlink log shows GPIO or PTT activity" >&2
	cat "$log" >&2
	exit 1
fi
if [ -f "$pid" ] && kill -0 "$(cat "$pid")" 2>/dev/null; then
	echo "FAIL: svxlink still running after shutdown" >&2
	kill "$(cat "$pid")" || true
	exit 1
fi
echo "ok: svxlink process loaded the no-PTT config and shut down"
echo "functional runtime checks passed"
