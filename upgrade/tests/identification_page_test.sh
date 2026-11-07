#!/bin/bash
# Identification page must finish rendering when the audio library is missing,
# and the generated schedule must carry the stored call sign at a legal Morse
# speed. No station grant is inferred and no radio is started.
set -euo pipefail

ROOT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
# shellcheck source=lib/http_session.sh
. "$ROOT_DIR/upgrade/tests/lib/http_session.sh"
tmp=$(mktemp -d)
db="$tmp/openrepeater.db"
preview=$(mktemp -d "${TMPDIR:-/tmp}/orp-preview-id.XXXXXX")
audio=$(mktemp -d "${TMPDIR:-/tmp}/orp-audio.XXXXXX")
marker="$tmp/bench-mode"
hostfile="$tmp/hostname"
jar="$tmp/cookies"
serverlog="$tmp/server.log"
port=8768
server=

cleanup() {
	if [ -n "${server:-}" ]; then
		kill "$server" >/dev/null 2>&1 || true
		wait "$server" 2>/dev/null || true
	fi
	rm -rf "$tmp" "$preview" "$audio"
}
trap cleanup EXIT

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
$stmt = $db->prepare("UPDATE settings SET value = :value WHERE keyID = :key");
$set = function ($key, $value) use ($db, $stmt) {
	$stmt->bindValue(":key", $key, SQLITE3_TEXT);
	$stmt->bindValue(":value", $value, SQLITE3_TEXT);
	$stmt->execute();
	if ($db->changes() !== 1) {
		fwrite(STDERR, "FAIL: fixture could not set {$key}\n");
		exit(1);
	}
};
$set("callSign", "FIXTURE");
$set("rxTone", "100.0");
$set("txTone", "88.5");
' "$db"
printf 'orp-test\n' > "$hostfile"
: > "$marker"
mkdir -p "$audio/identification" "$audio/courtesy_tones"
printf 'keep\n' > "$tmp/canary"

php -r '
$_SERVER["DOCUMENT_ROOT"] = $argv[1];
require $argv[1] . "/includes/classes/AudioFiles.php";
require $argv[1] . "/includes/classes/SVXLink.php";
require $argv[1] . "/includes/classes/SVXLink_TCL.php";
require $argv[1] . "/includes/classes/BenchGuard.php";
function fail($msg) { fwrite(STDERR, "FAIL: {$msg}\n"); exit(1); }
$missing = new AudioFiles();
if ($missing->get_audio_files("identification") !== array()) {
	fail("missing native audio directory did not list as empty");
}
putenv("ORP_AUDIO_PATH=" . $argv[2]);
$empty = new AudioFiles();
if ($empty->get_audio_files("identification") !== array() || $empty->get_audio_files("courtesy_tones") !== array()) {
	fail("empty audio directories did not list as empty");
}
file_put_contents($argv[2] . "/identification/Clip_One.wav", "RIFF");
$listed = $empty->get_audio_files("identification");
if (count($listed) !== 1 || $listed[0]["fileName"] !== "Clip_One.wav") {
	fail("a regular clip was not listed");
}
$secret = $argv[3] . "/secret-audio";
mkdir($secret);
file_put_contents($secret . "/hidden.wav", "secret");
symlink($secret, $argv[2] . "/linked");
$linked = new AudioFiles();
if ($linked->get_audio_files("linked") !== array()) {
	fail("a symlinked audio directory was listed");
}
$rename = $empty->audio_rename_file("identification", "../canary", "stolen");
if ($rename["msgType"] !== "error" || file_get_contents($argv[3] . "/canary") !== "keep\n") {
	fail("rename followed a path outside the library");
}
$delete = $empty->audio_delete_files("identification", array("../canary"));
if ($delete["msgType"] !== "error" || file_get_contents($argv[3] . "/canary") !== "keep\n") {
	fail("delete followed a path outside the library");
}
if (!is_file($argv[2] . "/identification/Clip_One.wav")) {
	fail("library clip was removed by the rejected operations");
}
echo "ok: missing, empty, and linked audio libraries do not fatal or escape\n";

