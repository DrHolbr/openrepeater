#!/bin/bash
# Cloud verification harness. Does not talk to the bench Pi or start a radio.
set -euo pipefail

ROOT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
cd "$ROOT_DIR"

if ! command -v php >/dev/null 2>&1; then
	echo "php is required" >&2
	exit 1
fi

echo "PHP $(php -r 'echo PHP_VERSION;')"
fail=0
while IFS= read -r file; do
	if ! php -l "$file" >/dev/null; then
		php -l "$file" || true
		fail=1
	fi
done < <(find . -name '*.php' -not -path './.git/*')
if [ "$fail" -ne 0 ]; then
	echo "php -l failed" >&2
	exit 1
fi
echo "ok: php -l"

php "$ROOT_DIR/upgrade/tests/php_safety_test.php"
bash "$ROOT_DIR/upgrade/tests/install_and_helper_test.sh"

db=$(mktemp)
cp "$ROOT_DIR/install/sql/openrepeater.db" "$db"
export ORP_DB_PATH="$db"
export ORP_FLAG_STORE=sqlite
export ORP_BENCH_MARKER="/no/such/orp-bench-mode"
port=8765
php -S 127.0.0.1:${port} -t "$ROOT_DIR" >/tmp/orp-php-server.log 2>&1 &
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
	echo "login page did not respond" >&2
	cat /tmp/orp-php-server.log >&2 || true
	exit 1
fi
body=$(curl -sf "http://127.0.0.1:${port}/login.php")
printf '%s' "$body" | grep -q 'Please login'
printf '%s' "$body" | grep -q 'name="password"'
code=$(curl -s -o /tmp/orp-index.html -w '%{http_code}' "http://127.0.0.1:${port}/index.php")
test "$code" = "200"
echo "ok: login page renders under PHP $(php -r 'echo PHP_VERSION;')"
echo "ok: index.php HTTP ${code}"
echo "harness passed"
