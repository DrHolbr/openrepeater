#!/bin/bash
# Authenticated wizard Save and Finish with no Memcached extension.
# Uses a copy of the stock database and a throwaway password. No station
# secret, no live SvxLink write, and no radio command.
set -euo pipefail

ROOT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
# shellcheck source=lib/fixture_tmpdir.sh
. "$ROOT_DIR/upgrade/tests/lib/fixture_tmpdir.sh"
# shellcheck source=lib/http_session.sh
. "$ROOT_DIR/upgrade/tests/lib/http_session.sh"
orp_use_fixture_tmpdir
tmp=$(orp_mktemp_dir)
db="$tmp/openrepeater.db"
preview=$(mktemp -d "$(orp_fixture_root)/orp-preview-wizard.XXXXXX")
marker="$tmp/bench-mode"
hostfile="$tmp/hostname"
jar="$tmp/cookies"
serverlog="$tmp/server.log"
cmdlog="$tmp/commands.log"
live_before="$tmp/live.before"
live_after_save="$tmp/live.after-save"
live_after_finish="$tmp/live.after-finish"
bindir="$tmp/bin"
port=8767
server=

cleanup() {
	if [ -n "${server}" ]; then
		kill "$server" >/dev/null 2>&1 || true
		wait "$server" 2>/dev/null || true
	fi
	rm -rf "$tmp" "$preview"
}
trap cleanup EXIT

cp "$ROOT_DIR/install/sql/openrepeater.db" "$db"
printf 'orp-test\n' > "$hostfile"
: > "$marker"
: > "$cmdlog"
orp_mkdir "$bindir"
cat > "$bindir/sudo" <<'EOF'
#!/bin/bash
printf '%s\n' "$*" >> "${ORP_COMMAND_LOG:?}"
exit 0
EOF
cat > "$bindir/systemctl" <<'EOF'
#!/bin/bash
printf '%s\n' "systemctl $*" >> "${ORP_COMMAND_LOG:?}"
exit 0
EOF
chmod 755 "$bindir/sudo" "$bindir/systemctl"

php -r '
if (extension_loaded("memcached")) {
	fwrite(STDERR, "FAIL: memcached extension is loaded; this regression needs the supported set without it\n");
	exit(1);
}
foreach (array("sqlite3", "session") as $ext) {
	if (!extension_loaded($ext)) {
		fwrite(STDERR, "FAIL: required extension {$ext} is not loaded\n");
		exit(1);
	}
}
$_SERVER["DOCUMENT_ROOT"] = $argv[1];
require $argv[1] . "/includes/autoloadClasses.php";
ob_start();
$found = class_exists("Memcached");
$buf = ob_get_clean();
if ($found || strpos($buf, "File Not Found") !== false || strpos($buf, "Memcached.php") !== false) {
	fwrite(STDERR, "FAIL: missing Memcached extension was treated as an OpenRepeater class file\n");
	exit(1);
}
try {
	new MissingOrpClassProbe();
	fwrite(STDERR, "FAIL: a missing OpenRepeater class was constructed\n");
	exit(1);
} catch (Error $e) {
	if (strpos($e->getMessage(), "MissingOrpClassProbe") === false) {
		fwrite(STDERR, "FAIL: missing class error did not name the class\n");
		exit(1);
	}
	if (strpos($e->getMessage(), "Memcached.php") !== false || strpos($e->getMessage(), "File Not Found") !== false) {
		fwrite(STDERR, "FAIL: missing class error was rewritten as a Memcached file path\n");
		exit(1);
	}
}
putenv("ORP_DB_PATH=" . $argv[2]);
$db = new Database();
$db->set_update_flag(true);
if ($db->get_update_flag() !== true) {
	fwrite(STDERR, "FAIL: update flag was not stored in sqlite without Memcached\n");
	exit(1);
}
$sqlite = new SQLite3($argv[2]);
$salt = "testhost";
$password = "bench-only-test";
$hash = hash("sha256", $salt . hash("sha256", $password));
$stmt = $sqlite->prepare("UPDATE users SET salt = :salt, password = :password WHERE username = \"admin\"");
$stmt->bindValue(":salt", $salt, SQLITE3_TEXT);
$stmt->bindValue(":password", $hash, SQLITE3_TEXT);
$stmt->execute();
if ($sqlite->changes() !== 1) {
	fwrite(STDERR, "FAIL: stock admin account was not present to preserve\n");
	exit(1);
}
$stmt = $sqlite->prepare("UPDATE settings SET value = :value WHERE keyID = \"callSign\"");
$stmt->bindValue(":value", "KEEPME", SQLITE3_TEXT);
$stmt->execute();
if ($sqlite->changes() !== 1) {
	fwrite(STDERR, "FAIL: stock callSign row was missing\n");
	exit(1);
}
$users = (int)$sqlite->querySingle("SELECT COUNT(*) FROM users");
$settings = (int)$sqlite->querySingle("SELECT COUNT(*) FROM settings");
$ports = (int)$sqlite->querySingle("SELECT COUNT(*) FROM ports");
$modules = (int)$sqlite->querySingle("SELECT COUNT(*) FROM modules");
if ($users !== 1 || $settings < 1 || $ports < 1 || $modules < 1) {
	fwrite(STDERR, "FAIL: fixture database is missing account or configuration rows\n");
	exit(1);
}
file_put_contents($argv[3], $hash);
' "$ROOT_DIR" "$db" "$tmp/account.hash"
echo "ok: missing Memcached extension is not an OpenRepeater class-file fatal"