$db = new SQLite3($argv[4]);
$settings = array();
$res = $db->query("SELECT keyID, value FROM settings");
while ($row = $res->fetchArray(SQLITE3_ASSOC)) { $settings[$row["keyID"]] = $row["value"]; }
if ($settings["callSign"] !== "FIXTURE" || $settings["ID_Morse_WPM"] !== "25" || $settings["rxTone"] !== "100.0") {
	fail("fixture settings were not intact before generation");
}
putenv("ORP_BENCH_TEST_HARNESS=1");
putenv("ORP_BENCH_MARKER=" . $argv[5]);
putenv("ORP_BENCH_HOSTNAME_FILE=" . $argv[6]);
putenv("ORP_BENCH_PREVIEW=" . $argv[7]);
$blocked = new SVXLink($settings, array(), array());
$blocked->build_logic_repeater("ORP_RepeaterLogic_Port1", 1);
if ($blocked->write_config($blocked->build_logic_repeater("ORP_RepeaterLogic_Port1", 1), "svxlink.conf", "ini") !== false) {
	fail("25 WPM Morse and the stock speed were published");
}
if (file_exists($argv[7] . "/svxlink.conf")) {
	fail("refused identification still wrote svxlink.conf");
}
$again = $db->querySingle("SELECT value FROM settings WHERE keyID=\"ID_Morse_WPM\"");
$call = $db->querySingle("SELECT value FROM settings WHERE keyID=\"callSign\"");
$tone = $db->querySingle("SELECT value FROM settings WHERE keyID=\"rxTone\"");
$timeout = $db->querySingle("SELECT value FROM settings WHERE keyID=\"repeaterTimeoutSec\"");
if ($again !== "25" || $call !== "FIXTURE" || $tone !== "100.0" || $timeout !== "230") {
	fail("refused publish changed stored speed, call sign, tone, or repeater timeout");
}
echo "ok: Morse above 20 WPM is not published and stored settings stay put\n";

