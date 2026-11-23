#!/bin/bash
# Unarmed functional-test publish keeps the UI document and disarms the radio.
set -euo pipefail

ROOT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
# shellcheck source=lib/fixture_tmpdir.sh
. "$ROOT_DIR/upgrade/tests/lib/fixture_tmpdir.sh"
# shellcheck source=lib/native_layout.sh
. "$ROOT_DIR/upgrade/tests/lib/native_layout.sh"
orp_use_fixture_tmpdir
tmp=$(orp_mktemp_dir)
trap 'sudo -n chown -R "$(id -u):$(id -g)" "$tmp" 2>/dev/null || true; orp_cleanup_fixture "$tmp"' EXIT

live="$tmp/live"
db="$tmp/openrepeater.db"
host="$tmp/hostname"
mode="$tmp/operating-mode"
cards="$tmp/cards"
preview="$live/var/lib/openrepeater/bench-preview"
orp_mkdir "$live" "$live/etc/svxlink" "$live/var/backups/orp-ui" "$preview" "$live/var/lib/openrepeater/db"
plant_native_layout "$live"
chmod 755 "$tmp" "$live" "$live/etc" "$live/etc/svxlink" "$live/var" "$live/var/lib" \
	"$live/var/lib/openrepeater" "$live/var/lib/openrepeater/db" "$preview" \
	"$live/var/backups" "$live/var/backups/orp-ui"
printf 'orp-test\n' > "$host"
printf 'functional-test\n' > "$mode"
sudo -n chown 0:0 "$mode"
sudo -n chmod 644 "$mode"
: > "$cards"
orp_copy_writable "$ROOT_DIR/install/sql/openrepeater.db" "$db"
sqlite3 "$db" "UPDATE settings SET value='FIXTURE' WHERE keyID='callSign';"
apply_ident_profile "$db"
cat > "$preview/svxlink.conf" <<'EOF'
[GLOBAL]
MODULE_PATH=/usr/local/lib/svxlink
LOGICS=ORP_RepeaterLogic_Port1
CFG_DIR=/etc/svxlink/functional-test.d
[ORP_RepeaterLogic_Port1]
TYPE=Repeater
CALLSIGN=FIXTURE
SHORT_IDENT_INTERVAL=7
LONG_IDENT_INTERVAL=60
RGR_SOUND_DELAY=0
[Rx1]
TYPE=Local
AUDIO_DEV=plughw:0
AUDIO_CHANNEL=0
SQL_DET=GPIO
GPIO_SQL_PIN=gpio23
[Tx1]
TYPE=Local
AUDIO_DEV=plughw:0
AUDIO_CHANNEL=0
PTT_TYPE=GPIO
PTT_PIN=gpio498
[ModuleEchoLink]
SERVERS=servers.echolink.org
EOF
chmod 644 "$preview/svxlink.conf"
sudo -n chown -R root:root "$live/usr/local/share/svxlink" "$live/usr/local/lib/svxlink" "$live/etc/svxlink"
printf 'GPIO_OUT_HIGH="gpio498"\n' > "$preview/gpio.conf"
chmod 644 "$preview/gpio.conf"

publish() {
	sudo -n env ORP_BENCH_TEST_HARNESS=1 ORP_ROOT="$live" ORP_DB_PATH="$db" \
		ORP_BENCH_HOSTNAME_FILE="$host" ORP_OPERATING_MODE_FILE="$mode" \
		ORP_BENCH_MARKER="$tmp/no-marker" ORP_ALSA_CARDS_FILE="$cards" \
		"$ROOT_DIR/install/scripts/orp_helper" config publish
}

publish >/dev/null
dest="$live/etc/svxlink/svxlink.conf"
grep -q '^\[GLOBAL\]$' "$dest"
grep -q '^LOGICS=ORP_RepeaterLogic_Port1$' "$dest"
grep -q '^\[ORP_RepeaterLogic_Port1\]$' "$dest"
grep -q '^SHORT_IDENT_INTERVAL=7$' "$dest"
grep -q '^LONG_IDENT_INTERVAL=60$' "$dest"
grep -q '^\[ModuleEchoLink\]$' "$dest"
grep -q '^SERVERS=servers.echolink.org$' "$dest"
grep -q '^PTT_TYPE=NONE$' "$dest"
grep -q '^SQL_DET=SIGLEV$' "$dest"
grep -q '^AUDIO_DEV=udp:127.0.0.1:17001$' "$dest"
grep -q '^AUDIO_DEV=udp:127.0.0.1:17002$' "$dest"
if grep -E -q 'PTT_PIN|GPIO_SQL_PIN|gpio498|PTT_TYPE=GPIO|GPIO_OUT_HIGH' "$dest"; then
	echo "FAIL: radio pins remained in the published config" >&2
	cat "$dest" >&2
	exit 1
fi
if [ -e "$live/etc/svxlink/gpio.conf" ]; then
	echo "FAIL: unarmed publish installed gpio.conf" >&2
	exit 1
fi
echo "ok: unarmed publish keeps the UI logic and disarms the radio"

printf ' 0 [Dummy ]: dummy\n' > "$cards"
cat > "$preview/svxlink.conf" <<'EOF'
[GLOBAL]
LOGICS=ORP_RepeaterLogic_Port1
[ORP_RepeaterLogic_Port1]
TYPE=Repeater
CALLSIGN=FIXTURE
SHORT_IDENT_INTERVAL=7
[Rx1]
TYPE=Local
AUDIO_DEV=plughw:0
SQL_DET=SIGLEV
[Tx1]
TYPE=Local
AUDIO_DEV=plughw:1
PTT_TYPE=Dummy
EOF
chmod 644 "$preview/svxlink.conf"
publish >/dev/null
grep -q '^AUDIO_DEV=plughw:0$' "$dest"
grep -q '^AUDIO_DEV=plughw:1$' "$dest"
grep -q '^PTT_TYPE=NONE$' "$dest"
grep -q '^SHORT_IDENT_INTERVAL=7$' "$dest"
echo "ok: a present ALSA card keeps the stored audio device"
echo "functional config sanitize checks passed"
