#!/bin/bash
# Load each of the five board presets through the ports form on a copied database.
set -euo pipefail

ROOT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
# shellcheck source=lib/http_session.sh
. "$ROOT_DIR/upgrade/tests/lib/http_session.sh"
# shellcheck source=lib/native_layout.sh
. "$ROOT_DIR/upgrade/tests/lib/native_layout.sh"
tmp=$(mktemp -d)
trap 'kill "$server" >/dev/null 2>&1 || true; rm -rf "$tmp"' EXIT
db="$tmp/openrepeater.db"
jar="$tmp/cookies"
host="$tmp/hostname"
marker="$tmp/bench-mode"
mode="$tmp/mode"
live="$tmp/live"
port=8774
cp "$ROOT_DIR/install/sql/openrepeater.db" "$db"
php -r '
$db = new SQLite3($argv[1]);
$salt = "testhost";
$password = "bench-only-test";
$hash = hash("sha256", $salt . hash("sha256", $password));
$stmt = $db->prepare("UPDATE users SET salt = :salt, password = :password WHERE username = \"admin\"");
$stmt->bindValue(":salt", $salt, SQLITE3_TEXT);
$stmt->bindValue(":password", $hash, SQLITE3_TEXT);
$stmt->execute();
$stmt = $db->prepare("UPDATE settings SET value = :value WHERE keyID = \"callSign\"");
$stmt->bindValue(":value", "TEST", SQLITE3_TEXT);
$stmt->execute();
' "$db"
apply_ident_profile "$db"
printf 'orp-test\n' > "$host"
printf 'bench\n' > "$marker"
printf 'bench\n' > "$mode"
plant_native_layout "$live"
mkdir -p "$live/var/backups/orp-ui"
chmod 755 "$live" "$live/etc" "$live/etc/svxlink" "$live/var" "$live/var/backups" "$live/var/backups/orp-ui"
export ORP_DB_PATH="$db"
export ORP_BENCH_TEST_HARNESS=1
export ORP_BENCH_HOSTNAME_FILE="$host"
export ORP_BENCH_MARKER="$marker"
export ORP_OPERATING_MODE_FILE="$mode"
php -S 127.0.0.1:${port} -t "$ROOT_DIR" >"$tmp/server.log" 2>&1 &
server=$!
ready=0
for _ in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15; do
	if curl -sf -o /dev/null "http://127.0.0.1:${port}/login.php"; then ready=1; break; fi
	sleep 0.2
done
[ "$ready" = 1 ]
base="http://127.0.0.1:${port}"
login_page=$(curl -s -c "$jar" -b "$jar" "$base/login.php")
login_token=$(http_token "$login_page")
curl -s -c "$jar" -b "$jar" -o /dev/null \
	--data-urlencode 'username=admin' \
	--data-urlencode 'password=bench-only-test' \
	--data-urlencode "csrf_token=${login_token}" \
	"$base/login.php"
page=$(curl -s -b "$jar" "$base/ports.php")
token=$(http_token "$page")
printf '%s' "$page" | grep -q 'loadBoardPreset'
for id in 0 1 2 3 4; do
	code=$(curl -s -o "$tmp/load-$id.body" -w '%{http_code}' -b "$jar" \
		--data-urlencode 'action=loadBoardPreset' \
		--data-urlencode "board_id=${id}" \
		--data-urlencode "csrf_token=${token}" \
		"$base/ports.php")
	[ "$code" = "200" ]
	php "$ROOT_DIR/upgrade/tests/preset_roundtrip_check.php" "$ROOT_DIR" "$db" "$id"
done
echo "ok: all five presets round-trip from the form into the copied database"

printf 'functional-test\n' > "$mode"
export ORP_OPERATING_MODE_FILE="$mode"
export ORP_ROOT="$live"
export ORP_DB_PATH="$db"
"$ROOT_DIR/install/scripts/orp_helper" config publish >/dev/null
cfg="$live/etc/svxlink/svxlink.conf"
grep -q '^PTT_TYPE=NONE$' "$cfg"
grep -q '^CALLSIGN=TEST$' "$cfg"
if grep -q 'PTT_PIN\|gpio498\|GPIO_SQL' "$cfg"; then
	echo "FAIL: preset numbers were copied into the no-PTT runtime" >&2
	exit 1
fi
echo "ok: loading a preset does not put TX numbers into the root runtime"
echo "preset round-trip checks passed"