export ORP_DB_PATH="$db"
unset ORP_FLAG_STORE || true
export ORP_BENCH_TEST_HARNESS=1
export ORP_BENCH_MARKER="$marker"
export ORP_BENCH_HOSTNAME_FILE="$hostfile"
export ORP_BENCH_PREVIEW="$preview"
export ORP_COMMAND_LOG="$cmdlog"
export PATH="$bindir:$PATH"

php -S 127.0.0.1:${port} -t "$ROOT_DIR" >"$serverlog" 2>&1 &
server=$!

ready=0
for _ in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15; do
	if curl -sf -o /dev/null "http://127.0.0.1:${port}/login.php"; then
		ready=1
		break
	fi
	sleep 0.2
done
if [ "$ready" -ne 1 ]; then
	echo "FAIL: wizard test server did not start" >&2
	cat "$serverlog" >&2 || true
	exit 1
fi

snapshot_live() {
	local out=$1
	: > "$out"
	local p
	for p in /etc/svxlink /usr/share/svxlink /usr/local/share/svxlink /usr/local/bin/svxlink /etc/openrepeater/svxlink; do
		if [ -e "$p" ] || [ -L "$p" ]; then
			find -P "$p" -printf '%p %y %s\n' 2>/dev/null | sort >> "$out" || true
		else
			printf 'missing %s\n' "$p" >> "$out"
		fi
	done
}

assert_no_memcached_error() {
	local file=$1
	if grep -q 'File Not Found:' "$file" || grep -q 'Memcached.php' "$file"; then
		echo "FAIL: response still reports a missing Memcached class file" >&2
		cat "$file" >&2
		exit 1
	fi
}

assert_no_radio() {
	if grep -E -q 'gpio_up|gpio_down|svxlink start|unmask|set_mixer|gpioset|gpioget|systemctl' "$cmdlog"; then
		echo "FAIL: a radio or service command was issued" >&2
		cat "$cmdlog" >&2
		exit 1
	fi
}

snapshot_live "$live_before"

anon=$(curl -s -D - -o /dev/null "http://127.0.0.1:${port}/wizard/index.php")
printf '%s\n' "$anon" | grep -q '302'
printf '%s\n' "$anon" | grep -q 'login.php'
echo "ok: anonymous wizard redirects to login"

login_page=$(curl -s -c "$jar" -b "$jar" "http://127.0.0.1:${port}/login.php")
login_token=$(http_token "$login_page")
headers=$(curl -s -D - -c "$jar" -b "$jar" -o /dev/null \
	--data-urlencode 'username=admin' \
	--data-urlencode 'password=bench-only-test' \
	--data-urlencode "csrf_token=${login_token}" \
	"http://127.0.0.1:${port}/login.php")
printf '%s\n' "$headers" | grep -q '302'
printf '%s\n' "$headers" | grep -q 'dashboard.php'
echo "ok: auth fixture opens a session"

page=$(curl -s -b "$jar" -c "$jar" "http://127.0.0.1:${port}/wizard/index.php")
token=$(http_token "$page")
if [ -z "$token" ]; then
	echo "FAIL: wizard page did not render a CSRF token" >&2
	exit 1
fi
assert_no_memcached_error <(printf '%s' "$page")
printf '%s' "$page" | grep -q 'Step 1 of 5'
if printf '%s' "$page" | grep -q 'Session name cannot be changed'; then
	echo "FAIL: wizard still warns about session_name" >&2
	exit 1
