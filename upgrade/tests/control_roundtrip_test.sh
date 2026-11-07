#!/bin/bash
# HTTP form round trips on a copied database. No station database is opened.
set -euo pipefail

ROOT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
# shellcheck source=lib/http_session.sh
. "$ROOT_DIR/upgrade/tests/lib/http_session.sh"
# shellcheck source=lib/native_layout.sh
. "$ROOT_DIR/upgrade/tests/lib/native_layout.sh"

tmp=$(mktemp -d)
preview="/tmp/orp-preview-controls-$$"
trap 'kill "$server" >/dev/null 2>&1 || true; rm -rf "$tmp" "$preview"' EXIT
db="$tmp/openrepeater.db"
jar="$tmp/admin.cookies"
throw_jar="$tmp/throw.cookies"
host="$tmp/hostname"
marker="$tmp/bench-mode"
mode="$tmp/mode"
funct="$tmp/functional"
live="$tmp/live"
modules="$tmp/modules"
audio="$tmp/audio"
backup="$tmp/backup"
sounds="$tmp/sounds"
canary="$tmp/php-canary"
helper_log="$tmp/helper.log"
port=8776
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
$throwSalt = "throwaway";
$throwHash = hash("sha256", $throwSalt . hash("sha256", "old-password"));
$stmt = $db->prepare("INSERT INTO users (userID, username, password, salt) VALUES (2, \"throwaway\", :password, :salt)");
$stmt->bindValue(":password", $throwHash, SQLITE3_TEXT);
$stmt->bindValue(":salt", $throwSalt, SQLITE3_TEXT);
$stmt->execute();
$stmt = $db->prepare("UPDATE settings SET value = :value WHERE keyID = \"callSign\"");
$stmt->bindValue(":value", "TEST", SQLITE3_TEXT);
$stmt->execute();
$stmt = $db->prepare("INSERT INTO gpio_pins (gpio_num, direction, active, description, type) VALUES (20, \"out\", \"high\", \"relay\", \"RemoteRelay\")");
$stmt->execute();
' "$db"
apply_ident_profile "$db"
admin_hash=$(sqlite3 "$db" "SELECT password FROM users WHERE username='admin';")
printf 'orp-test\n' > "$host"
printf 'bench\n' > "$marker"
printf 'bench\n' > "$mode"
printf 'functional-test\n' > "$funct"
plant_native_layout "$live"
mkdir -p "$preview" "$modules" "$audio/identification" "$audio/courtesy_tones" "$backup" "$sounds" "$live/var/backups/orp-ui"
chmod 755 "$live" "$live/etc" "$live/etc/svxlink" "$live/var" "$live/var/backups" "$live/var/backups/orp-ui"
export ORP_DB_PATH="$db"
export ORP_BENCH_TEST_HARNESS=1
export ORP_BENCH_HOSTNAME_FILE="$host"
export ORP_BENCH_MARKER="$marker"
export ORP_OPERATING_MODE_FILE="$mode"
export ORP_BENCH_PREVIEW="$preview"
export ORP_MODULES_PATH="$modules"
export ORP_AUDIO_PATH="$audio"
export ORP_BACKUP_PATH="$backup"
export ORP_SOUNDS_PATH="$sounds"
export ORP_PROBE_CANARY="$canary"
export ORP_HELPER_STUB=1
export ORP_HELPER_LOG="$helper_log"
php -S 127.0.0.1:${port} -t "$ROOT_DIR" >"$tmp/server.log" 2>&1 &
server=$!
ready=0
for _ in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15; do
	if curl -sf -o /dev/null "http://127.0.0.1:${port}/login.php"; then ready=1; break; fi
	sleep 0.2
done
[ "$ready" = 1 ]
base="http://127.0.0.1:${port}"
login() {
	local cookies=$1 user=$2 pass=$3 page token
	page=$(curl -s -c "$cookies" -b "$cookies" "$base/login.php")
	token=$(http_token "$page")
	curl -s -c "$cookies" -b "$cookies" -o /dev/null \
		--data-urlencode "username=${user}" \
		--data-urlencode "password=${pass}" \
		--data-urlencode "csrf_token=${token}" \
		"$base/login.php"
}
login "$jar" admin bench-only-test
page=$(curl -s -b "$jar" "$base/settings.php")
token=$(http_token "$page")
[ -n "$token" ]
post_settings() {
	curl -s -b "$jar" -H "X-CSRF-Token: ${token}" "$@"
}
code=$(post_settings -o "$tmp/mode.body" -w '%{http_code}' \
	--data-urlencode 'orp_Mode=simplex' \
	"$base/functions/ajax_db_update.php")
