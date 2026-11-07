#!/bin/bash
# Publish a no-PTT config for the source-install layout.
# This does not execute the distro svxlink binary. The Pi binary is not here.
set -euo pipefail

ROOT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
# shellcheck source=lib/native_layout.sh
. "$ROOT_DIR/upgrade/tests/lib/native_layout.sh"
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
plant_native_layout "$live"
chmod 755 "$live" "$live/etc" "$live/etc/svxlink" "$live/var" "$live/var/backups" "$live/var/backups/orp-ui"
printf 'ModuleEchoLink sample\n' > "$live/etc/svxlink/svxlink.d/ModuleEchoLink.conf"
printf 'orp-test\n' > "$host"
printf 'functional-test\n' > "$mode"
chmod 644 "$mode"
cp "$ROOT_DIR/install/sql/openrepeater.db" "$db"
php "$ROOT_DIR/upgrade/tests/functional_runtime_prepare.php" "$ROOT_DIR" "$db" "$host" "$tmp/no-marker" "$mode" "$preview" "$tmp/stored-tx"
apply_ident_profile "$db"
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
grep -q '^CALLSIGN=FIXTURE$' "$live/etc/svxlink/svxlink.conf"
grep -q '^SHORT_IDENT_INTERVAL=5$' "$live/etc/svxlink/svxlink.conf"
grep -q '^SHORT_CW_ID_ENABLE=1$' "$live/etc/svxlink/svxlink.conf"
grep -q '^SHORT_VOICE_ID_ENABLE=0$' "$live/etc/svxlink/svxlink.conf"
grep -q '^CW_WPM=20$' "$live/etc/svxlink/svxlink.conf"
grep -q '^CW_PITCH=600$' "$live/etc/svxlink/svxlink.conf"
grep -q '^MODULE_PATH=/usr/local/lib/svxlink$' "$live/etc/svxlink/svxlink.conf"
grep -q '^LOGIC_CORE_PATH=/usr/local/lib/svxlink$' "$live/etc/svxlink/svxlink.conf"
grep -q '^EVENT_HANDLER=/usr/local/share/svxlink/events.tcl$' "$live/etc/svxlink/svxlink.conf"
grep -q '^CFG_DIR=/etc/svxlink/functional-test.d$' "$live/etc/svxlink/svxlink.conf"
grep -q '^SQL_SIGLEV_OPEN_THRESH=30$' "$live/etc/svxlink/svxlink.conf"
grep -q '^SQL_SIGLEV_CLOSE_THRESH=10$' "$live/etc/svxlink/svxlink.conf"
if grep -q '^SIGLEV_OPEN_THRESH=\|^SIGLEV_CLOSE_THRESH=' "$live/etc/svxlink/svxlink.conf"; then
	echo "FAIL: published config still uses the deprecated SIGLEV threshold keys" >&2
	exit 1
fi
if grep -q 'ModuleEchoLink\|/usr/lib/\|/usr/share/svxlink' "$live/etc/svxlink/svxlink.conf"; then
	echo "FAIL: published config followed distro paths or svxlink.d" >&2
	exit 1
fi
if [ -n "$(find "$live/etc/svxlink/functional-test.d" -mindepth 1 -print)" ]; then
	echo "FAIL: functional-test.d is not empty" >&2
	exit 1
fi
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

echo "ok: published bytes name the source-install paths and leave svxlink.d unloaded"
echo "functional runtime checks passed"
