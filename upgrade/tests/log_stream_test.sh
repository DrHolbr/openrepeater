#!/bin/bash
# The repeater log page reads only /var/log/svxlink, with integer range headers.
set -euo pipefail

ROOT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
# shellcheck source=lib/http_session.sh
. "$ROOT_DIR/upgrade/tests/lib/http_session.sh"
tmp=$(mktemp -d)
trap 'chmod 644 "$log" 2>/dev/null || true; kill "$server" >/dev/null 2>&1 || true; rm -rf "$tmp"' EXIT
db="$tmp/openrepeater.db"
jar="$tmp/cookies"
log="/tmp/orp-log-svxlink-$$"
host="$tmp/hostname"
marker="$tmp/bench-mode"
port=8773
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
printf 'orp-test\n' > "$host"
printf 'bench\n' > "$marker"
: > "$log"
export ORP_DB_PATH="$db"
export ORP_BENCH_TEST_HARNESS=1
export ORP_BENCH_HOSTNAME_FILE="$host"
export ORP_BENCH_MARKER="$marker"
export ORP_SVXLINK_LOG="$log"
export ORP_ROOT="$tmp"
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
page=$(curl -s -b "$jar" "$base/log.php")
printf '%s' "$page" | grep -q 'Active Repeater Log'
printf '%s' "$page" | grep -q 'logtail.js'
token=$(http_token "$page")
js=$(curl -s -b "$jar" "$base/includes/js/logtail.js")
printf '%s' "$js" | grep -q 'functions/log_stream.php'
printf '%s' "$js" | grep -q 'X-CSRF-Token'
printf '%s' "$js" | grep -q 'The log stream did not return an integer length'
if printf '%s' "$js" | grep -q 'throw "Invalid integer'; then
	echo "FAIL: log client still throws Invalid integer" >&2
	exit 1
fi
echo "ok: log page loads the stream client that expects integer lengths"

code=$(curl -s -D "$tmp/anon.hdr" -o "$tmp/anon.body" -w '%{http_code}' "$base/functions/log_stream.php")
[ "$code" = "401" ]
grep -q 'text/plain' "$tmp/anon.hdr"
echo "ok: anonymous log stream is 401"

empty_hdr="$tmp/empty.hdr"
empty_body="$tmp/empty.body"
code=$(curl -s -D "$empty_hdr" -o "$empty_body" -w '%{http_code}' -b "$jar" \
	-H "X-CSRF-Token: ${token}" \
	-H 'Range: bytes=-100' \
	"$base/functions/log_stream.php")
[ "$code" = "200" ]
grep -qi '^Content-Length: 0' "$empty_hdr"
[ ! -s "$empty_body" ]
echo "ok: an empty SvxLink log returns a zero integer length"

printf 'SvxLink v1.10.2@26.05.2 Event handler script successfully loaded\n' > "$log"
pop_hdr="$tmp/pop.hdr"
pop_body="$tmp/pop.body"
code=$(curl -s -D "$pop_hdr" -o "$pop_body" -w '%{http_code}' -b "$jar" \
	-H "X-CSRF-Token: ${token}" \
	-H 'Range: bytes=-80' \
	"$base/functions/log_stream.php?file=/etc/passwd" || true)
if [ "$code" != "206" ]; then
	echo "FAIL: populated log status ${code}" >&2
	cat "$pop_hdr" >&2 || true
	exit 1
fi
grep -q 'text/plain' "$pop_hdr"
grep -E -q '^Content-Range: bytes [0-9]+-[0-9]+/[0-9]+' "$pop_hdr"
grep -E -q '^Content-Length: [0-9]+' "$pop_hdr"
grep -q 'Event handler script successfully loaded' "$pop_body"
if grep -q 'root:' "$pop_body"; then
	echo "FAIL: log stream returned an unrelated file" >&2
	exit 1
fi
python3 - "$pop_hdr" "$pop_body" <<'PY'
import re, sys
hdr, body = open(sys.argv[1]).read(), open(sys.argv[2], "rb").read()
m = re.search(r"(?im)^Content-Range: bytes (\d+)-(\d+)/(\d+)", hdr)
n = re.search(r"(?im)^Content-Length: (\d+)", hdr)
if not m or not n or not n.group(1).isdigit():
    raise SystemExit("missing integer range headers")
start, end, total = map(int, m.groups())
length = int(n.group(1))
if length != len(body) or end - start + 1 != length or total < end:
    raise SystemExit("range integers do not match the body")
print("ok: populated log range uses integer Content-Range and Content-Length")
PY

code=$(curl -s -D "$tmp/bad.hdr" -o /dev/null -w '%{http_code}' -b "$jar" \
	-H "X-CSRF-Token: ${token}" \
	-H 'Range: bytes=null-' \
	"$base/functions/log_stream.php")
[ "$code" = "416" ]
grep -E -q '^Content-Range: bytes \*/[0-9]+' "$tmp/bad.hdr"
echo "ok: a null range is 416 with an integer total"

rm -f "$log"
code=$(curl -s -o "$tmp/miss.body" -w '%{http_code}' -b "$jar" \
	-H "X-CSRF-Token: ${token}" \
	"$base/functions/log_stream.php")
[ "$code" = "404" ]
grep -q 'not present' "$tmp/miss.body"
: > "$log"
chmod 000 "$log"
code=$(curl -s -o "$tmp/perm.body" -w '%{http_code}' -b "$jar" \
	-H "X-CSRF-Token: ${token}" \
	"$base/functions/log_stream.php")
[ "$code" = "403" ]
grep -q 'not readable' "$tmp/perm.body"
chmod 644 "$log"
echo "ok: missing and unreadable logs return useful errors"
code=$(curl -s -o "$tmp/nocsrf.body" -w '%{http_code}' -b "$jar" \
	-H 'Range: bytes=-80' \
	"$base/functions/log_stream.php")
[ "$code" = "403" ]
grep -q 'forbidden' "$tmp/nocsrf.body"
code=$(curl -s -o /dev/null -w '%{http_code}' -b "$jar" \
	-H "Origin: https://evil.example" \
	-H "X-CSRF-Token: ${token}" \
	"$base/functions/log_stream.php")
[ "$code" = "403" ]
code=$(curl -s -D "$tmp/post.hdr" -o /dev/null -w '%{http_code}' -b "$jar" \
	-X POST \
	-H "X-CSRF-Token: ${token}" \
	"$base/functions/log_stream.php")
[ "$code" = "405" ]
grep -q 'Allow: GET, HEAD' "$tmp/post.hdr"
echo "ok: missing CSRF and a foreign origin are refused"
echo "ok: a POST to the log stream is refused"
node "$ROOT_DIR/upgrade/tests/logtail_client_test.js" "$ROOT_DIR/includes/js/logtail.js"
echo "log stream checks passed"
