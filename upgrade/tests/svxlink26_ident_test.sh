#!/bin/bash
# Stored identification values are copied by the root renderer, then the
# pinned SvxLink 26.05 procedures are executed. No radio is started.
set -euo pipefail

ROOT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
# shellcheck source=lib/native_layout.sh
. "$ROOT_DIR/upgrade/tests/lib/native_layout.sh"
fixture="$ROOT_DIR/upgrade/tests/fixtures/svxlink-26.05"
python3 - <<PY
import hashlib, pathlib, sys
root = pathlib.Path("$fixture")
pins = {
    "Logic.tcl": "2de34e66bee46e15a64b8d43f90d0a9aebd9a642c94ab67aae00df4d217dac4f",
    "RepeaterLogicType.tcl": "2113bffea43cf43f06c13d8160ddc432bc3835334c8f263dd6e830364c8577a5",
    "CW.tcl": "d18efb4ef08d31efbbdba3f4df95ebd4061621d6b544ed77f334ad1a1726cce7",
}
for name, pin in pins.items():
    digest = hashlib.sha256((root / name).read_bytes()).hexdigest()
    if digest != pin:
        sys.exit(f"FAIL: {name} digest {digest} is not the 26.05 pin")
print("ok: pinned 26.05 Logic.tcl, RepeaterLogicType.tcl, and CW.tcl")
PY
tclsh "$ROOT_DIR/upgrade/tests/svxlink26_ident_test.tcl" "$fixture"

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
live="$tmp/live"
db="$tmp/openrepeater.db"
host="$tmp/hostname"
mode="$tmp/mode"
mkdir -p "$live/etc/svxlink" "$live/var/backups/orp-ui"
plant_native_layout "$live"
chmod 755 "$live" "$live/etc" "$live/etc/svxlink" "$live/var" "$live/var/backups" "$live/var/backups/orp-ui"
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

sounds="$ROOT_DIR/upgrade/install-svxlink-sounds.sh"
canary="$tmp/sounds-canary"
mkdir -p "$canary"
printf 'KEEP\n' > "$canary/keep.txt"
set +e
unverified=$(ORP_SOUNDS_TEST_HARNESS=1 ORP_ROOT="$tmp/sounds-root" "$sounds" "$ROOT_DIR/upgrade/share/heather-16k-25.05.sha256" 2>&1)
unverified_rc=$?
set -e
[ "$unverified_rc" -eq 2 ]
printf '%s\n' "$unverified" | grep -q 'digest is not pinned'
[ "$(cat "$canary/keep.txt")" = "KEEP" ]
ln -s "$ROOT_DIR/upgrade/share/heather-16k-25.05.sha256" "$tmp/archive-link"
set +e
linked=$(ORP_SOUNDS_TEST_HARNESS=1 "$sounds" "$tmp/archive-link" 2>&1)
linked_rc=$?
set -e
[ "$linked_rc" -eq 2 ]
printf '%s\n' "$linked" | grep -q 'not a regular file'
python3 - <<PY
import hashlib, tarfile, pathlib
root = pathlib.Path("$tmp")
payload = root / "payload"
(payload / "en_US").mkdir(parents=True)
(payload / "en_US" / "clip.txt").write_text("clip\n")
archive = root / "bad.tar.bz2"
with tarfile.open(archive, "w:bz2") as tar:
    tar.add(payload / "en_US" / "clip.txt", arcname="en_US/clip.txt")
    tar.add(payload / "en_US" / "clip.txt", arcname="../escape.txt")
digest = hashlib.sha256(archive.read_bytes()).hexdigest()
(root / "pin").write_text(digest + "\n")
PY
set +e
escaped=$(ORP_SOUNDS_TEST_HARNESS=1 ORP_SOUNDS_PIN="$tmp/pin" ORP_ROOT="$tmp/sounds-root" "$sounds" "$tmp/bad.tar.bz2" 2>&1)
escaped_rc=$?
set -e
[ "$escaped_rc" -eq 2 ]
printf '%s\n' "$escaped" | grep -q 'escapes en_US'
if [ -e "$tmp/sounds-root/usr/local/share/svxlink/sounds/en_US" ]; then
	echo "FAIL: escaped archive was installed" >&2
	exit 1
fi
echo "ok: sound installation refuses an unpinned archive, a symlink, and a path escape"
echo "stored identification runtime checks passed"