$settings["ID_Morse_WPM"] = "20";
$good = new SVXLink($settings, array(), array(array("moduleEnabled" => 1, "svxlinkName" => "Help", "svxlinkID" => "0", "moduleOptions" => "")));
$logic = $good->build_logic_repeater("ORP_RepeaterLogic_Port1", 1);
if ($good->write_config($logic, "svxlink.conf", "ini") !== true) {
	fail("legal Morse schedule was not written: " . implode("; ", $good->identificationProblems()));
}
$ini = file_get_contents($argv[7] . "/svxlink.conf");
if (strpos($ini, "MODULES=ModuleHelp") === false || strpos($ini, "CALLSIGN=FIXTURE") === false || strpos($ini, "SHORT_IDENT_INTERVAL=5") === false) {
	fail("published config lost the stored call sign or 5 minute interval");
}
if (strpos($ini, "#SHORT_IDENT_INTERVAL") !== false || strpos($ini, "IDENT_ONLY_AFTER_TX=1") !== false) {
	fail("identification was commented out or deferred until after transmit");
}
if (strpos($ini, "LONG_IDENT_INTERVAL=240") === false) {
	fail("the supplemental long interval was not preserved");
}
if (strpos($ini, "TIMEOUT=180") !== false) {
	fail("the telecommand 3 minute limit was written as the normal repeater timeout");
}
$gaps = SVXLink::activeCommunicationIdGaps(5, 20 * 60);
if ($gaps !== array(300, 300, 300, 300)) {
	fail("config arithmetic for a 5 minute integer did not return four 300 second products");
}
$tcl = (new SVXLink_TCL($settings))->logic_override();
if (strpos($tcl, "CW::setWpm 20") === false || strpos($tcl, "CW::play \$mycall") === false || strpos($tcl, "CW::setWpm 25") !== false) {
	fail("generated Morse procedure did not use 20 WPM and the configured call sign");
}
$settings["ID_Morse_WPM"] = "25";
$settings["ID_Short_Mode"] = "voice";
$settings["ID_Short_AppendMorse"] = "False";
$settings["ID_Long_Mode"] = "disabled";
$voice = new SVXLink($settings, array(), array());
$voiceLogic = $voice->build_logic_repeater("ORP_RepeaterLogic_Port1", 1);
if ($voice->write_config($voiceLogic, "voice.conf", "ini") !== true) {
	fail("English voice identification was blocked because unused Morse speed was 25");
}
$voiceTcl = (new SVXLink_TCL($settings))->logic_override();
if (strpos($voiceTcl, "spellWord \$mycall") === false || strpos($voiceTcl, "CW::setWpm 25") !== false) {
	fail("voice identification did not spell the call sign or still emitted 25 WPM Morse");
}
$settings["ID_Short_IntervalMin"] = "11";
$settings["ID_Short_Mode"] = "morse";
$settings["ID_Morse_WPM"] = "20";
$late = new SVXLink($settings, array(), array());
$late->build_logic_repeater("ORP_RepeaterLogic_Port1", 1);
if ($late->write_config($late->build_logic_repeater("ORP_RepeaterLogic_Port1", 1), "late.conf", "ini") !== false) {
	fail("an 11 minute interval was published");
}
if (file_exists($argv[7] . "/late.conf")) fail("late.conf was written");
$settings["callSign"] = "FIXTURE";
$settings["ID_Short_IntervalMin"] = "5";
$settings["ID_Short_Mode"] = "morse";
$settings["ID_Morse_WPM"] = "20";
$settings["ID_Long_Mode"] = "disabled";
$settings["ID_Short_IdentOnlyAfterTX"] = "True";
$defer = new SVXLink($settings, array(), array());
if ($defer->identificationProblems() !== array()) {
	fail("identify-only-after-transmit was treated as a publish error: " . implode("; ", $defer->identificationProblems()));
}
if ($defer->write_config($defer->build_logic_repeater("ORP_RepeaterLogic_Port1", 1), "defer.conf", "ini") !== true) {
	fail("SvxLink IDENT_ONLY_AFTER_TX=1 was refused");
}
$deferIni = file_get_contents($argv[7] . "/defer.conf");
if (strpos($deferIni, "IDENT_ONLY_AFTER_TX=1") === false || strpos($deferIni, "SHORT_IDENT_INTERVAL=5") === false || strpos($deferIni, "CALLSIGN=FIXTURE") === false) {
	fail("published ident-only-after-tx config did not keep minutes and the stored call sign");
}
echo "ok: config integer is not SvxLink event timing; IDENT_ONLY_AFTER_TX=1 is published in minutes\n";
' "$ROOT_DIR" "$audio" "$tmp" "$db" "$marker" "$hostfile" "$preview"

export ORP_DB_PATH="$db"
unset ORP_FLAG_STORE || true
unset ORP_AUDIO_PATH || true
export ORP_BENCH_TEST_HARNESS=1
export ORP_BENCH_MARKER="$marker"
export ORP_BENCH_HOSTNAME_FILE="$hostfile"
export ORP_BENCH_PREVIEW="$preview"

php -S 127.0.0.1:${port} -t "$ROOT_DIR" >"$serverlog" 2>&1 &
server=$!
ready=0
for _ in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15; do
	if curl -sf -o /dev/null "http://127.0.0.1:${port}/login.php"; then ready=1; break; fi
	sleep 0.2
done
if [ "$ready" -ne 1 ]; then
	echo "FAIL: identification server did not start" >&2
	cat "$serverlog" >&2 || true
	exit 1
fi

login_page=$(curl -s -c "$jar" -b "$jar" "http://127.0.0.1:${port}/login.php")
login_token=$(http_token "$login_page")
curl -s -c "$jar" -b "$jar" -o /dev/null \
	--data-urlencode 'username=admin' \
	--data-urlencode 'password=bench-only-test' \
	--data-urlencode "csrf_token=${login_token}" \
	"http://127.0.0.1:${port}/login.php"

