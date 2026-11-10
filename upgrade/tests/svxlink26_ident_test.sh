#!/bin/bash
# Stored identification values are copied by the root renderer, then the
# pinned SvxLink 26.05 procedures are executed. No radio is started.
set -euo pipefail

ROOT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
# shellcheck source=lib/fixture_tmpdir.sh
. "$ROOT_DIR/upgrade/tests/lib/fixture_tmpdir.sh"
# shellcheck source=lib/native_layout.sh
. "$ROOT_DIR/upgrade/tests/lib/native_layout.sh"
orp_use_fixture_tmpdir
fixture="$ROOT_DIR/upgrade/tests/fixtures/svxlink-26.05"
python3 - <<PY
import hashlib, pathlib, sys
root = pathlib.Path("$fixture")
pins = {
    "Logic.tcl": "2de34e66bee46e15a64b8d43f90d0a9aebd9a642c94ab67aae00df4d217dac4f",
    "LogicBase.tcl": "2840ccfa28ddfc12ceeee533e8c5d069097ae26e772a63fd2dc51f10166d380f",
    "locale.tcl": "01f54727222129ee2e212aa3e698aa75cac94dcaf05773147e2c6cda8b8a874a",
    "RepeaterLogicType.tcl": "2113bffea43cf43f06c13d8160ddc432bc3835334c8f263dd6e830364c8577a5",
    "CW.tcl": "d18efb4ef08d31efbbdba3f4df95ebd4061621d6b544ed77f334ad1a1726cce7",
    "squelch_timeout.tcl": "71e33b2c5685b9ce69ae0bfd04fb7d7bd0fad2b3256f6ab547e1228d6462ddc0",
}
for name, pin in pins.items():
    digest = hashlib.sha256((root / name).read_bytes()).hexdigest()
    if digest != pin:
        sys.exit(f"FAIL: {name} digest {digest} is not the 26.05 pin")
print("ok: pinned 26.05 Logic.tcl, LogicBase.tcl, locale.tcl, RepeaterLogicType.tcl, and CW.tcl")
PY
tclsh "$ROOT_DIR/upgrade/tests/svxlink26_ident_test.tcl" "$fixture"

tmp=$(orp_mktemp_dir)
trap 'orp_cleanup_fixture "$tmp"' EXIT
live="$tmp/live"
db="$tmp/openrepeater.db"
host="$tmp/hostname"
mode="$tmp/mode"
orp_mkdir "$live" "$live/etc/svxlink" "$live/var/backups/orp-ui"
plant_native_layout "$live"
chmod 755 "$live" "$live/etc" "$live/etc/svxlink" "$live/var" "$live/var/backups" "$live/var/backups/orp-ui"
printf 'orp-test\n' > "$host"
printf 'functional-test\n' > "$mode"
orp_private "$mode"
chmod 644 "$mode"
cp "$ROOT_DIR/install/sql/openrepeater.db" "$db"
sqlite3 "$db" "UPDATE settings SET value='FIXTURE' WHERE keyID='callSign';"
apply_ident_profile "$db"
sqlite3 "$db" "UPDATE settings SET value='repeater' WHERE keyID='orp_Mode';"
export ORP_BENCH_TEST_HARNESS=1
export ORP_BENCH_HOSTNAME_FILE="$host"
export ORP_OPERATING_MODE_FILE="$mode"
export ORP_BENCH_MARKER="$tmp/no-marker"
export ORP_DB_PATH="$db"
export ORP_ROOT="$live"
"$ROOT_DIR/install/scripts/orp_helper" config publish >/dev/null
cfg="$live/etc/svxlink/svxlink.conf"
grep -q '^CALLSIGN=FIXTURE$' "$cfg"
grep -q '^SHORT_IDENT_INTERVAL=5$' "$cfg"
grep -q '^LONG_IDENT_INTERVAL=0$' "$cfg"
grep -q '^IDENT_ONLY_AFTER_TX=0$' "$cfg"
grep -q '^SHORT_CW_ID_ENABLE=1$' "$cfg"
grep -q '^SHORT_VOICE_ID_ENABLE=0$' "$cfg"
grep -q '^CW_WPM=20$' "$cfg"
grep -q '^CW_PITCH=600$' "$cfg"
grep -q '^LOGICS=RepeaterLogic$' "$cfg"
grep -q '^TYPE=Repeater$' "$cfg"
grep -q '^PTT_TYPE=NONE$' "$cfg"
if grep -q '^ID_Morse_Amplitude=\|^CW_AMP=' "$cfg"; then
	echo "FAIL: stored Morse amplitude was copied into the runtime" >&2
	exit 1
fi
ident=$("$ROOT_DIR/install/scripts/orp_helper" config ident)
printf '%s\n' "$ident" | grep -q '^CALLSIGN=FIXTURE$'
printf '%s\n' "$ident" | grep -q '^SHORT_IDENT_INTERVAL=5$'
echo "ok: root renderer copied the stored call sign, 5 minute interval, and 20 WPM"

# Voice with a stored 25 WPM speed does not publish that speed.
sqlite3 "$db" "UPDATE settings SET value='voice' WHERE keyID='ID_Short_Mode';"
sqlite3 "$db" "UPDATE settings SET value='25' WHERE keyID='ID_Morse_WPM';"
"$ROOT_DIR/install/scripts/orp_helper" config publish >/dev/null
grep -q '^SHORT_VOICE_ID_ENABLE=1$' "$cfg"
grep -q '^SHORT_CW_ID_ENABLE=0$' "$cfg"
if grep -q '^CW_WPM=' "$cfg"; then
	echo "FAIL: voice identification published a Morse speed" >&2
	exit 1
fi
[ "$(sqlite3 "$db" "SELECT value FROM settings WHERE keyID='ID_Morse_WPM';")" = "25" ]
echo "ok: voice identification leaves the stored 25 WPM unused and unchanged"
echo "stored identification runtime checks passed"