fi
echo "ok: authenticated wizard starts without a session_name warning"

page=$(curl -s -b "$jar" -c "$jar" \
	--data-urlencode 'process_page=wizard_page1' \
	--data-urlencode 'page=wizard_page2' \
	--data-urlencode 'agree=yes' \
	--data-urlencode "csrf_token=${token}" \
	"http://127.0.0.1:${port}/wizard/index.php")
assert_no_memcached_error <(printf '%s' "$page")
printf '%s' "$page" | grep -q 'Step 2 of 5'

page=$(curl -s -b "$jar" -c "$jar" \
	--data-urlencode 'process_page=wizard_page2' \
	--data-urlencode 'page=wizard_page3' \
	--data-urlencode 'callSign=W8TEST' \
	--data-urlencode "csrf_token=${token}" \
	"http://127.0.0.1:${port}/wizard/index.php")
assert_no_memcached_error <(printf '%s' "$page")
printf '%s' "$page" | grep -q 'Step 3 of 5'
printf '%s' "$page" | grep -q 'Manual Configuration'

page=$(curl -s -b "$jar" -c "$jar" \
	--data-urlencode 'process_page=wizard_page3' \
	--data-urlencode 'page=wizard_confirmation' \
	--data-urlencode 'board_id=manual' \
	--data-urlencode 'portLabel=Port 1' \
	--data-urlencode 'rxMode=gpio' \
	--data-urlencode 'rxGPIO=23' \
	--data-urlencode 'rxGPIO_active=high' \
	--data-urlencode 'rxAudioDev=' \
	--data-urlencode 'txGPIO=26' \
	--data-urlencode 'txGPIO_active=low' \
	--data-urlencode 'txAudioDev=' \
	--data-urlencode "csrf_token=${token}" \
	"http://127.0.0.1:${port}/wizard/index.php")
assert_no_memcached_error <(printf '%s' "$page")
printf '%s' "$page" | grep -q 'Step 4 of 5'
printf '%s' "$page" | grep -q 'W8TEST'
printf '%s' "$page" | grep -q 'Save Configuration'
echo "ok: wizard reaches the Save button with the posted call sign"

save_headers="$tmp/save.headers"
save_body="$tmp/save.body"
curl -s -D "$save_headers" -o "$save_body" -b "$jar" -c "$jar" \
	--data-urlencode 'process_page=wizard_update' \
	--data-urlencode 'page=wizard_complete' \
	--data-urlencode "csrf_token=${token}" \
	"http://127.0.0.1:${port}/wizard/index.php"
assert_no_memcached_error "$save_body"
if grep -q 'HTTP/1.1 302' "$save_headers" || grep -q 'svxlink_update.php' "$save_headers"; then
	echo "FAIL: Save redirected into config generation" >&2
	cat "$save_headers" >&2
	exit 1
fi
grep -q 'HTTP/1.1 200' "$save_headers"
grep -q 'Step 5 of 5' "$save_body"
grep -q 'Finish & Logout' "$save_body"
if find "$preview" -type f | grep -q .; then
	echo "FAIL: Save wrote a preview config" >&2
	find "$preview" -type f >&2
	exit 1
fi
snapshot_live "$live_after_save"
if ! cmp -s "$live_before" "$live_after_save"; then
	echo "FAIL: Save changed a live SvxLink path" >&2
	diff -u "$live_before" "$live_after_save" >&2 || true
	exit 1
