#!/bin/bash
# Successful and failed login against a temporary database. No station password is used.
set -euo pipefail

ROOT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
# shellcheck source=lib/fixture_tmpdir.sh
. "$ROOT_DIR/upgrade/tests/lib/fixture_tmpdir.sh"
# shellcheck source=lib/http_session.sh
. "$ROOT_DIR/upgrade/tests/lib/http_session.sh"
orp_use_fixture_tmpdir
work=$(orp_mktemp_dir)
db="$work/openrepeater.db"
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

export ORP_DB_PATH="$db"
export ORP_FLAG_STORE=sqlite
export ORP_BENCH_MARKER="/no/such/orp-bench-mode"
export ORP_BENCH_HOSTNAME_FILE="/no/such-orp-hostname"
port=8766
php -S 127.0.0.1:${port} -t "$ROOT_DIR" >"$work/server.log" 2>&1 &
server=$!
cleanup() {
	kill "$server" >/dev/null 2>&1 || true
	rm -rf "$work"
}
trap cleanup EXIT

contains() {
	grep -q -F -e "$1" <<< "$2"
}

ready=0
for _ in 1 2 3 4 5 6 7 8 9 10; do
	if curl -sf -o /dev/null "http://127.0.0.1:${port}/login.php"; then
		ready=1
		break
	fi
	sleep 0.2
done
if [ "$ready" -ne 1 ]; then
	echo "FAIL: login server did not start" >&2
	cat "$work/server.log" >&2 || true
	exit 1
fi

code=$(curl -s -o "$work/gpio-anon.html" -w '%{http_code}' "http://127.0.0.1:${port}/gpio.php")
if [ "$code" = "302" ] && grep -q 'login.php' "$work/gpio-anon.html"; then
	echo "ok: anonymous GPIO page redirects to login"
else
	# PHP header() redirects have an empty body and a Location header.
	headers=$(curl -s -D - -o /dev/null "http://127.0.0.1:${port}/gpio.php")
	contains 302 "$headers" && contains 'login.php' "$headers"
	echo "ok: anonymous GPIO page redirects to login"
fi

bad_jar=$(mktemp)
login_page=$(curl -s -c "$bad_jar" -b "$bad_jar" "http://127.0.0.1:${port}/login.php")
bad_token=$(http_token "$login_page")
code=$(curl -s -c "$bad_jar" -b "$bad_jar" -o "$work/bad-login.html" -w '%{http_code}' \
	--data-urlencode 'username=admin' \
	--data-urlencode 'password=wrong-password' \
	--data-urlencode "csrf_token=${bad_token}" \
	"http://127.0.0.1:${port}/login.php")
headers=$(curl -s -D - -c "$bad_jar" -b "$bad_jar" -o /dev/null \
	--data-urlencode 'username=admin' \
	--data-urlencode 'password=wrong-password' \
	--data-urlencode "csrf_token=${bad_token}" \
	"http://127.0.0.1:${port}/login.php")
contains 'incorrectLogin' "$headers"
gpio_headers=$(curl -s -D - -b "$bad_jar" -o /dev/null "http://127.0.0.1:${port}/gpio.php")
contains 'login.php' "$gpio_headers"
echo "ok: wrong password does not open a protected page"

unknown_jar=$(mktemp)
unknown_page=$(curl -s -c "$unknown_jar" -b "$unknown_jar" "http://127.0.0.1:${port}/login.php")
unknown_token=$(http_token "$unknown_page")
unknown_headers=$(curl -s -D - -c "$unknown_jar" -b "$unknown_jar" -o /dev/null \
	--data-urlencode 'username=nobody' \
	--data-urlencode 'password=wrong-password' \
	--data-urlencode "csrf_token=${unknown_token}" \
	"http://127.0.0.1:${port}/login.php")
contains 'incorrectLogin' "$unknown_headers"
contains 302 "$unknown_headers"
echo "ok: unknown user is rejected without a server error"

jar=$(mktemp)
login_ok=$(curl -s -c "$jar" -b "$jar" "http://127.0.0.1:${port}/login.php")
ok_token=$(http_token "$login_ok")
headers=$(curl -s -D - -c "$jar" -b "$jar" -o /dev/null \
	--data-urlencode 'username=admin' \
	--data-urlencode 'password=bench-only-test' \
	--data-urlencode "csrf_token=${ok_token}" \
	"http://127.0.0.1:${port}/login.php")
contains 302 "$headers"
contains 'dashboard.php' "$headers"
page=$(curl -s -b "$jar" "http://127.0.0.1:${port}/gpio.php")
contains 'GPIO map' "$page"
if contains 'Please login' "$page"; then
	echo "FAIL: protected GPIO page still shows the login form" >&2
	exit 1
fi
dash=$(curl -s -b "$jar" "http://127.0.0.1:${port}/dashboard.php")
contains 'Core System Info' "$dash"
if contains 'Please login' "$dash"; then
	echo "FAIL: dashboard still shows the login form" >&2
	exit 1
fi
echo "ok: valid login sets a session that can open protected pages"
rm -f "$bad_jar" "$jar" "$unknown_jar"
echo "login session checks passed"