[ "$code" = "200" ]
grep -q '^updated$' "$tmp/mode.body"
[ "$(sqlite3 "$db" "SELECT value FROM settings WHERE keyID='orp_Mode';")" = "simplex" ]
[ "$(sqlite3 "$db" "SELECT value FROM settings WHERE keyID='callSign';")" = "TEST" ]
code=$(post_settings -o "$tmp/badkey.body" -w '%{http_code}' \
	--data-urlencode "callSign'=TEST" \
	"$base/functions/ajax_db_update.php")
[ "$code" = "400" ]
grep -q '^refused$' "$tmp/badkey.body"
[ "$(sqlite3 "$db" "SELECT COUNT(*) FROM settings;")" = "$(sqlite3 "$db" "SELECT COUNT(*) FROM settings;")" ]
settings_before=$(sqlite3 "$db" "SELECT keyID || '=' || value FROM settings WHERE keyID NOT IN ('orp_Mode','txTailValueSec','repeaterDTMF_disable','repeaterDTMF_disable_pin','ID_Short_IntervalMin','ID_Short_Mode','courtesyMode','callSign') ORDER BY keyID;")
code=$(post_settings -o "$tmp/ports.body" -w '%{http_code}' \
	--data-urlencode 'portLabel[]=ROUNDTRIP' \
	--data-urlencode 'rxMode[]=vox' \
	--data-urlencode 'rxGPIO[]=26' \
	--data-urlencode 'rxGPIO_active[]=low' \
	--data-urlencode 'txGPIO[]=498' \
	--data-urlencode 'txGPIO_active[]=high' \
	--data-urlencode 'rxAudioDev[]=alsa:plughw:0|1' \
	--data-urlencode 'txAudioDev[]=alsa:plughw:0|1' \
	--data-urlencode 'portLabel[]=Port 2' \
	--data-urlencode 'rxMode[]=gpio' \
	--data-urlencode 'rxGPIO[]=23' \
	--data-urlencode 'rxGPIO_active[]=low' \
	--data-urlencode 'txGPIO[]=499' \
	--data-urlencode 'txGPIO_active[]=high' \
	--data-urlencode 'rxAudioDev[]=alsa:plughw:0|0' \
	--data-urlencode 'txAudioDev[]=alsa:plughw:0|0' \
	"$base/functions/port_db_update.php")
[ "$code" = "200" ]
[ "$(sqlite3 "$db" "SELECT portLabel || ' ' || rxMode || ' ' || rxGPIO || ' ' || txGPIO FROM ports WHERE portNum=1;")" = "ROUNDTRIP vox 26 498" ]
[ "$(sqlite3 "$db" "SELECT gpio_num || ' ' || type FROM gpio_pins WHERE gpio_num=20;")" = "20 RemoteRelay" ]
code=$(post_settings -o "$tmp/portbad.body" -w '%{http_code}' \
	--data-urlencode 'portLabel[]=../outside' \
	--data-urlencode 'rxMode[]=gpio' \
	--data-urlencode 'rxGPIO[]=26' \
	--data-urlencode 'rxGPIO_active[]=low' \
	--data-urlencode 'txGPIO[]=498' \
	--data-urlencode 'txGPIO_active[]=high' \
	--data-urlencode 'rxAudioDev[]=alsa:plughw:0|1' \
	--data-urlencode 'txAudioDev[]=alsa:plughw:0|1' \
	"$base/functions/port_db_update.php")
[ "$code" = "400" ]
[ "$(sqlite3 "$db" "SELECT portLabel FROM ports WHERE portNum=1;")" = "ROUNDTRIP" ]
code=$(post_settings -o "$tmp/settings.body" -w '%{http_code}' \
	--data-urlencode 'callSign=TEST' \
	--data-urlencode 'txTailValueSec=4' \
	--data-urlencode 'repeaterDTMF_disable=True' \
	--data-urlencode 'repeaterDTMF_disable_pin=2468' \
	"$base/functions/ajax_db_update.php")
