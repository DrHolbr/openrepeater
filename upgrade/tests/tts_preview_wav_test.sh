#!/bin/bash
# A valid Test Voice response is only the WAV: audio/wav, Content-Length
# equal to the body, and RIFF at byte 0. jQuery 1.7 must not be asked to
# read that body as responseType blob.
set -euo pipefail

ROOT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
# shellcheck source=lib/fixture_tmpdir.sh
. "$ROOT_DIR/upgrade/tests/lib/fixture_tmpdir.sh"
# shellcheck source=lib/http_session.sh
. "$ROOT_DIR/upgrade/tests/lib/http_session.sh"
orp_use_fixture_tmpdir

if grep -q 'xhrFields' "$ROOT_DIR/includes/js/page-settings.js"; then
	echo "FAIL: Test Voice still asks jQuery to read a blob response" >&2
	exit 1
fi
if ! grep -q 'responseXML' "$ROOT_DIR/includes/js/page-settings.js"; then
	echo "FAIL: Test Voice no longer records why jQuery reported HTTP 0" >&2
	exit 1
fi

tmp=$(orp_mktemp_dir)
trap 'kill "$server" >/dev/null 2>&1 || true; rm -rf "$tmp"' EXIT
db="$tmp/openrepeater.db"
jar="$tmp/admin.cookies"
port=8794
orp_copy_writable "$ROOT_DIR/install/sql/openrepeater.db" "$db"
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
mkdir -p "$tmp/bin"
cat > "$tmp/bin/flite" <<'EOF'
#!/bin/bash
out=""
while [ $# -gt 0 ]; do
	if [ "$1" = "-o" ]; then
		out=$2
		shift 2
		continue
	fi
	shift
done
if [ -z "$out" ]; then
	echo "flite stub: missing -o" >&2
	exit 1
fi
python3 - "$out" <<'PY'
import struct, sys
data = b"\x00\x00" * 16
chunks = (
    b"fmt " + struct.pack("<IHHIIHH", 16, 1, 1, 16000, 32000, 2, 16)
    + b"data" + struct.pack("<I", len(data)) + data
)
open(sys.argv[1], "wb").write(b"RIFF" + struct.pack("<I", 4 + len(chunks)) + b"WAVE" + chunks)
PY
EOF
chmod 755 "$tmp/bin/flite"
export PATH="$tmp/bin:$PATH"
export ORP_DB_PATH="$db"
export ORP_BENCH_TEST_HARNESS=1
php -S 127.0.0.1:${port} -t "$ROOT_DIR" >"$tmp/server.log" 2>&1 &
server=$!
ready=0
for _ in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15; do
	if curl -sf -o /dev/null "http://127.0.0.1:${port}/login.php"; then ready=1; break; fi
	sleep 0.2
done
[ "$ready" = 1 ]
base="http://127.0.0.1:${port}"
page=$(curl -s -c "$jar" -b "$jar" "$base/login.php")
token=$(http_token "$page")
curl -s -c "$jar" -b "$jar" -o /dev/null \
	--data-urlencode "username=admin" \
	--data-urlencode "password=bench-only-test" \
	--data-urlencode "csrf_token=${token}" \
	"$base/login.php"
page=$(curl -s -b "$jar" "$base/settings.php")
token=$(http_token "$page")
[ -n "$token" ]
code=$(curl -s -D "$tmp/wav.hdr" -o "$tmp/wav.body" -w '%{http_code}' -b "$jar" \
	-H "X-CSRF-Token: ${token}" \
	--data-urlencode 'engine=flite' \
	--data-urlencode 'flite_voice=slt' \
	--data-urlencode 'gain_db=0' \
	"$base/functions/tts_preview.php")
if [ "$code" != "200" ]; then
	echo "FAIL: Test Voice HTTP ${code}" >&2
	cat "$tmp/wav.hdr" >&2 || true
	exit 1
fi
tr -d '\r' < "$tmp/wav.hdr" > "$tmp/wav.hdr.lf"
ctype=$(awk 'BEGIN{IGNORECASE=1} /^Content-Type:/ { sub(/^[^:]*:[[:space:]]*/, ""); print; exit }' "$tmp/wav.hdr.lf")
clen=$(awk 'BEGIN{IGNORECASE=1} /^Content-Length:/ { print $2; exit }' "$tmp/wav.hdr.lf")
bytes=$(wc -c < "$tmp/wav.body" | tr -d ' ')
if [ "$ctype" != "audio/wav" ]; then
	echo "FAIL: Test Voice Content-Type is [${ctype}]" >&2
	exit 1
fi
if [ "$clen" != "$bytes" ]; then
	echo "FAIL: Test Voice Content-Length ${clen} is not the ${bytes} bytes sent" >&2
	exit 1
fi
magic=$(head -c 12 "$tmp/wav.body" | od -An -tx1 | tr -d ' \n')
if [ "${magic#52494646}" = "$magic" ] || [ "${magic#52494646????????57415645}" = "$magic" ]; then
	echo "FAIL: Test Voice body does not start with a RIFF WAVE header" >&2
	echo "$magic" >&2
	exit 1
fi
echo "ok: Test Voice returns audio/wav with Content-Length and a leading RIFF header"
