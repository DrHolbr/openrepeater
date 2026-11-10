#!/bin/bash
# Real HTTP checks for the privileged dispatcher. Denial responses are
# produced before the helper stub or the database changes.
set -euo pipefail

ROOT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
# shellcheck source=lib/fixture_tmpdir.sh
. "$ROOT_DIR/upgrade/tests/lib/fixture_tmpdir.sh"
# shellcheck source=lib/http_session.sh
. "$ROOT_DIR/upgrade/tests/lib/http_session.sh"
orp_use_fixture_tmpdir
tmp=$(orp_mktemp_dir)
trap 'kill "$server" >/dev/null 2>&1 || true; rm -rf "$tmp"' EXIT
db="$tmp/openrepeater.db"
jar="$tmp/cookies"
log="$tmp/helper.log"
hostfile="$tmp/hostname"
port=8771
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
printf 'orp-test\n' > "$hostfile"
: > "$log"
gate_db="$tmp/gate.db"
gate_sessions="$tmp/sessions"
orp_mkdir "$gate_sessions"
cp "$db" "$gate_db"
php "$ROOT_DIR/upgrade/tests/auth_account_gate_test.php" "$gate_db" "$gate_sessions"
password_before=$(php -r 'echo (new SQLite3($argv[1]))->querySingle("SELECT password FROM users WHERE username=\"admin\"");' "$db")

export ORP_DB_PATH="$db"
export ORP_FLAG_STORE=sqlite
export ORP_BENCH_TEST_HARNESS=1
export ORP_BENCH_MARKER="$tmp/no-bench-marker"
export ORP_BENCH_HOSTNAME_FILE="$hostfile"
export ORP_HELPER_STUB=1
export ORP_HELPER_LOG="$log"
php -S 127.0.0.1:${port} -t "$ROOT_DIR" >"$tmp/server.log" 2>&1 &
server=$!
ready=0
for _ in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15; do
	if curl -sf -o /dev/null "http://127.0.0.1:${port}/login.php"; then ready=1; break; fi
	sleep 0.2
done
if [ "$ready" -ne 1 ]; then
	echo "FAIL: auth server did not start" >&2
	cat "$tmp/server.log" >&2 || true
	exit 1
fi

base="http://127.0.0.1:${port}"
callsign() {
	php -r 'echo (new SQLite3($argv[1]))->querySingle("SELECT value FROM settings WHERE keyID=\"callSign\"");' "$db"
}

code=$(curl -s -o "$tmp/anon.body" -w '%{http_code}' \
	--data-urlencode 'post_service=svxlink' \
	--data-urlencode 'post_option=status' \
	"$base/functions/ajax_system.php")
[ "$code" = "401" ]
grep -q 'unauthorized' "$tmp/anon.body"
[ ! -s "$log" ]
[ "$(callsign)" = "TEST" ]
echo "ok: cookie-free lifecycle POST is 401 before the helper"

code=$(curl -s -o "$tmp/random.body" -w '%{http_code}' \
	-H 'Cookie: PHPSESSID=aaaaaaaaaaaaaaaaaaaaaaaaaa' \
	--data-urlencode 'post_service=svxlink' \
	--data-urlencode 'post_option=start' \
	"$base/functions/ajax_system.php")
[ "$code" = "401" ]
[ ! -s "$log" ]
[ "$(callsign)" = "TEST" ]
echo "ok: a random session cookie is 401 before the helper"

login_page=$(curl -s -c "$jar" -b "$jar" "$base/login.php")
login_token=$(http_token "$login_page")
[ -n "$login_token" ]
headers=$(curl -s -D - -c "$jar" -b "$jar" -o /dev/null \
	--data-urlencode 'username=admin' \
	--data-urlencode 'password=bench-only-test' \
	--data-urlencode "csrf_token=${login_token}" \
	"$base/login.php")
printf '%s\n' "$headers" | grep -q 'dashboard.php'
dash=$(curl -s -b "$jar" -c "$jar" "$base/dashboard.php")
token=$(http_token "$dash")
[ -n "$token" ]
printf '%s' "$dash" | grep -q 'name="csrf-token"'
printf '%s' "$dash" | grep -q 'page-dashboard.js'
js=$(curl -s -b "$jar" "$base/includes/js/page-dashboard.js")
printf '%s' "$js" | grep -q 'function orpCsrfToken'
printf '%s' "$js" | grep -q 'csrf_token: orpCsrfToken()'
echo "ok: dashboard renders the token and the repeater control posts it"

code=$(curl -s -o "$tmp/notoken.body" -w '%{http_code}' -b "$jar" \
	--data-urlencode 'post_service=svxlink' \
	--data-urlencode 'post_option=status' \
	"$base/functions/ajax_system.php")
[ "$code" = "403" ]
grep -q 'forbidden' "$tmp/notoken.body"
code=$(curl -s -o "$tmp/badtoken.body" -w '%{http_code}' -b "$jar" \
	--data-urlencode 'post_service=svxlink' \
	--data-urlencode 'post_option=start' \
	--data-urlencode 'csrf_token=not-the-token' \
	"$base/functions/ajax_system.php")
[ "$code" = "403" ]
code=$(curl -s -o "$tmp/get.body" -w '%{http_code}' -b "$jar" -G \
	--data-urlencode 'post_service=svxlink' \
	--data-urlencode 'post_option=start' \
	--data-urlencode "csrf_token=${token}" \
	"$base/functions/ajax_system.php")