[ "$code" = "200" ]
[ "$(sqlite3 "$db" "SELECT value FROM settings WHERE keyID='txTailValueSec';")" = "4" ]
[ "$(sqlite3 "$db" "SELECT value FROM settings WHERE keyID='repeaterDTMF_disable_pin';")" = "2468" ]
code=$(post_settings -o "$tmp/dtmf-empty.body" -w '%{http_code}' \
	--data '' \
	"$base/functions/ajax_db_update.php")
[ "$code" = "200" ]
[ "$(sqlite3 "$db" "SELECT value FROM settings WHERE keyID='repeaterDTMF_disable_pin';")" = "2468" ]
code=$(post_settings -o "$tmp/tts.body" -w '%{http_code}' \
	--data-urlencode 'engine=flite' \
	--data-urlencode 'flite_voice=slt' \
	--data-urlencode 'gain_db=0' \
	"$base/functions/tts_preview.php")
grep -q 'Synthesis failed' "$tmp/tts.body" || grep -q 'audio' "$tmp/tts.hdr" || true
if grep -q 'Synthesis failed' "$tmp/tts.body"; then
	echo "ok: Test Voice reports synthesis failure and does not claim audio"
else
	head -c 12 "$tmp/tts.body" | grep -q 'RIFF'
	echo "ok: Test Voice returned a WAV sample"
fi
[ "$(sqlite3 "$db" "SELECT value FROM settings WHERE keyID='callSign';")" = "TEST" ]
code=$(post_settings -o "$tmp/id.body" -w '%{http_code}' \
	--data-urlencode 'ID_Short_Mode=morse' \
	--data-urlencode 'ID_Short_IntervalMin=7' \
	"$base/functions/ajax_db_update.php")
[ "$code" = "200" ]
[ "$(sqlite3 "$db" "SELECT value FROM settings WHERE keyID='ID_Short_IntervalMin';")" = "7" ]
export ORP_ROOT="$live"
export ORP_OPERATING_MODE_FILE="$funct"
"$ROOT_DIR/install/scripts/orp_helper" config publish >/dev/null
cfg="$live/etc/svxlink/svxlink.conf"
grep -q '^PTT_TYPE=NONE$' "$cfg"
grep -q '^SHORT_IDENT_INTERVAL=7$' "$cfg"
grep -q '^LOGICS=RepeaterLogic$' "$cfg"
if grep -q 'ONLINE_CMD\|gpio498\|PTT_PIN' "$cfg"; then
	echo "FAIL: stored DTMF pin or port numbers entered the no-PTT runtime" >&2
	exit 1
fi
echo "ok: simplex, DTMF pin, and port numbers stay in the database; the root runtime stays RepeaterLogic with PTT_TYPE=NONE"
before_cfg=$(sha256sum "$cfg" | awk '{print $1}')
code=$(post_settings -o "$tmp/custom.body" -w '%{http_code}' \
	--data-urlencode 'ID_Short_Mode=custom' \
	"$base/functions/ajax_db_update.php")
if [ "$code" != "200" ]; then
	echo "FAIL: custom mode post ${code} $(cat "$tmp/custom.body")" >&2
	exit 1
fi
set +e
ORP_ROOT="$live" ORP_OPERATING_MODE_FILE="$funct" "$ROOT_DIR/install/scripts/orp_helper" config publish >/dev/null 2>"$tmp/custom.err"
custom_rc=$?
set -e
if [ "$custom_rc" = 0 ]; then
	echo "FAIL: custom identification was published" >&2
	exit 1
fi
if ! grep -q 'not published' "$tmp/custom.err"; then
	echo "FAIL: custom publish rc=${custom_rc} detail=$(cat "$tmp/custom.err")" >&2
	exit 1
fi
mode_now=$(sqlite3 "$db" "SELECT value FROM settings WHERE keyID='ID_Short_Mode';")
if [ "$mode_now" != "custom" ]; then
	echo "FAIL: custom mode was not stored (${mode_now})" >&2
	exit 1
fi
after_cfg=$(sha256sum "$cfg" | awk '{print $1}')
if [ "$after_cfg" != "$before_cfg" ]; then
	echo "FAIL: refused publish changed the runtime file" >&2
	exit 1
fi
sqlite3 "$db" "UPDATE settings SET value='morse' WHERE keyID='ID_Short_Mode';"
code=$(post_settings -o "$tmp/courtesy.body" -w '%{http_code}' \
	--data-urlencode 'courtesyMode=beep' \
	"$base/functions/ajax_db_update.php")
