#!/bin/bash
# A failed armed publish removes the orp-companions directory it created.
set -euo pipefail

ROOT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
# shellcheck source=lib/fixture_tmpdir.sh
. "$ROOT_DIR/upgrade/tests/lib/fixture_tmpdir.sh"
# shellcheck source=lib/native_layout.sh
. "$ROOT_DIR/upgrade/tests/lib/native_layout.sh"
orp_use_fixture_tmpdir
tmp=$(orp_mktemp_dir)
scratch="$tmp/scratch"
trap 'sudo -n chown -R "$(id -u):$(id -g)" "$tmp" 2>/dev/null || true; orp_cleanup_fixture "$tmp"' EXIT
mkdir -m 755 "$scratch"

live="$tmp/live"
db="$tmp/openrepeater.db"
host="$tmp/hostname"
mode="$tmp/operating-mode"
armed="$tmp/tx-armed"
preview="$live/var/lib/openrepeater/bench-preview"
orp_mkdir "$live" "$live/etc/svxlink" "$live/etc/openrepeater" "$live/var/backups/orp-ui" \
	"$preview" "$live/var/lib/openrepeater/db"
plant_native_layout "$live"
chmod 755 "$tmp" "$live" "$live/etc" "$live/etc/svxlink" "$live/etc/openrepeater" \
	"$live/var" "$live/var/lib" "$live/var/lib/openrepeater" "$live/var/lib/openrepeater/db" \
	"$preview" "$live/var/backups" "$live/var/backups/orp-ui"
printf 'orp-test\n' > "$host"
printf 'functional-test\n' > "$mode"
printf 'armed\n' > "$armed"
sudo -n chown 0:0 "$mode" "$armed" "$live/etc/openrepeater"
sudo -n chmod 755 "$live/etc/openrepeater"
sudo -n chmod 644 "$mode" "$armed"
sudo -n chown -R root:root "$live/usr/local/share/svxlink" "$live/usr/local/lib/svxlink"
orp_copy_writable "$ROOT_DIR/install/sql/openrepeater.db" "$db"
sqlite3 "$db" "UPDATE settings SET value='FIXTURE' WHERE keyID='callSign';"
sqlite3 "$db" "UPDATE settings SET value='nope' WHERE keyID='courtesyMode';"
apply_ident_profile "$db"
printf '%s\n' '[GLOBAL]' 'LOGICS=RepeaterLogic' '[Tx1]' 'PTT_TYPE=GPIO' 'PTT_PIN=gpio26' > "$preview/svxlink.conf"
printf 'GPIO_OUT_HIGH="gpio498"\n' > "$preview/gpio.conf"
chmod 644 "$preview/svxlink.conf" "$preview/gpio.conf"
printf 'CANARY\n' > "$live/etc/svxlink/svxlink.conf"
chmod 644 "$live/etc/svxlink/svxlink.conf"

before=$(find "$scratch" -maxdepth 1 -type d -name 'orp-companions.*' | wc -l)
set +e
out=$(sudo -n env ORP_BENCH_TEST_HARNESS=1 ORP_ROOT="$live" ORP_DB_PATH="$db" \
	ORP_BENCH_HOSTNAME_FILE="$host" ORP_OPERATING_MODE_FILE="$mode" \
	ORP_TX_ARMED_FILE="$armed" ORP_BENCH_MARKER="$tmp/no-marker" \
	TMPDIR="$scratch" \
	"$ROOT_DIR/install/scripts/orp_helper" config publish 2>&1)
rc=$?
set -e
after=$(find "$scratch" -maxdepth 1 -type d -name 'orp-companions.*' | wc -l)
if [ "$rc" -eq 0 ]; then
	echo "FAIL: invalid courtesy was published" >&2
	printf '%s\n' "$out" >&2
	exit 1
fi
printf '%s\n' "$out" | grep -q 'not disabled or beep'
[ "$(cat "$live/etc/svxlink/svxlink.conf")" = "CANARY" ]
[ "$before" = "0" ]
[ "$after" = "0" ]
echo "ok: a failed armed publish removes the orp-companions directory"
echo "companion cleanup checks passed"
