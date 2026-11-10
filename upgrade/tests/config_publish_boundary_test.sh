#!/bin/bash
# The privileged publisher ignores web staging. Invalid input does not
# replace a live canary and does not start svxlink.
set -euo pipefail

ROOT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
# shellcheck source=lib/fixture_tmpdir.sh
. "$ROOT_DIR/upgrade/tests/lib/fixture_tmpdir.sh"
# shellcheck source=lib/native_layout.sh
. "$ROOT_DIR/upgrade/tests/lib/native_layout.sh"
orp_use_fixture_tmpdir
tmp=$(orp_mktemp_dir)
trap 'orp_cleanup_fixture "$tmp"' EXIT
live="$tmp/live"
db="$tmp/openrepeater.db"
host="$tmp/hostname"
mode="$tmp/mode"
stage="$tmp/staged.conf"
ctl="$tmp/systemctl"
log="$tmp/systemctl.log"
orp_mkdir "$live" "$live/etc/svxlink" "$live/var/lib/openrepeater/db" "$live/var/backups/orp-ui"
plant_native_layout "$live"
chmod 755 "$live" "$live/etc" "$live/etc/svxlink" "$live/var" "$live/var/lib" "$live/var/lib/openrepeater" "$live/var/lib/openrepeater/db" "$live/var/backups" "$live/var/backups/orp-ui"
printf 'orp-test\n' > "$host"
printf 'functional-test\n' > "$mode"
orp_private "$mode"
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
export ORP_STAGED_CONFIG="$stage"
export ORP_SYSTEMCTL="$ctl"
export ORP_SYSTEMCTL_LOG="$log"
cat > "$ctl" <<'EOF'
#!/bin/bash
printf '%s\n' "$*" >> "${ORP_SYSTEMCTL_LOG:?}"
exit 0
EOF
chmod 755 "$ctl"
: > "$log"

cat > "$stage" <<'EOF'
# /share/svxlink/events.tcl
[Tx1]
PTT_TYPE=NONE
[Tx2]
PTT_TYPE=GPIO
PTT_PIN=gpio498
AUDIO_DEV=udp:192.168.155.216:17001
EVENT_HANDLER=/tmp/attacker.tcl
INCLUDE=http://example.invalid/svxlink.conf
EOF

dest="$live/etc/svxlink/svxlink.conf"
printf 'CANARY\n' > "$dest"
chmod 600 "$dest"
owner_before=$(stat -c '%u:%g:%a' "$dest")
sum_before=$(sha256sum "$dest" | awk '{print $1}')

sqlite3 "$db" "UPDATE settings SET value = 'BAD' || char(10) || 'PTT_PIN=gpio498' WHERE keyID='callSign';"
set +e
bad=$("$ROOT_DIR/install/scripts/orp_helper" config publish 2>&1)
bad_rc=$?
set -e
[ "$bad_rc" -ne 0 ]
printf '%s\n' "$bad" | grep -q 'not a plain station token'
[ "$(cat "$dest")" = "CANARY" ]
[ "$(stat -c '%u:%g:%a' "$dest")" = "$owner_before" ]
[ "$(sha256sum "$dest" | awk '{print $1}')" = "$sum_before" ]
[ ! -s "$log" ]
echo "ok: invalid call sign leaves the live canary and does not start"

sqlite3 "$db" "UPDATE settings SET value='FIXTURE' WHERE keyID='callSign';"
# Keep rewriting the staged file while publish runs.
(
	i=0
	while [ "$i" -lt 200 ]; do
		printf 'PTT_PIN=gpio498\nPTT_TYPE=GPIO\nEVENT_HANDLER=/tmp/attacker.tcl\n' > "$stage"
		i=$((i + 1))
	done
) &
racer=$!
set +e
ok=$("$ROOT_DIR/install/scripts/orp_helper" config publish 2>&1)
ok_rc=$?
set -e
wait "$racer" || true
[ "$ok_rc" -eq 0 ]
printf '%s\n' "$ok" | grep -q 'service was not started'
if grep -q 'gpio498\|192.168.155.216\|attacker.tcl\|INCLUDE=' "$dest"; then
	echo "FAIL: published file followed the staged config" >&2
	cat "$dest" >&2
	exit 1
