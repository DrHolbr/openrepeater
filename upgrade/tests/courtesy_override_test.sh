#!/bin/bash
# Disabled and beep are applied as a root-owned local Logic.tcl override.
# The pinned 26.05 Logic.tcl is sourced with that override. No radio starts.
set -euo pipefail

ROOT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
# shellcheck source=lib/fixture_tmpdir.sh
. "$ROOT_DIR/upgrade/tests/lib/fixture_tmpdir.sh"
# shellcheck source=lib/native_layout.sh
. "$ROOT_DIR/upgrade/tests/lib/native_layout.sh"
orp_use_fixture_tmpdir
fixture="$ROOT_DIR/upgrade/tests/fixtures/svxlink-26.05"
helper="$ROOT_DIR/install/scripts/orp_helper"
tcl="$ROOT_DIR/upgrade/tests/courtesy_override_test.tcl"

tmp=$(orp_mktemp_dir)
trap 'rm -rf "$tmp"' EXIT
live="$tmp/live"
db="$tmp/openrepeater.db"
host="$tmp/hostname"
mode="$tmp/operating-mode"
base="$tmp/svx"
mkdir -p "$live/etc/svxlink" "$live/var/backups/orp-ui" "$base/events.d/local"
plant_native_layout "$live"
chmod 755 "$live" "$live/etc" "$live/etc/svxlink" "$live/var" "$live/var/backups" "$live/var/backups/orp-ui"
for name in Logic.tcl LogicBase.tcl locale.tcl RepeaterLogicType.tcl CW.tcl squelch_timeout.tcl; do
	ln -s "$fixture/$name" "$base/events.d/$name"
done
printf 'orp-test\n' > "$host"
printf 'functional-test\n' > "$mode"
chmod 644 "$mode"
cp "$ROOT_DIR/install/sql/openrepeater.db" "$db"
sqlite3 "$db" "UPDATE settings SET value='FIXTURE' WHERE keyID='callSign';"
apply_ident_profile "$db"
export ORP_BENCH_TEST_HARNESS=1
export ORP_BENCH_HOSTNAME_FILE="$host"
export ORP_OPERATING_MODE_FILE="$mode"
export ORP_BENCH_MARKER="$tmp/no-marker"
export ORP_DB_PATH="$db"
export ORP_ROOT="$live"

tclsh "$tcl" "$base" default

publish() {
	"$helper" config publish
}

overlay() {
	rm -f "$base/events.d/local/Logic.tcl"
	if [ -f "$live/usr/local/share/svxlink/events.d/local/Logic.tcl" ]; then
		cp -p "$live/usr/local/share/svxlink/events.d/local/Logic.tcl" "$base/events.d/local/Logic.tcl"
	fi
}

pub=$(publish)
printf '%s\n' "$pub" | grep -q '^courtesy=applied$'
printf '%s\n' "$pub" | grep -q '^courtesy_mode=beep$'
printf '%s\n' "$pub" | grep -q '^courtesy_executed=not-run$'
printf '%s\n' "$pub" | grep -q '^PTT_TYPE=NONE$' || grep -q '^PTT_TYPE=NONE$' "$live/etc/svxlink/svxlink.conf"
grep -q '^RGR_SOUND_DELAY=0$' "$live/etc/svxlink/svxlink.conf"
grep -q '^PTT_TYPE=NONE$' "$live/etc/svxlink/svxlink.conf"
override="$live/usr/local/share/svxlink/events.d/local/Logic.tcl"
[ -f "$override" ] && [ ! -L "$override" ]
[ "$(stat -c %a "$override")" = "644" ]
grep -q 'playTone 660 500 200' "$override"
if grep -E -q 'playFile|source |exec ' "$override"; then
	echo "FAIL: beep override contains a path or a command" >&2
	exit 1
fi
overlay
tclsh "$tcl" "$base" beep
echo "ok: beep is stored in the stock database and applied as the local override"

sqlite3 "$db" "UPDATE settings SET value='disabled' WHERE keyID='courtesyMode';"
pub=$(publish)
printf '%s\n' "$pub" | grep -q '^courtesy_mode=disabled$'
grep -q 'playSilence 100' "$override"
if grep -q 'playTone' "$override"; then
	echo "FAIL: disabled override still plays a tone" >&2
	exit 1
fi
overlay
tclsh "$tcl" "$base" disabled
echo "ok: disabled is applied as silence and does not play a tone"

conf_sum=$(sha256sum "$live/etc/svxlink/svxlink.conf" | awk '{print $1}')
tcl_sum=$(sha256sum "$override" | awk '{print $1}')
sqlite3 "$db" "UPDATE settings SET value='custom' WHERE keyID='courtesyMode';"
set +e
pub=$(publish 2>"$tmp/custom.err")
rc=$?
set -e
[ "$rc" -ne 0 ]
grep -q 'previous runtime was not changed' "$tmp/custom.err"
[ "$(sha256sum "$live/etc/svxlink/svxlink.conf" | awk '{print $1}')" = "$conf_sum" ]
[ "$(sha256sum "$override" | awk '{print $1}')" = "$tcl_sum" ]
echo "ok: custom courtesy is stored and leaves the applied override unchanged"

sqlite3 "$db" "UPDATE settings SET value='nope' WHERE keyID='courtesyMode';"
set +e
pub=$(publish 2>"$tmp/bad.err")
rc=$?
set -e
[ "$rc" -ne 0 ]
grep -q 'not disabled or beep' "$tmp/bad.err"
[ "$(sha256sum "$live/etc/svxlink/svxlink.conf" | awk '{print $1}')" = "$conf_sum" ]
[ "$(sha256sum "$override" | awk '{print $1}')" = "$tcl_sum" ]
echo "ok: an invalid courtesy mode leaves the applied override unchanged"

printf 'SECRET\n' > "$tmp/canary"
chmod 600 "$tmp/canary"
rm -f "$override"
ln -s "$tmp/canary" "$override"
sqlite3 "$db" "UPDATE settings SET value='beep' WHERE keyID='courtesyMode';"
set +e
pub=$(publish 2>"$tmp/link.err")
rc=$?
set -e
[ "$rc" -ne 0 ]
[ -L "$override" ]
[ "$(cat "$tmp/canary")" = "SECRET" ]
[ "$(stat -c %a "$tmp/canary")" = "600" ]
[ "$(sha256sum "$live/etc/svxlink/svxlink.conf" | awk '{print $1}')" = "$conf_sum" ]
echo "ok: a symlinked courtesy override is not followed"
echo "courtesy override checks passed"
