#!/bin/bash
# The privileged publisher ignores web staging. Invalid input does not
# replace a live canary and does not start svxlink.
set -euo pipefail

ROOT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
live="$tmp/live"
db="$tmp/openrepeater.db"
host="$tmp/hostname"
mode="$tmp/mode"
stage="$tmp/staged.conf"
ctl="$tmp/systemctl"
log="$tmp/systemctl.log"
mkdir -p "$live/etc/svxlink" "$live/var/lib/openrepeater/db" "$live/var/backups/orp-ui"
chmod 755 "$live" "$live/etc" "$live/etc/svxlink" "$live/var" "$live/var/lib" "$live/var/lib/openrepeater" "$live/var/lib/openrepeater/db" "$live/var/backups" "$live/var/backups/orp-ui"
printf 'orp-test\n' > "$host"
printf 'functional-test\n' > "$mode"
chmod 644 "$mode"
cp "$ROOT_DIR/install/sql/openrepeater.db" "$db"
sqlite3 "$db" "UPDATE settings SET value='FIXTURE' WHERE keyID='callSign';"

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
grep -q '^EVENT_HANDLER=/usr/share/svxlink/events.tcl$' "$dest"
grep -q '^CALLSIGN=FIXTURE$' "$dest"
[ "$(grep -c '^\[Tx' "$dest")" -eq 1 ]
[ ! -s "$log" ]
echo "ok: publisher ignored the mutable staged file, including a racing rewrite"

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
mkdir -p "$other/svxlink"
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
