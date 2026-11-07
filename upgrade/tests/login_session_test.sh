#!/bin/bash
# Successful and failed login against a temporary database. No station password is used.
set -euo pipefail

ROOT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
db=$(mktemp)
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

export ORP_DB_PATH="$db"
export ORP_FLAG_STORE=sqlite
export ORP_BENCH_MARKER="/no/such/orp-bench-mode"
export ORP_BENCH_HOSTNAME_FILE="/no/such-orp-hostname"
port=8766
php -S 127.0.0.1:${port} -t "$ROOT_DIR" >/tmp/orp-login-server.log 2>&1 &
server=$!
cleanup() {
	kill "$server" >/dev/null 2>&1 || true
	rm -f "$db"
}
trap cleanup EXIT

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
	cat /tmp/orp-login-server.log >&2 || true
	exit 1
fi

code=$(curl -s -o /tmp/orp-gpio-anon.html -w '%{http_code}' "http://127.0.0.1:${port}/gpio.php")
if [ "$code" = "302" ] && grep -q 'login.php' /tmp/orp-gpio-anon.html; then
	echo "ok: anonymous GPIO page redirects to login"
else
	# PHP header() redirects have an empty body and a Location header.
	headers=$(curl -s -D - -o /dev/null "http://127.0.0.1:${port}/gpio.php")
	printf '%s\n' "$headers" | grep -q '302' && printf '%s\n' "$headers" | grep -q 'login.php'
	echo "ok: anonymous GPIO page redirects to login"
fi

bad_jar=$(mktemp)
code=$(curl -s -c "$bad_jar" -o /tmp/orp-bad-login.html -w '%{http_code}' \
	-d 'username=admin' -d 'password=wrong-password' \
	"http://127.0.0.1:${port}/login.php")
headers=$(curl -s -D - -c "$bad_jar" -o /dev/null \
	-d 'username=admin' -d 'password=wrong-password' \
	"http://127.0.0.1:${port}/login.php")
printf '%s\n' "$headers" | grep -q 'incorrectLogin'
gpio_headers=$(curl -s -D - -b "$bad_jar" -o /dev/null "http://127.0.0.1:${port}/gpio.php")
printf '%s\n' "$gpio_headers" | grep -q 'login.php'
echo "ok: wrong password does not open a protected page"

unknown_headers=$(curl -s -D - -o /dev/null \
	-d 'username=nobody' -d 'password=wrong-password' \
	"http://127.0.0.1:${port}/login.php")
printf '%s\n' "$unknown_headers" | grep -q 'incorrectLogin'
printf '%s\n' "$unknown_headers" | grep -q '302'
echo "ok: unknown user is rejected without a server error"

jar=$(mktemp)
headers=$(curl -s -D - -c "$jar" -o /dev/null \
	-d 'username=admin' -d 'password=bench-only-test' \
	"http://127.0.0.1:${port}/login.php")
printf '%s\n' "$headers" | grep -q '302'
printf '%s\n' "$headers" | grep -q 'dashboard.php'
page=$(curl -s -b "$jar" "http://127.0.0.1:${port}/gpio.php")
printf '%s' "$page" | grep -q 'GPIO map'
if printf '%s' "$page" | grep -q 'Please login'; then
	echo "FAIL: protected GPIO page still shows the login form" >&2
	exit 1
fi
dash=$(curl -s -b "$jar" "http://127.0.0.1:${port}/dashboard.php")
printf '%s' "$dash" | grep -q 'Core System Info'
if printf '%s' "$dash" | grep -q 'Please login'; then
	echo "FAIL: dashboard still shows the login form" >&2
	exit 1
fi
echo "ok: valid login sets a session that can open protected pages"
rm -f "$bad_jar" "$jar"
echo "login session checks passed"