fi
grep -q '^PTT_TYPE=NONE$' "$dest"
grep -q '^AUDIO_DEV=udp:127.0.0.1:17001$' "$dest"
grep -q '^AUDIO_DEV=udp:127.0.0.1:17002$' "$dest"
grep -q '^EVENT_HANDLER=/usr/local/share/svxlink/events.tcl$' "$dest"
grep -q '^CALLSIGN=FIXTURE$' "$dest"
grep -q '^SHORT_IDENT_INTERVAL=5$' "$dest"
grep -q '^CW_WPM=20$' "$dest"
grep -q '^SHORT_CW_ID_ENABLE=1$' "$dest"
[ "$(grep -c '^\[Tx' "$dest")" -eq 1 ]
grep -q '^MODULE_PATH=/usr/local/lib/svxlink$' "$dest"
[ ! -s "$log" ]
unit_dir="$live/usr/local/lib/systemd/system"
orp_mkdir "$unit_dir"
"$ROOT_DIR/install/scripts/orp_helper" native unit > "$unit_dir/svxlink.service"
chmod 644 "$unit_dir/svxlink.service"
orp_mkdir "$live/var/lib/svxlink" "$live/var/spool/svxlink"
: > "$live/var/log/svxlink"
chmod 755 "$live/var/lib/svxlink" "$live/var/spool/svxlink"
chmod 644 "$live/var/log/svxlink"
set +e
masked=$("$ROOT_DIR/install/scripts/orp_helper" svxlink start 2>&1)
masked_rc=$?
set -e
[ "$masked_rc" -ne 0 ]
printf '%s\n' "$masked" | grep -q 'Unmask was not performed'
[ ! -s "$log" ]
[ "$(readlink "$live/etc/systemd/system/svxlink.service")" = "/dev/null" ]
echo "ok: publisher ignored the mutable staged file, including a racing rewrite"
echo "ok: start does not unmask the administrative mask"

good_sum=$(sha256sum "$dest" | awk '{print $1}')
sqlite3 "$db" "UPDATE settings SET value='25' WHERE keyID='ID_Morse_WPM';"
set +e
fast=$("$ROOT_DIR/install/scripts/orp_helper" config publish 2>&1)
fast_rc=$?
set -e
[ "$fast_rc" -ne 0 ]
printf '%s\n' "$fast" | grep -q 'stored speed was not changed'
[ "$(sqlite3 "$db" "SELECT value FROM settings WHERE keyID='ID_Morse_WPM';")" = "25" ]
[ "$(sha256sum "$dest" | awk '{print $1}')" = "$good_sum" ]
sqlite3 "$db" "UPDATE settings SET value='20' WHERE keyID='ID_Morse_WPM';"
sqlite3 "$db" "UPDATE settings SET value='custom' WHERE keyID='ID_Long_Mode';"
set +e
custom=$("$ROOT_DIR/install/scripts/orp_helper" config publish 2>&1)
custom_rc=$?
set -e
[ "$custom_rc" -ne 0 ]
printf '%s\n' "$custom" | grep -q 'mode custom is not published'
[ "$(sqlite3 "$db" "SELECT value FROM settings WHERE keyID='ID_Long_Mode';")" = "custom" ]
[ "$(sha256sum "$dest" | awk '{print $1}')" = "$good_sum" ]
sqlite3 "$db" "UPDATE settings SET value='disabled' WHERE keyID='ID_Long_Mode';"
echo "ok: 25 WPM and a custom clip are not published and the stored rows stay put"

# Corrupt the installed bytes. Start must not run.
printf 'PTT_PIN=gpio498\n' >> "$dest"
: > "$log"
set +e
start=$("$ROOT_DIR/install/scripts/orp_helper" svxlink start 2>&1)
start_rc=$?
set -e
[ "$start_rc" -ne 0 ]
printf '%s\n' "$start" | grep -q 'Start was not called'
[ ! -s "$log" ]
echo "ok: start refuses a config that is not the snapshot"

# Symlink destination. The canary behind it stays put.
rm -f "$dest"
printf 'KEEP\n' > "$tmp/link-canary"
chmod 600 "$tmp/link-canary"
ln -s "$tmp/link-canary" "$dest"
set +e
link=$("$ROOT_DIR/install/scripts/orp_helper" config publish 2>&1)
link_rc=$?
set -e
[ "$link_rc" -ne 0 ]
[ "$(cat "$tmp/link-canary")" = "KEEP" ]
[ "$(stat -c '%a' "$tmp/link-canary")" = "600" ]
echo "ok: a symlinked destination is not replaced"

# Ancestor symlink.
rm -f "$dest"
other="$tmp/other"
orp_mkdir "$other/svxlink"
printf 'ANCESTOR\n' > "$other/svxlink/svxlink.conf"
chmod 600 "$other/svxlink/svxlink.conf"
rm -rf "$live/etc"
ln -s "$other" "$live/etc"
set +e
anc=$("$ROOT_DIR/install/scripts/orp_helper" config publish 2>&1)
anc_rc=$?
set -e
[ "$anc_rc" -ne 0 ]
[ "$(cat "$other/svxlink/svxlink.conf")" = "ANCESTOR" ]
[ "$(stat -c '%a' "$other/svxlink/svxlink.conf")" = "600" ]
echo "ok: an ancestor symlink is not followed"
echo "config publish boundary checks passed"