[ "$code" = "405" ]
grep -q 'method not allowed' "$tmp/get.body"
code=$(curl -s -o "$tmp/origin.body" -w '%{http_code}' -b "$jar" \
	-H 'Origin: https://evil.example' \
	--data-urlencode 'post_service=svxlink' \
	--data-urlencode 'post_option=status' \
	--data-urlencode "csrf_token=${token}" \
	"$base/functions/ajax_system.php")
[ "$code" = "403" ]
code=$(curl -s -o "$tmp/unmask.body" -w '%{http_code}' -b "$jar" \
	--data-urlencode 'post_service=svxlink' \
	--data-urlencode 'post_option=unmask' \
	--data-urlencode "csrf_token=${token}" \
	"$base/functions/ajax_system.php")
[ "$code" = "403" ]
[ ! -s "$log" ]
[ "$(callsign)" = "TEST" ]
echo "ok: missing token, bad token, GET, cross-origin, and unmask stop before the helper"

code=$(curl -s -o "$tmp/https-origin.body" -w '%{http_code}' -b "$jar" \
	-H "Origin: https://127.0.0.1" \
	--data-urlencode 'post_service=svxlink' \
	--data-urlencode 'post_option=status' \
	--data-urlencode "csrf_token=${token}" \
	"$base/functions/ajax_system.php")
[ "$code" = "403" ]
code=$(curl -s -o "$tmp/https-port.body" -w '%{http_code}' -b "$jar" \
	-H "Origin: https://127.0.0.1:${port}" \
	-H 'X-Forwarded-Proto: https' \
	--data-urlencode 'post_service=svxlink' \
	--data-urlencode 'post_option=status' \
	--data-urlencode "csrf_token=${token}" \
	"$base/functions/ajax_system.php")
[ "$code" = "403" ]
code=$(curl -s -o "$tmp/wrong-port.body" -w '%{http_code}' -b "$jar" \
	-H "Origin: http://127.0.0.1:9" \
	--data-urlencode 'post_service=svxlink' \
	--data-urlencode 'post_option=status' \
	--data-urlencode "csrf_token=${token}" \
	"$base/functions/ajax_system.php")
[ "$code" = "403" ]
[ ! -s "$log" ]
echo "ok: https and the wrong port are not this HTTP origin, and forwarded proto is not trusted"

sqlite3 "$db" "UPDATE users SET username='renamed' WHERE userID=1;"
code=$(curl -s -o "$tmp/mismatch.body" -w '%{http_code}' -b "$jar" \
	--data-urlencode 'post_service=svxlink' \
	--data-urlencode 'post_option=status' \
	--data-urlencode "csrf_token=${token}" \
	"$base/functions/ajax_system.php")
[ "$code" = "401" ]
sqlite3 "$db" "UPDATE users SET username='admin' WHERE userID=1;"
[ ! -s "$log" ]
[ "$(callsign)" = "TEST" ]
echo "ok: a session whose username no longer matches the account row is 401"

code=$(curl -s -o "$tmp/status.body" -w '%{http_code}' -b "$jar" \
	--data-urlencode 'post_service=svxlink' \
	--data-urlencode 'post_option=status' \
	--data-urlencode "csrf_token=${token}" \
	"$base/functions/ajax_system.php")
[ "$code" = "200" ]
grep -qx 'inactive' "$tmp/status.body"
grep -qx 'svxlink status' "$log"
echo "ok: authenticated status POST reaches the helper with the allowlisted arguments"

code=$(curl -s -o "$tmp/dbdeny.body" -w '%{http_code}' -b "$jar" \
	--data-urlencode 'callSign=HACKED' \
	"$base/functions/ajax_db_update.php")
[ "$code" = "403" ]
[ "$(callsign)" = "TEST" ]
code=$(curl -s -o "$tmp/dbok.body" -w '%{http_code}' -b "$jar" \
	--data-urlencode 'callSign=TEST2' \
	--data-urlencode "csrf_token=${token}" \
	"$base/functions/ajax_db_update.php")
[ "$code" = "200" ]
[ "$(callsign)" = "TEST2" ]
password_after=$(php -r 'echo (new SQLite3($argv[1]))->querySingle("SELECT password FROM users WHERE username=\"admin\"");' "$db")
[ "$password_before" = "$password_after" ]
echo "ok: settings writes require the token and the account password is unchanged"

code=$(curl -s -o "$tmp/rebuild-get.body" -w '%{http_code}' -b "$jar" \
	"$base/functions/svxlink_update.php")
[ "$code" = "405" ]
code=$(curl -s -o "$tmp/rebuild-post.body" -w '%{http_code}' -b "$jar" \
	--data-urlencode 'return_url=../dashboard.php' \
	"$base/functions/svxlink_update.php")
[ "$code" = "403" ]
[ "$(grep -c . "$log")" -eq 1 ]
echo "ok: config rebuild is not a GET and is not a tokenless POST"

sqlite3 "$db" "DELETE FROM users WHERE userID=1;"
code=$(curl -s -o "$tmp/deleted.body" -w '%{http_code}' -b "$jar" \
	--data-urlencode 'post_service=svxlink' \
	--data-urlencode 'post_option=start' \
	--data-urlencode "csrf_token=${token}" \
	"$base/functions/ajax_system.php")
[ "$code" = "401" ]
[ "$(grep -c . "$log")" -eq 1 ]
[ "$(callsign)" = "TEST2" ]
echo "ok: a deleted account is 401 before the helper"
echo "auth boundary checks passed"
