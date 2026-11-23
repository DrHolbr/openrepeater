#!/bin/bash
# A custom identification clip is copied where 26.05 send_*_announce_ident plays it.
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
mode="$tmp/operating-mode"
orp_mkdir "$live" "$live/etc/svxlink" "$live/var/backups/orp-ui" \
	"$live/var/www/openrepeater/sounds/identification"
plant_native_layout "$live"
chmod 755 "$live" "$live/etc" "$live/etc/svxlink" "$live/var" "$live/var/backups" "$live/var/backups/orp-ui"
printf 'orp-test\n' > "$host"
printf 'functional-test\n' > "$mode"
orp_private "$mode"
chmod 644 "$mode"
orp_copy_writable "$ROOT_DIR/install/sql/openrepeater.db" "$db"
sqlite3 "$db" "UPDATE settings SET value='FIXTURE' WHERE keyID='callSign';"
apply_ident_profile "$db"
printf 'short-clip\n' > "$live/var/www/openrepeater/sounds/identification/Sample_Short_ID_Clip.wav"
printf 'long-clip\n' > "$live/var/www/openrepeater/sounds/identification/Sample_Long_ID_Clip.wav"
sqlite3 "$db" "
UPDATE settings SET value='custom' WHERE keyID='ID_Short_Mode';
UPDATE settings SET value='Sample_Short_ID_Clip.wav' WHERE keyID='ID_Short_CustomFile';
UPDATE settings SET value='custom' WHERE keyID='ID_Long_Mode';
UPDATE settings SET value='Sample_Long_ID_Clip.wav' WHERE keyID='ID_Long_CustomFile';
UPDATE settings SET value='5' WHERE keyID='ID_Long_IntervalMin';
UPDATE settings SET value='False' WHERE keyID='ID_Short_AppendMorse';
UPDATE settings SET value='False' WHERE keyID='ID_Long_AppendMorse';
"

export ORP_BENCH_TEST_HARNESS=1
export ORP_BENCH_HOSTNAME_FILE="$host"
export ORP_OPERATING_MODE_FILE="$mode"
export ORP_BENCH_MARKER="$tmp/no-marker"
export ORP_DB_PATH="$db"
export ORP_ROOT="$live"

"$ROOT_DIR/install/scripts/orp_helper" config publish >/dev/null
dest="$live/etc/svxlink/svxlink.conf"
grep -q '^SHORT_ANNOUNCE_ENABLE=1$' "$dest"
grep -q '^LONG_ANNOUNCE_ENABLE=1$' "$dest"
grep -q '^SHORT_ANNOUNCE_FILE=/usr/local/share/svxlink/sounds/identification/Sample_Short_ID_Clip.wav$' "$dest"
grep -q '^LONG_ANNOUNCE_FILE=/usr/local/share/svxlink/sounds/identification/Sample_Long_ID_Clip.wav$' "$dest"
grep -q '^SHORT_VOICE_ID_ENABLE=0$' "$dest"
grep -q '^LONG_VOICE_ID_ENABLE=0$' "$dest"
grep -q '^PTT_TYPE=NONE$' "$dest"
[ "$(cat "$live/usr/local/share/svxlink/sounds/identification/Sample_Short_ID_Clip.wav")" = "short-clip" ]
[ "$(cat "$live/usr/local/share/svxlink/sounds/identification/Sample_Long_ID_Clip.wav")" = "long-clip" ]
echo "ok: custom identification clips are published for the 26.05 announce handler"

rm -f "$live/var/www/openrepeater/sounds/identification/Sample_Long_ID_Clip.wav"
sum=$(sha256sum "$dest" | awk '{print $1}')
set +e
out=$("$ROOT_DIR/install/scripts/orp_helper" config publish 2>&1)
rc=$?
set -e
[ "$rc" -ne 0 ]
printf '%s\n' "$out" | grep -q 'mode custom is not published'
[ "$(sha256sum "$dest" | awk '{print $1}')" = "$sum" ]
echo "ok: a missing custom identification clip is not published"
echo "custom identification publish checks passed"