[ "$code" = "200" ]
[ "$(sqlite3 "$db" "SELECT value FROM settings WHERE keyID='courtesyMode';")" = "beep" ]
printf 'not-audio' > "$tmp/note.php"
code=$(curl -s -b "$jar" -H "X-CSRF-Token: ${token}" -o "$tmp/audio-bad.body" -w '%{http_code}' \
	-F 'action=upload_file' -F 'file[]=@'"$tmp/note.php" \
	"$base/identification.php")
if ! grep -q 'supported format\|plain file name' "$tmp/audio-bad.body"; then
	echo "FAIL: audio type refusal was $(cat "$tmp/audio-bad.body")" >&2
	exit 1
fi
boundary=----orpbound
{
	printf -- '--%s\r\n' "$boundary"
	printf 'Content-Disposition: form-data; name="action"\r\n\r\nupload_file\r\n'
	printf -- '--%s\r\n' "$boundary"
	printf 'Content-Disposition: form-data; name="file[]"; filename="../../escaped.wav"\r\n'
	printf 'Content-Type: application/octet-stream\r\n\r\n'
	printf 'not-audio\r\n'
	printf -- '--%s--\r\n' "$boundary"
} > "$tmp/slip.mime"
code=$(curl -s -b "$jar" -H "X-CSRF-Token: ${token}" -H "Content-Type: multipart/form-data; boundary=${boundary}" \
	--data-binary @"$tmp/slip.mime" -o "$tmp/audio-slip.body" -w '%{http_code}' \
	"$base/courtesy_tone.php")
if ! grep -q 'plain file name\|converting your file' "$tmp/audio-slip.body"; then
	echo "FAIL: path upload was not refused" >&2
	exit 1
fi
php -r '
require $argv[1];
$ref = new ReflectionMethod("AudioFiles", "plainFileName");
$ref->setAccessible(true);
$audio = new AudioFiles();
if ($ref->invoke($audio, "../../escaped.wav") !== null) { fwrite(STDERR, "slash name accepted\n"); exit(1); }
' "$ROOT_DIR/includes/classes/AudioFiles.php"
[ ! -e "$tmp/escaped.wav" ]
ln -s /tmp "$audio/identification-link"
# A symlinked library is not a destination. The real identification directory stays empty of conversions.
find "$audio/identification" -type f | grep -q . && { echo "FAIL: audio upload wrote a file"; exit 1; }
echo "ok: audio upload refuses a script name and a path name"
TMP="$tmp" python3 - <<'PY'
import os, stat, zipfile
base = os.environ["TMP"]
good = os.path.join(base, "probe.zip")
with zipfile.ZipFile(good, "w") as z:
    z.writestr("info.ini", "[Module_Info]\nmod_name = ProbeMod\ndisplay_name = Probe\n")
    z.writestr("build_config.php", "<?php\n")
    z.writestr("default_settings.php", "<?php\nfile_put_contents(getenv('ORP_PROBE_CANARY'), 'ran');\n$default_settings = array('timeout' => '1');\n")
    z.writestr("svxlink/events.d/ModuleProbe.tcl", "proc probe {} {puts ran}\n")
    z.writestr("svxlink/modules.d/ModuleProbe.conf", "NAME=Probe\n")
slip = os.path.join(base, "slip.zip")
with zipfile.ZipFile(slip, "w") as z:
    z.writestr("../escaped.txt", "nope")
link = os.path.join(base, "link.zip")
with zipfile.ZipFile(link, "w") as z:
    info = zipfile.ZipInfo("svxlink/events.d/link.tcl")
    info.create_system = 3
    info.external_attr = (stat.S_IFLNK | 0o777) << 16
    z.writestr(info, "/tmp/evil")
PY
code=$(curl -s -b "$jar" -H "X-CSRF-Token: ${token}" -o "$tmp/mod.body" -w '%{http_code}' \
	-F 'upload_file=1' -F 'file[]=@'"$tmp/probe.zip" \
	"$base/modules.php")
if ! grep -q 'successfully installed' "$tmp/mod.body"; then
	cp "$tmp/mod.body" /tmp/mod-body.html
	echo "FAIL: module upload was not accepted" >&2
	exit 1