assert_complete() {
	local name=$1 file=$2 needle=$3
	if ! grep -q '</html>' "$file"; then
		echo "FAIL: ${name} returned a truncated document" >&2
		exit 1
	fi
	if ! grep -q "$needle" "$file"; then
		echo "FAIL: ${name} did not render ${needle}" >&2
		exit 1
	fi
	if grep -q 'natsort()' "$file" || grep -q 'File Not Found:' "$file"; then
		echo "FAIL: ${name} body contains a fatal marker" >&2
		exit 1
	fi
}

curl -s -b "$jar" -o "$tmp/identification.html" "http://127.0.0.1:${port}/identification.php"
assert_complete identification "$tmp/identification.html" 'ID_Long_Mode'
grep -q 'ID_Short_Mode' "$tmp/identification.html"
grep -q 'No Audio Files to Display' "$tmp/identification.html"
grep -q '47 CFR 97.119(b)(1)' "$tmp/identification.html"
grep -q 'identification_problems' "$tmp/identification.html"
echo "ok: identification.php finishes with the long ID control when the audio directory is absent"

curl -s -b "$jar" -o "$tmp/courtesy.html" "http://127.0.0.1:${port}/courtesy_tone.php"
assert_complete courtesy "$tmp/courtesy.html" 'courtesyMode'
grep -q 'No Audio Files to Display' "$tmp/courtesy.html"
echo "ok: courtesy_tone.php finishes when the audio directory is absent"

curl -s -b "$jar" -o "$tmp/settings.html" "http://127.0.0.1:${port}/settings.php"
assert_complete settings "$tmp/settings.html" 'rxCtcssOpenThresh'
grep -q 'rxCtcssCloseThresh' "$tmp/settings.html"
grep -q 'txCtcssLevel' "$tmp/settings.html"
php -r '
$db = new SQLite3($argv[1]);
$expect = array(
	"callSign" => "FIXTURE",
	"rxTone" => "100.0",
	"txTone" => "88.5",
	"repeaterTimeoutSec" => "230",
	"rxCtcssOpenThresh" => "10",
	"rxCtcssCloseThresh" => "5",
	"txCtcssLevel" => "9",
);
foreach ($expect as $key => $value) {
	$got = $db->querySingle("SELECT value FROM settings WHERE keyID=\"".$key."\"");
	if ($got !== $value) {
		fwrite(STDERR, "FAIL: {$key} became " . var_export($got, true) . "\n");
		exit(1);
	}
}
' "$db"
echo "ok: settings GET inserted missing CTCSS default rows and left call sign and tones unchanged"
php -r '
$db = new SQLite3($argv[1]);
$stmt = $db->prepare("UPDATE settings SET value = :value WHERE keyID = \"rxCtcssOpenThresh\"");
$stmt->bindValue(":value", "22", SQLITE3_TEXT);
$stmt->execute();
' "$db"
curl -s -b "$jar" -o "$tmp/settings-again.html" "http://127.0.0.1:${port}/settings.php"
grep -q 'value="22"' "$tmp/settings-again.html"
php -r '
$db = new SQLite3($argv[1]);
$expect = array(
	"callSign" => "FIXTURE",
	"rxTone" => "100.0",
	"txTone" => "88.5",
	"rxCtcssOpenThresh" => "22",
	"rxCtcssCloseThresh" => "5",
	"txCtcssLevel" => "9",
);
foreach ($expect as $key => $value) {
	$got = $db->querySingle("SELECT value FROM settings WHERE keyID=\"".$key."\"");
	if ($got !== $value) {
		fwrite(STDERR, "FAIL: second settings GET changed {$key} to " . var_export($got, true) . "\n");
		exit(1);
	}
}
' "$db"
echo "ok: second settings GET is idempotent and preserves an existing CTCSS threshold"

curl -s -b "$jar" -o "$tmp/modules.html" "http://127.0.0.1:${port}/modules.php"
assert_complete modules "$tmp/modules.html" 'action="/modules.php"'
echo "ok: module upload and delete forms post back to modules.php"

if grep -E -q 'PHP (Warning|Fatal)|natsort\(\)|Failed to open directory|Undefined array key' "$serverlog"; then
	echo "FAIL: page log still contains the audio fatal or settings warning" >&2
	cat "$serverlog" >&2
	exit 1
fi
echo "identification page checks passed"