fi
php -r '
$sqlite = new SQLite3($argv[1]);
$expected = trim(file_get_contents($argv[2]));
$row = $sqlite->querySingle("SELECT password, salt FROM users WHERE username = \"admin\"", true);
$actual = hash("sha256", "testhost" . hash("sha256", "bench-only-test"));
if (!is_array($row) || !isset($row["password"]) || $row["password"] !== $actual || $row["password"] !== $expected) {
	fwrite(STDERR, "FAIL: Save changed the account credential\n");
	exit(1);
}
if ((int)$sqlite->querySingle("SELECT COUNT(*) FROM users") !== 1) {
	fwrite(STDERR, "FAIL: Save changed the account row count\n");
	exit(1);
}
$call = $sqlite->querySingle("SELECT value FROM settings WHERE keyID = \"callSign\"");
if ($call !== "W8TEST") {
	fwrite(STDERR, "FAIL: Save did not persist the call sign\n");
	exit(1);
}
if ((int)$sqlite->querySingle("SELECT COUNT(*) FROM settings") < 1) {
	fwrite(STDERR, "FAIL: Save removed settings\n");
	exit(1);
}
if ((int)$sqlite->querySingle("SELECT COUNT(*) FROM ports") !== 1) {
	fwrite(STDERR, "FAIL: Save did not leave the posted port\n");
	exit(1);
}
$tx = $sqlite->querySingle("SELECT txGPIO FROM ports");
if ((string)$tx !== "26") {
	fwrite(STDERR, "FAIL: Save persisted TX pin " . (string)$tx . "\n");
	exit(1);
}
if ((int)$sqlite->querySingle("SELECT COUNT(*) FROM modules") !== 3) {
	fwrite(STDERR, "FAIL: Save did not leave the module rows\n");
	exit(1);
}
$flag = $sqlite->querySingle("SELECT value FROM system_flags WHERE keyID = \"update_settings_flag\"");
if ($flag !== "1") {
	fwrite(STDERR, "FAIL: Save did not record the sqlite rebuild flag\n");
	exit(1);
}
' "$db" "$tmp/account.hash"
assert_no_radio
echo "ok: Save persists settings and does not write radio config"

finish_headers="$tmp/finish.headers"
finish_body="$tmp/finish.body"
curl -s -D "$finish_headers" -o "$finish_body" -b "$jar" -c "$jar" \
	--data-urlencode 'process_page=wizard_complete' \
	--data-urlencode 'page=wizard_complete' \
	--data-urlencode "csrf_token=${token}" \
	"http://127.0.0.1:${port}/wizard/index.php"
assert_no_memcached_error "$finish_body"
grep -q 'HTTP/1.1 200' "$finish_headers"
grep -q 'svxlink_update.php' "$finish_body"
finish_token=$(http_token "$(cat "$finish_body")")
echo "ok: Finish posts to the bench update route"

rebuild_headers="$tmp/rebuild.headers"
rebuild_body="$tmp/rebuild.body"
curl -s -D "$rebuild_headers" -o "$rebuild_body" -b "$jar" -c "$jar" \
	--data-urlencode "csrf_token=${finish_token}" \
	"http://127.0.0.1:${port}/functions/svxlink_update.php"
assert_no_memcached_error "$rebuild_body"
grep -q 'HTTP/1.1 302' "$rebuild_headers"
grep -q 'login.php' "$rebuild_headers"
if ! grep -Eq 'bench_preview_ok=1|preview_failed=1' "$rebuild_headers"; then
	echo "FAIL: finish response was not a bench redirect" >&2
	cat "$rebuild_headers" >&2
	exit 1
fi
snapshot_live "$live_after_finish"
if ! cmp -s "$live_before" "$live_after_finish"; then
	echo "FAIL: finish changed a live SvxLink path" >&2
	diff -u "$live_before" "$live_after_finish" >&2 || true
	exit 1
fi
php -r '
$sqlite = new SQLite3($argv[1]);
if ((int)$sqlite->querySingle("SELECT COUNT(*) FROM users") !== 1) {
	fwrite(STDERR, "FAIL: finish removed the account\n");
	exit(1);
}
if ($sqlite->querySingle("SELECT value FROM settings WHERE keyID = \"callSign\"") !== "W8TEST") {
	fwrite(STDERR, "FAIL: finish removed the saved call sign\n");
	exit(1);
}
if ((int)$sqlite->querySingle("SELECT COUNT(*) FROM ports") !== 1) {
	fwrite(STDERR, "FAIL: finish removed the port row\n");
	exit(1);
}
if ((int)$sqlite->querySingle("SELECT COUNT(*) FROM modules") !== 3) {
	fwrite(STDERR, "FAIL: finish removed the module rows\n");
	exit(1);
}
$actual = hash("sha256", "testhost" . hash("sha256", "bench-only-test"));
$stored = $sqlite->querySingle("SELECT password FROM users WHERE username = \"admin\"");
if ($stored !== $actual) {
	fwrite(STDERR, "FAIL: finish changed the account credential\n");
	exit(1);
}
' "$db"
assert_no_radio
if grep -E -q 'PHP Warning:|Session name cannot be changed|Memcached\.php' "$serverlog"; then
	echo "FAIL: wizard request log still contains a warning or Memcached file error" >&2
	cat "$serverlog" >&2
	exit 1
fi
echo "ok: finish stays off the radio and keeps the saved account and settings"
echo "wizard save checks passed"