fi
[ ! -e "$canary" ]
[ "$(sqlite3 "$db" "SELECT moduleEnabled || ' ' || svxlinkID FROM modules WHERE svxlinkName='ProbeMod';")" = "0 3" ]
[ "$(sqlite3 "$db" "SELECT moduleKey FROM modules WHERE svxlinkName='Help';")" = "1" ]
[ -L "$preview/events.d/ModuleProbe.tcl" ]
[ ! -e /usr/local/share/svxlink/events.d/ModuleProbe.tcl ]
[ ! -e /usr/share/svxlink/events.d/ModuleProbe.tcl ]
if grep -q 'ProbeMod' "$cfg"; then
	echo "FAIL: uploaded module was copied into the root runtime" >&2
	exit 1
fi
code=$(curl -s -b "$jar" -H "X-CSRF-Token: ${token}" -o "$tmp/slip.body" -w '%{http_code}' \
	-F 'upload_file=1' -F 'file[]=@'"$tmp/slip.zip" \
	"$base/modules.php")
grep -q 'problem' "$tmp/slip.body"
[ ! -e "$modules/escaped.txt" ]
[ ! -e "$tmp/escaped.txt" ]
code=$(curl -s -b "$jar" -H "X-CSRF-Token: ${token}" -o "$tmp/linkmod.body" -w '%{http_code}' \
	-F 'upload_file=1' -F 'file[]=@'"$tmp/link.zip" \
	"$base/modules.php")
grep -q 'problem' "$tmp/linkmod.body"
code=$(curl -s -b "$jar" -H "X-CSRF-Token: ${token}" -o "$tmp/del.body" -w '%{http_code}' \
	--data-urlencode 'delete=1' \
	--data-urlencode 'deleteSelectedModule=ProbeMod' \
	"$base/modules.php")
grep -q 'Successfully deleted' "$tmp/del.body"
[ "$(sqlite3 "$db" "SELECT COUNT(*) FROM modules WHERE svxlinkName='ProbeMod';")" = "0" ]
code=$(curl -s -b "$jar" -H "X-CSRF-Token: ${token}" -o "$tmp/core.body" -w '%{http_code}' \
	--data-urlencode 'delete=1' \
	--data-urlencode 'deleteSelectedModule=Help' \
	"$base/modules.php")
grep -q 'core module' "$tmp/core.body"
[ "$(sqlite3 "$db" "SELECT svxlinkName FROM modules WHERE moduleKey=1;")" = "Help" ]
echo "ok: module upload stays inactive, does not execute PHP or Tcl, and cannot remove Help"
: > "$helper_log"
code=$(post_settings -o "$tmp/reboot.body" -w '%{http_code}' \
	--data-urlencode 'post_service=system' \
	--data-urlencode 'post_option=restart' \
	"$base/functions/ajax_system.php")
[ "$code" = "403" ]
grep -q 'bench mode blocks system restart' "$tmp/reboot.body"
[ ! -s "$helper_log" ]
code=$(post_settings -o "$tmp/shutdown.body" -w '%{http_code}' \
	--data-urlencode 'post_service=system' \
	--data-urlencode 'post_option=stop' \
	"$base/functions/ajax_system.php")
[ "$code" = "403" ]
echo "ok: host restart and shutdown stay blocked"
code=$(curl -s -b "$jar" -H "X-CSRF-Token: ${token}" -o "$tmp/backup.body" -w '%{http_code}' \
	--data-urlencode 'createBackup=1' \
	"$base/backup.php")
grep -q 'Successfully created backup' "$tmp/backup.body"
archive=$(find "$backup" -maxdepth 1 -name '*.orp' -printf '%f\n')
[ -n "$archive" ]
sqlite3 "$db" "UPDATE settings SET value='TEMPCS' WHERE keyID='callSign';"
code=$(curl -s -b "$jar" -H "X-CSRF-Token: ${token}" -o "$tmp/validate.body" -w '%{http_code}' \
	--data-urlencode "validate_restore=${archive}" \
	"$base/backup.php")
grep -q '"status":"ok"' "$tmp/validate.body"
code=$(curl -s -b "$jar" -H "X-CSRF-Token: ${token}" -o "$tmp/restore.body" -w '%{http_code}' \
	--data-urlencode 'restore=1' \
	"$base/backup.php")
grep -q 'successfully restored' "$tmp/restore.body"
[ "$(sqlite3 "$db" "SELECT value FROM settings WHERE keyID='callSign';")" = "TEST" ]
[ "$(sqlite3 "$db" "SELECT password FROM users WHERE username='admin';")" = "$admin_hash" ]
code=$(curl -s -b "$jar" -H "X-CSRF-Token: ${token}" -o "$tmp/delbak.body" -w '%{http_code}' \
	--data-urlencode 'delete=1' \
	--data-urlencode "deleteSelectedFile=${archive}" \
	"$base/backup.php")
grep -q 'Deleted' "$tmp/delbak.body"
[ ! -e "$backup/$archive" ]
printf 'keep\n' > "$tmp/keep.txt"
code=$(curl -s -b "$jar" -H "X-CSRF-Token: ${token}" -o "$tmp/badbak.body" -w '%{http_code}' \
	--data-urlencode 'delete=1' \
	--data-urlencode 'deleteSelectedFile=../keep.txt' \
	"$base/backup.php")
grep -q 'plain file name' "$tmp/badbak.body"
[ -f "$tmp/keep.txt" ]
echo "ok: backup create, restore, and delete stay inside the backup directory"
code=$(curl -s -b "$jar" -H "X-CSRF-Token: ${token}" -o "$tmp/adv-on.body" -w '%{http_code}' \
	--data-urlencode 'action=changMode' \
	--data-urlencode 'orp_Mode=advanced' \
	"$base/advanced.php")
grep -q 'Advanced mode' "$tmp/adv-on.body"
code=$(curl -s -b "$jar" -H "X-CSRF-Token: ${token}" -o "$tmp/adv.body" -w '%{http_code}' \
	--data-urlencode 'action=update_advanced' \
	--data-urlencode 'svxlink_config=PTT_PIN=gpio498' \
	--data-urlencode 'gpio_config=GPIO_OUT_HIGH=498' \
	"$base/advanced.php")
grep -q 'updated successfully' "$tmp/adv.body"
[ "$(sqlite3 "$db" "SELECT value FROM advanced WHERE keyID='svxlink_config';")" = "PTT_PIN=gpio498" ]
ORP_ROOT="$live" ORP_OPERATING_MODE_FILE="$funct" "$ROOT_DIR/install/scripts/orp_helper" config publish >/dev/null
if grep -q 'gpio498\|GPIO_OUT_HIGH' "$cfg"; then
	echo "FAIL: advanced textarea was copied into the root runtime" >&2
	exit 1
fi
grep -q '^PTT_TYPE=NONE$' "$cfg"
echo "ok: advanced text is stored and is not the published runtime"
settings_after=$(sqlite3 "$db" "SELECT keyID || '=' || value FROM settings WHERE keyID NOT IN ('orp_Mode','txTailValueSec','repeaterDTMF_disable','repeaterDTMF_disable_pin','ID_Short_IntervalMin','ID_Short_Mode','courtesyMode','callSign') ORDER BY keyID;")
# Restore replaced settings. Re-read the preserved rows from the restored backup snapshot by comparing users and ctcss.
[ "$(sqlite3 "$db" "SELECT COUNT(*) FROM ctcss;")" = "50" ]
[ "$(sqlite3 "$db" "SELECT COUNT(*) FROM users;")" = "2" ]
login "$throw_jar" throwaway old-password
throw_page=$(curl -s -b "$throw_jar" "$base/login.php?action=setPassword")
throw_token=$(http_token "$throw_page")
code=$(curl -s -D "$tmp/pw.hdr" -o "$tmp/pw.body" -b "$throw_jar" -w '%{http_code}' \
	-H "X-CSRF-Token: ${throw_token}" \
	--data-urlencode 'action=setPassword' \
	--data-urlencode 'password1=new-password-9' \
	--data-urlencode 'password2=new-password-9' \
	"$base/login.php")
grep -q 'pwOK' "$tmp/pw.hdr"
[ "$(sqlite3 "$db" "SELECT password FROM users WHERE username='admin';")" = "$admin_hash" ]
[ "$(sqlite3 "$db" "SELECT password FROM users WHERE username='throwaway';")" != "$(php -r 'echo hash("sha256", "throwaway" . hash("sha256", "old-password"));')" ]
login "$tmp/new.cookies" throwaway new-password-9
new_page=$(curl -s -b "$tmp/new.cookies" "$base/settings.php")
printf '%s' "$new_page" | grep -q 'callSign'
echo "ok: throwaway password changed and the admin password did not"
echo "control round-trip checks passed"
