#!/bin/bash
# Fixture checks for the bench installer and orp_helper. No apt, no radio, no GPIO.
set -euo pipefail

export ORP_BENCH_TEST_HARNESS=1
ROOT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
# shellcheck source=lib/fixture_tmpdir.sh
. "$ROOT_DIR/upgrade/tests/lib/fixture_tmpdir.sh"
# shellcheck source=lib/native_layout.sh
. "$ROOT_DIR/upgrade/tests/lib/native_layout.sh"
orp_use_fixture_tmpdir
orp_require_fixture_space
INSTALL="$ROOT_DIR/upgrade/install-orp-ui.sh"
HELPER="$ROOT_DIR/install/scripts/orp_helper"
fail=0

ok() { echo "ok: $1"; }
bad() { echo "FAIL: $1" >&2; fail=1; }

if grep -E -n 'dist-upgrade|full-upgrade|gpioset|orp_systemctl unmask|systemctl unmask' "$INSTALL"; then
	bad "installer contains a forbidden command"
else
	ok "installer has no dist-upgrade, gpioset, or unmask command"
fi

bash -n "$INSTALL"
bash -n "$ROOT_DIR/upgrade/lib/bench-target.sh"
bash -n "$HELPER"
ok "shell syntax checks passed"
if grep -E -n '^[[:space:]]*(\.|source)[[:space:]]' "$HELPER"; then
	bad "orp_helper sources a file"
else
	ok "orp_helper sources nothing"
fi
if grep -n 'bench-target.sh' "$HELPER" || grep -n '/var/www/openrepeater/upgrade' "$HELPER"; then
	bad "orp_helper names a docroot script"
else
	ok "orp_helper does not name a docroot script"
fi

make_systemctl() {
	local path=$1
	cat > "$path" <<'EOF'
#!/bin/bash
echo "$*" >> "${ORP_SYSTEMCTL_LOG:?}"
cmd=$1
shift || true
case "$cmd" in
	is-enabled)
		case "$1" in
			svxlink.service|remotetrx.service|svxreflector.service)
				echo masked
				exit 1
				;;
			*)
				echo disabled
				exit 1
				;;
		esac
		;;
	is-active)
		case "$1" in
			orp-test-bootstrap.service|orp-test-bootstrap)
				if [ "${ORP_BOOTSTRAP_ACTIVE:-0}" = 1 ]; then
					echo activating
					exit 0
				fi
				echo inactive
				exit 3
				;;
			*)
				echo inactive
				exit 3
				;;
		esac
		;;
	*)
		exit 0
		;;
esac
EOF
	chmod 755 "$path"
}

seed_identity() {
	local root=$1
	orp_mkdir "$root" "$root/etc" "$root/var/lib/orp-test" "$root/usr/local/bin" "$root/usr/local/share/svxlink" \
		"$root/usr/local/sbin" "$root/opt/orp-test" "$root/etc/svxlink" "$root/etc/nginx/sites-enabled"
	printf 'orp-test\n' > "$root/etc/hostname"
	printf 'aarch64\n' > "$root/etc/orp-arch"
	cat > "$root/etc/os-release" <<'EOF'
ID=debian
VERSION_ID="13"
VERSION_CODENAME=trixie
EOF
	printf 'guard\n' > "$root/etc/orp-test-image"
	printf 'done\n' > "$root/var/lib/orp-test/complete"
	printf 'sentinel-build\n' > "$root/var/lib/orp-test/build-sentinel"
	orp_mkdir "$root/var/lib/orp-test/build"
	printf 'object\n' > "$root/var/lib/orp-test/build/keep.o"
	printf 'bin\n' > "$root/usr/local/bin/svxlink"
	printf 'share\n' > "$root/usr/local/share/svxlink/keep"
	printf 'bootstrap\n' > "$root/usr/local/sbin/orp-test-bootstrap.sh"
	printf 'archive\n' > "$root/opt/orp-test/keep"
	printf 'stock-svxlink\n' > "$root/etc/svxlink/svxlink.conf"
	printf 'default-site\n' > "$root/etc/nginx/sites-enabled/default"
	plant_native_layout "$root"
}

checksum() { sha256sum "$1" | awk '{print $1}'; }

tmp=$(orp_mktemp_dir)
trap 'orp_cleanup_fixture "$tmp"' EXIT
bin="$tmp/bin"
orp_mkdir "$bin"
log="$tmp/systemctl.log"
make_systemctl "$bin/systemctl"

# Wrong hostname must fail before any web root is created.
bad_host="$tmp/bad-host"
seed_identity "$bad_host"
printf 'pi\n' > "$bad_host/etc/hostname"
set +e
ORP_INSTALL_OFFLINE=1 ORP_ROOT="$bad_host" ORP_SYSTEMCTL="$bin/systemctl" ORP_SYSTEMCTL_LOG="$log" \
	ORP_BOOTSTRAP_ACTIVE=0 "$INSTALL" >"$tmp/bad-host.out" 2>"$tmp/bad-host.err"
rc=$?
set -e
if [ "$rc" -eq 2 ] && [ ! -d "$bad_host/var/www/openrepeater" ]; then
	ok "wrong hostname exits 2 before copying the UI"
else
	bad "wrong hostname rc=$rc"
	cat "$tmp/bad-host.err" >&2 || true
fi

# Missing completion marker.
no_marker="$tmp/no-marker"
seed_identity "$no_marker"
rm -f "$no_marker/var/lib/orp-test/complete"
set +e
ORP_INSTALL_OFFLINE=1 ORP_ROOT="$no_marker" ORP_SYSTEMCTL="$bin/systemctl" ORP_SYSTEMCTL_LOG="$log" \
	"$INSTALL" >"$tmp/no-marker.out" 2>"$tmp/no-marker.err"
rc=$?
set -e
if [ "$rc" -eq 3 ] && [ ! -d "$no_marker/var/www/openrepeater" ]; then
	ok "absent completion marker exits 3 before copying the UI"
else
	bad "missing marker rc=$rc"
	cat "$tmp/no-marker.err" >&2 || true
fi

# Bootstrap still activating.
active="$tmp/active"
seed_identity "$active"
set +e
ORP_INSTALL_OFFLINE=1 ORP_ROOT="$active" ORP_SYSTEMCTL="$bin/systemctl" ORP_SYSTEMCTL_LOG="$log" \
	ORP_BOOTSTRAP_ACTIVE=1 "$INSTALL" >"$tmp/active.out" 2>"$tmp/active.err"
rc=$?
set -e
if [ "$rc" -eq 3 ] && [ ! -d "$active/var/www/openrepeater" ]; then
	ok "activating bootstrap exits 3 before copying the UI"
else
	bad "active bootstrap rc=$rc"
	cat "$tmp/active.err" >&2 || true
fi

# Successful offline install, twice, preserving the database and sentinels.
good="$tmp/good"
seed_identity "$good"
: > "$log"
: > "$tmp/good.trace"
: > "$tmp/chown.log"
set +e
ORP_INSTALL_OFFLINE=1 ORP_ROOT="$good" ORP_SYSTEMCTL="$bin/systemctl" ORP_SYSTEMCTL_LOG="$log" \
	ORP_INSTALL_TRACE="$tmp/good.trace" ORP_CHOWN_LOG="$tmp/chown.log" \
	ORP_BOOTSTRAP_ACTIVE=0 ORP_PHP_FPM_SOCK=/run/php/php8.4-fpm.sock \
	"$INSTALL" >"$tmp/good.out" 2>"$tmp/good.err"
rc=$?
set -e
if [ "$rc" -ne 0 ]; then
	bad "installer failed rc=$rc"
	cat "$tmp/good.err" >&2 || true
else
	ok "installer completed on a matching fixture"
fi

for pair in \
	"$good/usr/local/bin/svxlink:bin" \
	"$good/etc/svxlink/svxlink.conf:stock-svxlink" \
	"$good/var/lib/orp-test/complete:done" \
	"$good/var/lib/orp-test/build/keep.o:object" \
	"$good/usr/local/sbin/orp-test-bootstrap.sh:bootstrap"
do
	file=${pair%%:*}
	expect=${pair##*:}
	got=$(cat "$file")
	got=${got%$'\n'}
	if [ "$got" = "$expect" ]; then
		ok "unchanged $(basename "$file")"
	else
		bad "changed $file"
	fi
done

if [ ! -e "$good/var/lib/orp-test/build.swap" ]; then
	ok "build.swap was not created"
else
	bad "build.swap was created"
fi

unit="$good/usr/local/lib/systemd/system/svxlink.service"
if [ -f "$unit" ] && [ ! -L "$unit" ] \
	&& grep -q '^ExecStart=/usr/local/bin/svxlink --logfile=/var/log/svxlink --config=/etc/svxlink/svxlink.conf$' "$unit" \
	&& ! grep -E -q 'gpio|EnvironmentFile|ExecStartPre|ExecStopPost|/usr/bin/svxlink' "$unit"
then
	ok "vendor unit points at the source-install binary and has no GPIO hook"
else
	bad "vendor unit"
	cat "$unit" >&2 || true
fi
for masked in svxlink.service remotetrx.service svxreflector.service; do
	if [ -L "$good/etc/systemd/system/$masked" ] && [ "$(readlink "$good/etc/systemd/system/$masked")" = "/dev/null" ]; then
		ok "mask preserved: $masked"
	else
		bad "mask changed: $masked"
	fi
done
if grep -q '^daemon-reload$' "$log" && ! grep -E -q 'unmask|start svxlink|enable svxlink' "$log"; then
	ok "installer reloaded systemd and did not unmask or start svxlink"
else
	bad "systemctl log during install"
	cat "$log" >&2 || true
fi

# Missing RepeaterLogic.so is the native layout the previous publisher missed.
# The install stops before the web tree and does not write a unit.
short="$tmp/short-layout"
seed_identity "$short"
rm -f "$short/usr/local/lib/svxlink/RepeaterLogic.so"
: > "$tmp/short.log"
set +e
ORP_INSTALL_OFFLINE=1 ORP_ROOT="$short" ORP_SYSTEMCTL="$bin/systemctl" ORP_SYSTEMCTL_LOG="$tmp/short.log" \
	ORP_BOOTSTRAP_ACTIVE=0 "$INSTALL" >"$tmp/short.out" 2>"$tmp/short.err"
rc=$?
set -e
if [ "$rc" -eq 7 ] && [ ! -d "$short/var/www/openrepeater" ] \
	&& [ ! -e "$short/usr/local/lib/systemd/system/svxlink.service" ] \
	&& [ "$(readlink "$short/etc/systemd/system/svxlink.service")" = "/dev/null" ] \
	&& grep -q 'RepeaterLogic.so' "$tmp/short.out" "$tmp/short.err"
then
	ok "missing native plugin aborts before the unit or the web tree"
else
	bad "missing plugin rc=$rc"
	echo '--- stdout ---' >&2
	cat "$tmp/short.out" >&2 || true
	echo '--- stderr ---' >&2
	cat "$tmp/short.err" >&2 || true
fi

site="$good/etc/nginx/sites-available/openrepeater"
if grep -q 'unix:/run/php/php8.4-fpm.sock' "$site" \
	&& ! grep -E -q 'php5-fpm|ssl[[:space:]]+on|listen[[:space:]]+443' "$site" \
	&& grep -q 'server_name orp-test' "$site" \
	&& grep -F -q 'location ~* ^/(modules|sounds)/' "$site" \
	&& grep -F -q 'location ~* ^/backup/' "$site" \
	&& grep -F -q 'location /internal-backup/' "$site" \
	&& ! grep -F -q 'location ~* ^/backup/[A-Za-z0-9]' "$site" \
	&& grep -q 'phtml' "$site" \
	&& grep -q 'phps' "$site" \
	&& grep -F -q 'zip|bak' "$site" \
	&& grep -q 'deny all;' "$site"
then
	ok "nginx site uses the PHP 8 socket and has no legacy TLS redirect"
else
	bad "nginx site content"
	cat "$site" >&2 || true
fi

if [ ! -e "$good/etc/nginx/sites-enabled/default" ] && [ -L "$good/etc/nginx/sites-enabled/openrepeater" ]; then
	ok "default site is not left enabled"
else
	bad "nginx enabled sites"
fi

if grep -q 'radio=blocked' "$good/etc/openrepeater/bench-mode" && grep -q 'gpio=readonly' "$good/etc/openrepeater/bench-mode"; then
	ok "bench-mode marker was written"
else
	bad "bench-mode marker"
fi
if [ "$(stat -c %a "$good/etc/openrepeater/bench-mode")" = "644" ] && [ "$(stat -c %a "$good/etc/openrepeater")" = "755" ]; then
	ok "bench marker and its directory are not group or world writable"
else
	bad "bench marker mode marker=$(stat -c %a "$good/etc/openrepeater/bench-mode") dir=$(stat -c %a "$good/etc/openrepeater")"
fi
if grep -E -q "root:root ${good}/etc/openrepeater/bench-mode$" "$tmp/chown.log" \
	&& grep -E -q "root:root ${good}/etc/openrepeater$" "$tmp/chown.log" \
	&& ! grep 'www-data' "$tmp/chown.log" | grep -F "$good/etc/openrepeater"
then
	ok "bench policy is recorded as root-owned, not www-data"
else
	bad "chown log"
	cat "$tmp/chown.log" >&2 || true
fi
marker_line=$(grep -n '^marker$' "$tmp/good.trace" | head -n 1 | cut -d: -f1)
stage_line=$(grep -n '^stage-www$' "$tmp/good.trace" | head -n 1 | cut -d: -f1)
test_line=$(grep -n '^nginx-test$' "$tmp/good.trace" | head -n 1 | cut -d: -f1)
enable_line=$(grep -n '^nginx-enable$' "$tmp/good.trace" | head -n 1 | cut -d: -f1)
if [ -n "$marker_line" ] && [ -n "$stage_line" ] && [ -n "$test_line" ] && [ -n "$enable_line" ] \
	&& [ "$marker_line" -lt "$stage_line" ] && [ "$stage_line" -lt "$test_line" ] && [ "$test_line" -lt "$enable_line" ]
then
	ok "marker is written before the web tree and nginx starts only after its config test"
else
	bad "install trace order"
	cat "$tmp/good.trace" >&2 || true
fi
sudoers="$good/etc/sudoers.d/openrepeater"
if ! grep -E -q '^www-data ALL=\(root\) NOPASSWD: /usr/sbin/orp_helper$' "$sudoers" \
	&& grep -q 'orp_helper svxlink gpio_up' "$sudoers" \
	&& grep -q 'orp_helper svxlink unmask' "$sudoers" \
	&& grep -q 'orp_helper remotetrx start' "$sudoers" \
	&& grep -q 'orp_helper svxreflector unmask' "$sudoers" \
	&& grep -q 'orp_helper system restart' "$sudoers" \
	&& grep -q 'orp_helper system stop' "$sudoers" \
	&& grep -q 'orp_helper svxlink status' "$sudoers" \
	&& grep -q 'orp_helper svxlink start' "$sudoers" \
	&& grep -q 'orp_helper svxlink stop' "$sudoers" \
	&& grep -q 'orp_helper config publish' "$sudoers" \
	&& grep -q 'orp_helper info os' "$sudoers" \
	&& grep -F -q 'orp_helper module activate [A-Za-z]' "$sudoers" \
	&& grep -F -q 'orp_helper module activate [A-Za-z][A-Za-z0-9_]' "$sudoers" \
	&& ! grep -F -q 'orp_helper module activate *' "$sudoers" \
	&& ! grep -F -q 'orp_helper module deactivate *' "$sudoers"
then
	ok "sudoers allows the functional-test radio commands and the closed module names"
else
	bad "sudoers contract"
	cat "$sudoers" >&2 || true
fi

if grep -q 'bench_refuses' "$good/usr/sbin/orp_helper"; then
	ok "installed helper contains the bench refusal"
else
	bad "helper was not installed"
fi

db="$good/var/lib/openrepeater/db/openrepeater.db"
if [ -f "$db" ]; then
	ok "stock database copied"
else
	bad "database missing"
fi
sqlite3 "$db" "UPDATE ports SET portLabel='USERPRESET' WHERE portNum=1;"
printf 'preserve\n' >> "$db"
mode="$good/etc/openrepeater/operating-mode"
if [ "$(tr -d '[:space:]' < "$mode")" = "bench" ]; then
	ok "first install writes bench operating mode"
else
	bad "first install did not write bench operating mode"
fi
printf 'functional-test\n' > "$mode"
orp_private "$mode"
for dir in \
	"$good/var/www/openrepeater/sounds" \
	"$good/var/www/openrepeater/sounds/courtesy_tones" \
	"$good/var/www/openrepeater/sounds/identification" \
	"$good/var/www/openrepeater/backup" \
	"$good/var/www/openrepeater/backup/restore"
do
	if [ -d "$dir" ] && [ ! -L "$dir" ]; then
		ok "restore anchor exists and is not a symlink: ${dir#"$good"}"
	else
		bad "restore anchor missing or is a symlink: $dir"
	fi
done
if grep -q "/var/www/openrepeater/sounds/" "$ROOT_DIR/includes/classes/BackupRestore.php" \
	&& grep -q "/var/www/openrepeater/backup/" "$ROOT_DIR/includes/classes/BackupRestore.php" \
	&& grep -q "/var/www/openrepeater/sounds" "$INSTALL" \
	&& grep -q "/var/www/openrepeater/backup" "$INSTALL"
then
	ok "installer anchors match the BackupRestore defaults"
else
	bad "installer anchors do not match BackupRestore"
fi
printf 'user-clip\n' > "$good/var/www/openrepeater/sounds/courtesy_tones/keep.wav"
printf 'user-backup\n' > "$good/var/www/openrepeater/backup/user.orp"
orp_mkdir "$good/usr/local/share/svxlink/sounds/en_US"
printf 'heather-canary\n' > "$good/usr/local/share/svxlink/sounds/en_US/heather.wav"
heather_before=$(checksum "$good/usr/local/share/svxlink/sounds/en_US/heather.wav")
before=$(checksum "$db")
ORP_INSTALL_OFFLINE=1 ORP_ROOT="$good" ORP_SYSTEMCTL="$bin/systemctl" ORP_SYSTEMCTL_LOG="$log" \
	ORP_BOOTSTRAP_ACTIVE=0 ORP_PHP_FPM_SOCK=/run/php/php8.4-fpm.sock \
	"$INSTALL" >/dev/null
after=$(checksum "$db")
if [ "$before" = "$after" ]; then
	ok "second install does not replace the database"
else
	bad "database was replaced on the second install"
fi
if [ "$(sqlite3 "$db" "SELECT portLabel FROM ports WHERE portNum=1;")" = "USERPRESET" ]; then
	ok "second install keeps the stored port label"
else
	bad "second install replaced the stored port label"
fi
if [ "$(tr -d '[:space:]' < "$mode")" = "functional-test" ]; then
	ok "second install does not replace functional-test mode"
else
	bad "second install replaced the operating mode"
fi
if [ -f "$good/etc/openrepeater/bench-mode" ] && [ "$(stat -c %a "$good/etc/openrepeater/bench-mode")" = "644" ]; then
	ok "second install keeps the bench marker"
else
	bad "second install removed the bench marker"
fi
if [ "$(cat "$good/var/www/openrepeater/sounds/courtesy_tones/keep.wav")" = "user-clip" ] \
	&& [ "$(cat "$good/var/www/openrepeater/backup/user.orp")" = "user-backup" ] \
	&& [ "$(checksum "$good/usr/local/share/svxlink/sounds/en_US/heather.wav")" = "$heather_before" ] \
	&& [ ! -L "$good/var/www/openrepeater/sounds" ] \
	&& [ ! -L "$good/var/www/openrepeater/backup" ]
then
	ok "second install preserves user audio and backup files and does not touch Heather"
else
	bad "second install changed user audio, backups, or Heather"
fi

linkroot="$tmp/sounds-link"
seed_identity "$linkroot"
orp_mkdir "$linkroot/var/www/openrepeater" "$linkroot/outside"
printf 'secret\n' > "$linkroot/outside/secret"
ln -s "$linkroot/outside" "$linkroot/var/www/openrepeater/sounds"
set +e
ORP_INSTALL_OFFLINE=1 ORP_ROOT="$linkroot" ORP_SYSTEMCTL="$bin/systemctl" ORP_SYSTEMCTL_LOG="$log" \
	ORP_BOOTSTRAP_ACTIVE=0 ORP_PHP_FPM_SOCK=/run/php/php8.4-fpm.sock \
	"$INSTALL" >"$tmp/sounds-link.out" 2>"$tmp/sounds-link.err"
rc=$?
set -e
if [ "$rc" -ne 0 ] && [ "$(cat "$linkroot/outside/secret")" = "secret" ] \
	&& [ ! -e "$linkroot/outside/courtesy_tones" ] \
	&& [ "$(cat "$linkroot/usr/local/share/svxlink/keep")" = "share" ]
then
	ok "a sounds symlink is refused and the outside tree is not used"
else
	bad "sounds symlink rc=$rc"
	cat "$tmp/sounds-link.err" >&2 || true
fi

ancestor="$tmp/ancestor-link"
seed_identity "$ancestor"
orp_mkdir "$ancestor/outside/www"
rm -rf "$ancestor/var/www"
ln -s "$ancestor/outside/www" "$ancestor/var/www"
printf 'secret\n' > "$ancestor/outside/secret"
set +e
ORP_INSTALL_OFFLINE=1 ORP_ROOT="$ancestor" ORP_SYSTEMCTL="$bin/systemctl" ORP_SYSTEMCTL_LOG="$log" \
	ORP_BOOTSTRAP_ACTIVE=0 ORP_PHP_FPM_SOCK=/run/php/php8.4-fpm.sock \
	"$INSTALL" >"$tmp/ancestor-link.out" 2>"$tmp/ancestor-link.err"
rc=$?
set -e
if [ "$rc" -ne 0 ] && [ "$(cat "$ancestor/outside/secret")" = "secret" ] \
	&& [ ! -d "$ancestor/outside/www/openrepeater/sounds" ]
then
	ok "an ancestor symlink on the web path is refused"
else
	bad "ancestor symlink rc=$rc"
	cat "$tmp/ancestor-link.err" >&2 || true
fi

failroot="$tmp/nginx-fail"
seed_identity "$failroot"
: > "$tmp/nginx-fail.log"
: > "$tmp/nginx-fail.trace"
printf '%s\n' '#!/bin/sh' 'exit 1' > "$tmp/nginx-fail.sh"
chmod 755 "$tmp/nginx-fail.sh"
set +e
ORP_INSTALL_OFFLINE=1 ORP_ROOT="$failroot" ORP_SYSTEMCTL="$bin/systemctl" \
	ORP_SYSTEMCTL_LOG="$tmp/nginx-fail.log" ORP_INSTALL_TRACE="$tmp/nginx-fail.trace" \
	ORP_NGINX_TEST="$tmp/nginx-fail.sh" ORP_PHP_FPM_SOCK=/run/php/php8.4-fpm.sock \
	ORP_BOOTSTRAP_ACTIVE=0 "$INSTALL" >"$tmp/nginx-fail.out" 2>"$tmp/nginx-fail.err"
rc=$?
set -e
if [ "$rc" -eq 5 ] && [ -f "$failroot/etc/openrepeater/bench-mode" ] \
	&& [ ! -e "$failroot/etc/nginx/sites-enabled/openrepeater" ] \
	&& grep -q '^marker$' "$tmp/nginx-fail.trace" \
	&& ! grep -q '^nginx-enable$' "$tmp/nginx-fail.trace" \
	&& ! grep -E -q 'enable --now nginx|unmask|svxlink start' "$tmp/nginx-fail.log"
then
	ok "nginx test failure leaves the marker, does not enable nginx, and does not unmask radio"
else
	bad "nginx failure path rc=$rc"
	cat "$tmp/nginx-fail.err" >&2 || true
	echo '--- trace ---' >&2
	cat "$tmp/nginx-fail.trace" >&2 || true
	echo '--- systemctl ---' >&2
	cat "$tmp/nginx-fail.log" >&2 || true
fi

if grep -E -q '^(enable --now php8\.4-fpm|enable --now nginx)$' "$log" \
	&& ! grep -E -q 'unmask|svxlink start|start svxlink|restart svxlink|enable --now svxlink|enable svxlink' "$log"
then
	ok "systemctl log enables only the web stack"
else
	bad "systemctl log"
	cat "$log" >&2 || true
fi

# Helper behavior.
rec="$tmp/rec"
orp_mkdir "$rec"
cat > "$rec/systemctl" <<'EOF'
#!/bin/bash
echo "systemctl $*" >> "${HELPER_LOG:?}"
exit 0
EOF
cat > "$rec/service" <<'EOF'
#!/bin/bash
echo "service $*" >> "${HELPER_LOG:?}"
exit 0
EOF
cat > "$rec/shutdown" <<'EOF'
#!/bin/bash
echo "shutdown $*" >> "${HELPER_LOG:?}"
exit 0
EOF
cat > "$rec/amixer" <<'EOF'
#!/bin/bash
echo "amixer $*" >> "${HELPER_LOG:?}"
exit 0
EOF
cat > "$rec/alsactl" <<'EOF'
#!/bin/bash
echo "alsactl $*" >> "${HELPER_LOG:?}"
exit 0
EOF
cat > "$rec/gpio-up" <<'EOF'
#!/bin/bash
echo "gpio-up $*" >> "${HELPER_LOG:?}"
exit 0
EOF
chmod 755 "$rec"/*

hlog="$tmp/helper.log"
marker="$tmp/bench-mode"
printf 'radio=blocked\n' > "$marker"
orp_private "$marker"
export PATH="$rec:$PATH"
export HELPER_LOG="$hlog"
export SVXLINK_GPIO_UP_BIN="$rec/gpio-up"
export SVXLINK_GPIO_DOWN_BIN="$rec/gpio-up"
printf 'cloud\n' > "$tmp/hostname-other"
printf 'orp-test\n' > "$tmp/hostname-orp"
export ORP_BENCH_HOSTNAME_FILE="$tmp/hostname-other"
cat > "$rec/chown" <<'EOF'
#!/bin/bash
echo "chown $*" >> "${HELPER_LOG:?}"
exit 0
EOF
chmod 755 "$rec/chown"

run_helper() {
	local marker=$1
	shift
	set +e
	out=$(ORP_BENCH_MARKER="$marker" "$HELPER" "$@" 2>&1)
	rc=$?
	set -e
	printf '%s\n' "$rc"
	printf '%s\n' "$out"
}

: > "$hlog"
result=$(run_helper "$marker" svxlink start)
rc=$(printf '%s\n' "$result" | head -n 1)
out=$(printf '%s\n' "$result" | tail -n +2)
if [ "$rc" -ne 0 ] && printf '%s' "$out" | grep -q 'refused:' && [ ! -s "$hlog" ]; then
	ok "bench helper refuses svxlink start without calling systemctl"
else
	bad "bench svxlink start rc=$rc out=$out"
	cat "$hlog" >&2 || true
fi

for spec in "svxlink restart" "svxlink enable" "svxlink gpio_up" "system restart" "system stop" "set_mixer Master 80" "alsa restore"; do
	: > "$hlog"
	# shellcheck disable=SC2086
	result=$(run_helper "$marker" $spec)
	rc=$(printf '%s\n' "$result" | head -n 1)
	out=$(printf '%s\n' "$result" | tail -n +2)
	if [ "$rc" -ne 0 ] && printf '%s' "$out" | grep -q 'refused:' && [ ! -s "$hlog" ]; then
		ok "bench helper refuses $spec"
	else
		bad "bench helper $spec rc=$rc"
	fi
done

: > "$hlog"
result=$(run_helper "$marker" svxlink unmask)
rc=$(printf '%s\n' "$result" | head -n 1)
out=$(printf '%s\n' "$result" | tail -n +2)
if [ "$rc" -ne 0 ] && printf '%s' "$out" | grep -q 'refused:' && [ ! -s "$hlog" ]; then
	ok "unmask is refused on the bench"
else
	bad "unmask on bench"
fi

: > "$hlog"
result=$(run_helper /no/such/bench-mode svxlink unmask)
rc=$(printf '%s\n' "$result" | head -n 1)
out=$(printf '%s\n' "$result" | tail -n +2)
if [ "$rc" -ne 0 ] && printf '%s' "$out" | grep -q 'refused:' && [ ! -s "$hlog" ]; then
	ok "unmask is refused without the bench marker"
else
	bad "unmask without marker"
fi

: > "$hlog"
result=$(run_helper /no/such/bench-mode svxlink start)
out=$(printf '%s\n' "$result" | tail -n +2)
if grep -q 'service svxlink start' "$hlog" && ! printf '%s' "$out" | grep -q 'refused:'; then
	ok "without the marker, svxlink start still calls service"
else
	bad "legacy svxlink start was blocked"
	cat "$hlog" >&2 || true
fi

: > "$hlog"
result=$(ORP_BENCH_HOSTNAME_FILE="$tmp/hostname-orp" run_helper /no/such/bench-mode svxlink start)
rc=$(printf '%s\n' "$result" | head -n 1)
out=$(printf '%s\n' "$result" | tail -n +2)
if [ "$rc" -ne 0 ] && printf '%s' "$out" | grep -q 'refused:' && ! grep -q 'service svxlink start' "$hlog"; then
	ok "hostname orp-test blocks svxlink start even when the marker is absent"
else
	bad "hostname bench gate rc=$rc"
	cat "$hlog" >&2 || true
fi

: > "$hlog"
result=$(run_helper /no/such/bench-mode alsa backup /etc/passwd)
rc=$(printf '%s\n' "$result" | head -n 1)
out=$(printf '%s\n' "$result" | tail -n +2)
if [ "$rc" -ne 0 ] && printf '%s' "$out" | grep -q 'refused:' && ! grep -E -q 'alsactl|chown' "$hlog"; then
	ok "alsa backup rejects a path outside the backup directory without chown"
else
	bad "alsa path guard"
	printf '%s\n' "$out" >&2
	cat "$hlog" >&2 || true
fi

printf '%s\n' '#!/bin/bash' 'echo "alsactl $*" >> "${HELPER_LOG:?}"' 'exit 1' > "$rec/alsactl"
chmod 755 "$rec/alsactl"
: > "$hlog"
result=$(run_helper /no/such/bench-mode alsa backup /var/www/openrepeater/backup/build/alsamixer.state)
rc=$(printf '%s\n' "$result" | head -n 1)
out=$(printf '%s\n' "$result" | tail -n +2)
if [ "$rc" -ne 0 ] && printf '%s' "$out" | grep -q 'alsactl store failed' \
	&& grep -q 'alsactl --file /var/www/openrepeater/backup/build/alsamixer.state store' "$hlog" \
	&& ! grep -q '^chown ' "$hlog"
then
	ok "alsactl failure does not chown the state file"
else
	bad "alsactl failure still changed ownership"
	printf '%s\n' "$out" >&2
	cat "$hlog" >&2 || true
fi

: > "$hlog"
result=$(run_helper "$marker" alsa backup /var/www/openrepeater/backup/build/alsamixer.state)
rc=$(printf '%s\n' "$result" | head -n 1)
out=$(printf '%s\n' "$result" | tail -n +2)
if [ "$rc" -ne 0 ] && printf '%s' "$out" | grep -q 'refused:' && ! grep -E -q 'alsactl|chown' "$hlog"; then
	ok "bench mode refuses alsa backup before alsactl or chown"
else
	bad "bench alsa backup"
	printf '%s\n' "$out" >&2
	cat "$hlog" >&2 || true
fi

canary_record() {
	stat -c '%u %g %a %n' "$1"
	cat "$1"
}

plant_canary() {
	local path=$1
	printf 'CANARY-BYTES\n' > "$path"
	chmod 604 "$path"
	canary_record "$path"
}

assert_canary() {
	local path=$1
	local before=$2
	local after
	after=$(canary_record "$path")
	if [ "$before" = "$after" ]; then
		ok "canary unchanged: $(basename "$path")"
	else
		bad "canary changed: $path"
		printf 'before [%s]\nafter  [%s]\n' "$before" "$after" >&2
	fi
}

# Leaf symlink where the old installer would chmod the canary.
leaf="$tmp/leaf-link"
seed_identity "$leaf"
orp_mkdir "$leaf/var/lib/openrepeater/db"
leaf_canary="$leaf/protected-canary"
leaf_before=$(plant_canary "$leaf_canary")
ln -s "$leaf_canary" "$leaf/var/lib/openrepeater/db/openrepeater.db"
set +e
ORP_INSTALL_OFFLINE=1 ORP_ROOT="$leaf" ORP_SYSTEMCTL="$bin/systemctl" \
	ORP_SYSTEMCTL_LOG="$tmp/leaf.log" ORP_PHP_FPM_SOCK=/run/php/php8.4-fpm.sock \
	ORP_BOOTSTRAP_ACTIVE=0 "$INSTALL" >"$tmp/leaf.out" 2>"$tmp/leaf.err"
rc=$?
set -e
if [ "$rc" -ne 0 ]; then
	ok "db symlink aborts the install"
else
	bad "db symlink install rc=$rc"
	cat "$tmp/leaf.err" >&2 || true
fi
assert_canary "$leaf_canary" "$leaf_before"

# Ancestor symlink. A leaf -L check would not see this.
anc="$tmp/ancestor-link"
seed_identity "$anc"
real="$anc/real-tree"
orp_mkdir "$real"
anc_canary="$real/keep"
anc_before=$(plant_canary "$anc_canary")
ln -s "$real" "$anc/var/lib/openrepeater"
set +e
ORP_INSTALL_OFFLINE=1 ORP_ROOT="$anc" ORP_SYSTEMCTL="$bin/systemctl" \
	ORP_SYSTEMCTL_LOG="$tmp/anc.log" ORP_PHP_FPM_SOCK=/run/php/php8.4-fpm.sock \
	ORP_BOOTSTRAP_ACTIVE=0 "$INSTALL" >"$tmp/anc.out" 2>"$tmp/anc.err"
rc=$?
set -e
if [ "$rc" -ne 0 ] && [ ! -e "$real/db" ] && [ ! -e "$real/bench-preview" ]; then
	ok "ancestor symlink is not followed"
else
	bad "ancestor symlink rc=$rc"
	cat "$tmp/anc.err" >&2 || true
fi
assert_canary "$anc_canary" "$anc_before"

# Reinstall after the database inode is replaced with a symlink.
re="$tmp/reinstall-link"
seed_identity "$re"
: > "$tmp/re.log"
set +e
ORP_INSTALL_OFFLINE=1 ORP_ROOT="$re" ORP_SYSTEMCTL="$bin/systemctl" \
	ORP_SYSTEMCTL_LOG="$tmp/re.log" ORP_PHP_FPM_SOCK=/run/php/php8.4-fpm.sock \
	ORP_BOOTSTRAP_ACTIVE=0 "$INSTALL" >"$tmp/re.out" 2>"$tmp/re.err"
rc=$?
set -e
if [ "$rc" -ne 0 ]; then
	bad "reinstall setup failed rc=$rc"
	cat "$tmp/re.err" >&2 || true
fi
re_canary="$re/protected-canary"
re_before=$(plant_canary "$re_canary")
rm -f "$re/var/lib/openrepeater/db/openrepeater.db"
ln -s "$re_canary" "$re/var/lib/openrepeater/db/openrepeater.db"
set +e
ORP_INSTALL_OFFLINE=1 ORP_ROOT="$re" ORP_SYSTEMCTL="$bin/systemctl" \
	ORP_SYSTEMCTL_LOG="$tmp/re2.log" ORP_PHP_FPM_SOCK=/run/php/php8.4-fpm.sock \
	ORP_BOOTSTRAP_ACTIVE=0 "$INSTALL" >"$tmp/re2.out" 2>"$tmp/re2.err"
rc=$?
set -e
if [ "$rc" -ne 0 ] && [ -f "$re/etc/openrepeater/bench-mode" ]; then
	ok "reinstall refuses a replaced database symlink and keeps the marker"
else
	bad "reinstall symlink rc=$rc"
	cat "$tmp/re2.err" >&2 || true
fi
assert_canary "$re_canary" "$re_before"

preview="$tmp/preview-link"
seed_identity "$preview"
orp_mkdir "$preview/var/lib/openrepeater"
preview_canary="$preview/etc/svxlink/svxlink.conf"
preview_before=$(canary_record "$preview_canary")
ln -s "$preview/etc/svxlink" "$preview/var/lib/openrepeater/bench-preview"
set +e
ORP_INSTALL_OFFLINE=1 ORP_ROOT="$preview" ORP_SYSTEMCTL="$bin/systemctl" \
	ORP_SYSTEMCTL_LOG="$tmp/preview.log" ORP_PHP_FPM_SOCK=/run/php/php8.4-fpm.sock \
	ORP_BOOTSTRAP_ACTIVE=0 "$INSTALL" >"$tmp/preview.out" 2>"$tmp/preview.err"
rc=$?
set -e
if [ "$rc" -ne 0 ]; then
	ok "bench-preview symlink aborts the install"
else
	bad "bench-preview symlink rc=$rc"
	cat "$tmp/preview.err" >&2 || true
fi
assert_canary "$preview_canary" "$preview_before"

# A read-only source tree is a supported install source. tar must not
# leave the web root mode 0555.
ro_src="$(orp_mktemp_dir)/src"
orp_mkdir "$ro_src"
tar -C "$ROOT_DIR" --exclude=.git --exclude=dev -cf - . | tar -C "$ro_src" -xf -
chmod -R a-w "$ro_src"
ro_dest="$tmp/readonly-source"
seed_identity "$ro_dest"
set +e
ORP_INSTALL_OFFLINE=1 ORP_ROOT="$ro_dest" ORP_SYSTEMCTL="$bin/systemctl" \
	ORP_SYSTEMCTL_LOG="$tmp/ro.log" ORP_PHP_FPM_SOCK=/run/php/php8.4-fpm.sock \
	ORP_BOOTSTRAP_ACTIVE=0 "$ro_src/upgrade/install-orp-ui.sh" >"$tmp/ro.out" 2>"$tmp/ro.err"
rc=$?
set -e
ro_web="$ro_dest/var/www/openrepeater"
if [ "$rc" -eq 0 ] \
	&& [ "$(stat -c %a "$ro_web")" = "755" ] \
	&& [ "$(stat -c %a "$ro_web/index.php")" = "644" ] \
	&& [ "$(stat -c %a "$ro_dest/usr/sbin/orp_helper")" = "755" ] \
	&& [ ! -e "$ro_web/install" ] \
	&& [ ! -e "$ro_web/upgrade" ] \
	&& [ -d "$ro_web/sounds" ] && [ ! -L "$ro_web/sounds" ] \
	&& [ -d "$ro_web/sounds/courtesy_tones" ] \
	&& [ -d "$ro_web/backup/restore" ]
then
	ok "a read-only source installs with explicit directory and file modes"
else
	bad "read-only source rc=$rc web=$(stat -c %a "$ro_web" 2>/dev/null || echo missing)"
	cat "$tmp/ro.err" >&2 || true
fi

mask_root=$(orp_mktemp_dir)
orp_mkdir "$mask_root/etc/openrepeater"
cat > "$tmp/mask-systemctl" <<'EOF'
#!/bin/bash
unit=${2:-}
case "$1" in
	is-enabled)
		printf '%s\n' "${MASK_ENABLED:-masked}"
		exit 1
		;;
	is-active)
		printf '%s\n' "${MASK_ACTIVE:-inactive}"
		exit 3
		;;
esac
exit 0
EOF
chmod 755 "$tmp/mask-systemctl"
(
	export ROOT="$mask_root"
	export ORP_SYSTEMCTL="$tmp/mask-systemctl"
	# shellcheck source=../lib/bench-target.sh
	. "$ROOT_DIR/upgrade/lib/bench-target.sh"
	MASK_ENABLED=masked MASK_ACTIVE=inactive bench_assert_masks
) || bad "masked units were refused"
(
	export ROOT="$mask_root"
	export ORP_SYSTEMCTL="$tmp/mask-systemctl"
	. "$ROOT_DIR/upgrade/lib/bench-target.sh"
	if MASK_ENABLED=disabled MASK_ACTIVE=inactive bench_assert_masks; then
		exit 1
	fi
) || bad "disabled units were accepted without a functional-test token"
printf 'orp-test\n' > "$mask_root/etc/hostname"
printf 'functional-test\n' > "$mask_root/etc/openrepeater/operating-mode"
chmod 644 "$mask_root/etc/openrepeater/operating-mode"
sudo chown 0:0 "$mask_root/etc/openrepeater/operating-mode"
(
	export ROOT="$mask_root"
	export ORP_SYSTEMCTL="$tmp/mask-systemctl"
	. "$ROOT_DIR/upgrade/lib/bench-target.sh"
	MASK_ENABLED=disabled MASK_ACTIVE=inactive bench_assert_masks
) || bad "inactive disabled functional-test was refused"
(
	export ROOT="$mask_root"
	export ORP_SYSTEMCTL="$tmp/mask-systemctl"
	. "$ROOT_DIR/upgrade/lib/bench-target.sh"
	MASK_ENABLED=enabled MASK_ACTIVE=inactive bench_assert_masks
) || bad "an enabled unit was refused in functional-test"
(
	export ROOT="$mask_root"
	export ORP_SYSTEMCTL="$tmp/mask-systemctl"
	. "$ROOT_DIR/upgrade/lib/bench-target.sh"
	MASK_ENABLED=disabled MASK_ACTIVE=active bench_assert_masks
) || bad "a running unit was refused in functional-test"
sudo chmod 666 "$mask_root/etc/openrepeater/operating-mode"
(
	export ROOT="$mask_root"
	export ORP_SYSTEMCTL="$tmp/mask-systemctl"
	. "$ROOT_DIR/upgrade/lib/bench-target.sh"
	if MASK_ENABLED=disabled MASK_ACTIVE=inactive bench_assert_masks; then
		exit 1
	fi
) || bad "a group-writable functional-test token was accepted"
ok "masks stay fail-closed and functional-test may be inactive and disabled"
if command -v setfacl >/dev/null 2>&1 && command -v getfacl >/dev/null 2>&1; then
	printf 'functional-test\n' | sudo tee "$mask_root/etc/openrepeater/operating-mode" >/dev/null
	sudo chown 0:0 "$mask_root/etc/openrepeater/operating-mode"
	sudo chmod 644 "$mask_root/etc/openrepeater/operating-mode"
	sudo setfacl -m u:nobody:r "$mask_root/etc/openrepeater/operating-mode"
	(
		export ROOT="$mask_root"
		export ORP_SYSTEMCTL="$tmp/mask-systemctl"
		. "$ROOT_DIR/upgrade/lib/bench-target.sh"
		if MASK_ENABLED=disabled MASK_ACTIVE=inactive bench_assert_masks; then
			exit 1
		fi
	) || bad "a functional-test token with an ACL was accepted"
	sudo setfacl -b "$mask_root/etc/openrepeater/operating-mode" || true
	ok "a functional-test token with an ACL is refused"
fi
user_token=$(orp_mktemp_dir)
orp_mkdir "$user_token/etc/openrepeater"
printf 'orp-test\n' > "$user_token/etc/hostname"
printf 'functional-test\n' > "$user_token/etc/openrepeater/operating-mode"
chmod 644 "$user_token/etc/openrepeater/operating-mode"
sudo chown 1000:1000 "$user_token/etc/openrepeater/operating-mode"
(
	export ROOT="$user_token"
	. "$ROOT_DIR/upgrade/lib/bench-target.sh"
	if bench_mode_is_functional_test; then
		exit 1
	fi
) || bad "the installer accepted a uid-1000 mode 0644 token"
(
	export ORP_HELPER_SOURCE_ONLY=1
	export ORP_ROOT="$user_token"
	# shellcheck source=../../install/scripts/orp_helper
	. "$ROOT_DIR/install/scripts/orp_helper"
	if native_functional_token; then
		exit 1
	fi
) || bad "the helper accepted a uid-1000 mode 0644 token"
ok "a uid-1000 mode 0644 token is refused by the installer and the helper"

ft_ctl="$tmp/ft-systemctl"
cat > "$ft_ctl" <<'EOF'
#!/bin/bash
echo "$*" >> "${ORP_SYSTEMCTL_LOG:?}"
case "$1" in
	is-enabled)
		echo disabled
		exit 1
		;;
	is-active)
		echo inactive
		exit 3
		;;
	*)
		exit 0
		;;
esac
EOF
chmod 755 "$ft_ctl"
lib_only=$(orp_mktemp_dir)
orp_mkdir "$lib_only/etc/openrepeater" "$lib_only/usr/lib/systemd/system"
printf 'orp-test\n' > "$lib_only/etc/hostname"
printf 'functional-test\n' > "$lib_only/etc/openrepeater/operating-mode"
chmod 644 "$lib_only/etc/openrepeater/operating-mode"
sudo chown 0:0 "$lib_only/etc/openrepeater/operating-mode"
for unit in svxlink.service remotetrx.service svxreflector.service; do
	printf '%s\n' '[Unit]' 'Description=library' > "$lib_only/usr/lib/systemd/system/$unit"
done
: > "$tmp/lib-only.log"
(
	export ROOT="$lib_only"
	export ORP_SYSTEMCTL="$ft_ctl"
	export ORP_SYSTEMCTL_LOG="$tmp/lib-only.log"
	. "$ROOT_DIR/upgrade/lib/bench-target.sh"
	bench_assert_masks
) || bad "the installer refused a unit that exists only under /usr/lib"
(
	export ORP_HELPER_SOURCE_ONLY=1
	export ORP_ROOT="$lib_only"
	export ORP_SYSTEMCTL="$ft_ctl"
	export ORP_SYSTEMCTL_LOG="$tmp/lib-only.log"
	. "$ROOT_DIR/install/scripts/orp_helper"
	native_masks
) || bad "the helper refused a unit that exists only under /usr/lib"
ok "a disabled inactive unit that exists only under /usr/lib is accepted"
unmask_units() {
	local root=$1 unit
	for unit in svxlink.service remotetrx.service svxreflector.service; do
		rm -f "$root/etc/systemd/system/$unit"
		printf '%s\n' '[Unit]' 'Description=fixture' > "$root/etc/systemd/system/$unit"
	done
}
no_token="$tmp/ft-notoken"
seed_identity "$no_token"
unmask_units "$no_token"
: > "$tmp/ft-notoken.log"
set +e
ORP_INSTALL_OFFLINE=1 ORP_ROOT="$no_token" ORP_SYSTEMCTL="$ft_ctl" ORP_SYSTEMCTL_LOG="$tmp/ft-notoken.log" \
	ORP_BOOTSTRAP_ACTIVE=0 "$INSTALL" >"$tmp/ft-notoken.out" 2>"$tmp/ft-notoken.err"
rc=$?
set -e
if [ "$rc" -eq 4 ] && grep -q 'refused:' "$tmp/ft-notoken.err" && [ ! -d "$no_token/var/www/openrepeater" ]; then
	ok "an unmasked inactive bench without a functional-test token is refused"
else
	bad "unmasked install without a token rc=$rc"
	cat "$tmp/ft-notoken.err" >&2 || true
fi
with_token="$tmp/ft-token"
seed_identity "$with_token"
unmask_units "$with_token"
orp_mkdir "$with_token/etc/openrepeater"
printf 'functional-test\n' > "$with_token/etc/openrepeater/operating-mode"
chmod 644 "$with_token/etc/openrepeater/operating-mode"
sudo chown 0:0 "$with_token/etc/openrepeater/operating-mode"
sudo chown -R 0:0 "$with_token"
: > "$tmp/ft-token.log"
unit_before=$(sha256sum \
	"$with_token/etc/systemd/system/svxlink.service" \
	"$with_token/etc/systemd/system/remotetrx.service" \
	"$with_token/etc/systemd/system/svxreflector.service")
set +e
sudo -n env ORP_INSTALL_OFFLINE=1 ORP_ROOT="$with_token" ORP_SYSTEMCTL="$ft_ctl" \
	ORP_SYSTEMCTL_LOG="$tmp/ft-token.log" ORP_BOOTSTRAP_ACTIVE=0 \
	ORP_PHP_FPM_SOCK=/run/php/php8.4-fpm.sock ORP_BENCH_TEST_HARNESS=1 \
	bash "$INSTALL" >"$tmp/ft-token.out" 2>"$tmp/ft-token.err"
rc=$?
set -e
unit_after=$(sha256sum \
	"$with_token/etc/systemd/system/svxlink.service" \
	"$with_token/etc/systemd/system/remotetrx.service" \
	"$with_token/etc/systemd/system/svxreflector.service")
if [ "$rc" -eq 0 ] \
	&& [ "$unit_before" = "$unit_after" ] \
	&& [ ! -L "$with_token/etc/systemd/system/svxlink.service" ] \
	&& [ ! -e "$with_token/usr/local/lib/systemd/system/svxlink.service" ] \
	&& ! grep -E '^(enable|unmask|start) ' "$tmp/ft-token.log" | grep -E -q 'svxlink|remotetrx|svxreflector'
then
	ok "a functional-test token install finishes without replacing or enabling units"
else
	bad "functional-test unmasked install rc=$rc"
	cat "$tmp/ft-token.err" >&2 || true
fi
sudo chown -R "$(id -u):$(id -g)" "$with_token" || true

# Same fixtures, both copies. A mismatch is a drift even when both are wrong.
token_verdict() {
	local root=$1 which=$2
	if [ "$which" = installer ]; then
		if ROOT="$root" bash -c '. "$1"; bench_mode_is_functional_test' _ \
			"$ROOT_DIR/upgrade/lib/bench-target.sh" >/dev/null 2>&1
		then
			printf accept
		else
			printf refuse
		fi
	else
		if ORP_HELPER_SOURCE_ONLY=1 ORP_ROOT="$root" ORP_BENCH_TEST_HARNESS=1 \
			bash -c '. "$1"; native_functional_token' _ "$HELPER" >/dev/null 2>&1
		then
			printf accept
		else
			printf refuse
		fi
	fi
}
expect_token() {
	local label=$1 root=$2 want=$3 inst helper
	inst=$(token_verdict "$root" installer)
	helper=$(token_verdict "$root" helper)
	phpv=$(php -r '
		putenv("ORP_BENCH_TEST_HARNESS=1");
		putenv("ORP_OPERATING_MODE_FILE=" . $argv[1] . "/etc/openrepeater/operating-mode");
		putenv("ORP_BENCH_HOSTNAME_FILE=" . $argv[1] . "/etc/hostname");
		putenv("ORP_BENCH_MARKER=" . $argv[1] . "/no-such-marker");
		require $argv[2] . "/includes/classes/BenchGuard.php";
		echo BenchGuard::detect()->trustedFunctionalTest() ? "accept" : "refuse";
	' "$root" "$ROOT_DIR")
	if [ "$inst" != "$helper" ] || [ "$inst" != "$phpv" ] || [ "$inst" != "$want" ]; then
		bad "token drift ${label}: installer=${inst} helper=${helper} php=${phpv} expected=${want}"
	fi
}
cat > "$tmp/drift-systemctl" <<'EOF'
#!/bin/bash
case "$1" in
	is-enabled)
		printf '%s\n' "${DRIFT_ENABLED:-disabled}"
		exit 1
		;;
	is-active)
		printf '%s\n' "${DRIFT_ACTIVE:-inactive}"
		exit 3
		;;
	*)
		exit 0
		;;
esac
EOF
chmod 755 "$tmp/drift-systemctl"
mask_verdict() {
	local root=$1 which=$2
	if [ "$which" = installer ]; then
		if ROOT="$root" ORP_SYSTEMCTL="$tmp/drift-systemctl" \
			bash -c '. "$1"; bench_assert_masks' _ \
			"$ROOT_DIR/upgrade/lib/bench-target.sh" >/dev/null 2>&1
		then
			printf accept
		else
			printf refuse
		fi
	else
		if ORP_HELPER_SOURCE_ONLY=1 ORP_ROOT="$root" ORP_BENCH_TEST_HARNESS=1 \
			ORP_SYSTEMCTL="$tmp/drift-systemctl" \
			bash -c '. "$1"; native_masks' _ "$HELPER" >/dev/null 2>&1
		then
			printf accept
		else
			printf refuse
		fi
	fi
}
expect_masks() {
	local label=$1 root=$2 enabled=$3 active=$4 want=$5 inst helper
	inst=$(DRIFT_ENABLED="$enabled" DRIFT_ACTIVE="$active" mask_verdict "$root" installer)
	helper=$(DRIFT_ENABLED="$enabled" DRIFT_ACTIVE="$active" mask_verdict "$root" helper)
	if [ "$inst" != "$helper" ] || [ "$inst" != "$want" ]; then
		bad "unit drift ${label}: installer=${inst} helper=${helper} expected=${want}"
	fi
}
new_token_root() {
	local root contents=$1 mode=$2 owner=$3
	root=$(orp_mktemp_dir)
	orp_mkdir "$root/etc/openrepeater"
	printf 'orp-test\n' > "$root/etc/hostname"
	if [ "$contents" != missing ]; then
		printf '%s\n' "$contents" > "$root/etc/openrepeater/operating-mode"
		chmod "$mode" "$root/etc/openrepeater/operating-mode"
		if [ "$owner" = root ]; then
			sudo chown 0:0 "$root/etc/openrepeater/operating-mode"
		elif [ "$owner" = user ]; then
			sudo chown 1000:1000 "$root/etc/openrepeater/operating-mode"
		fi
	fi
	printf '%s' "$root"
}
good_token=$(new_token_root functional-test 644 root)
user_owned=$(new_token_root functional-test 644 user)
group_write=$(new_token_root functional-test 666 root)
wrong_text=$(new_token_root bench 644 root)
missing_token=$(new_token_root missing 644 root)
wrong_host=$(orp_mktemp_dir)
orp_mkdir "$wrong_host/etc/openrepeater"
printf 'not-the-bench\n' > "$wrong_host/etc/hostname"
printf 'functional-test\n' > "$wrong_host/etc/openrepeater/operating-mode"
chmod 644 "$wrong_host/etc/openrepeater/operating-mode"
sudo chown 0:0 "$wrong_host/etc/openrepeater/operating-mode"
link_token=$(orp_mktemp_dir)
orp_mkdir "$link_token/etc/openrepeater"
printf 'orp-test\n' > "$link_token/etc/hostname"
printf 'functional-test\n' > "$link_token/etc/openrepeater/real-mode"
chmod 644 "$link_token/etc/openrepeater/real-mode"
sudo chown 0:0 "$link_token/etc/openrepeater/real-mode"
ln -s real-mode "$link_token/etc/openrepeater/operating-mode"
expect_token "root-owned functional-test" "$good_token" accept
expect_token "uid 1000 mode 0644" "$user_owned" refuse
expect_token "group-writable" "$group_write" refuse
expect_token "contents bench" "$wrong_text" refuse
expect_token "missing file" "$missing_token" refuse
expect_token "wrong hostname" "$wrong_host" refuse
expect_token "symlink token" "$link_token" refuse
if command -v setfacl >/dev/null 2>&1 && command -v getfacl >/dev/null 2>&1; then
	acl_token=$(new_token_root functional-test 644 root)
	sudo setfacl -m u:nobody:r "$acl_token/etc/openrepeater/operating-mode"
	expect_token "extended ACL" "$acl_token" refuse
	sudo setfacl -b "$acl_token/etc/openrepeater/operating-mode" || true
fi
expect_masks "disabled inactive with a token" "$good_token" disabled inactive accept
expect_masks "systemd masked without a token" "$missing_token" masked inactive accept
expect_masks "enabled with a token" "$good_token" enabled inactive accept
expect_masks "active with a token" "$good_token" disabled active accept
expect_masks "disabled without a token" "$missing_token" disabled inactive refuse
devnull_unit=$(orp_mktemp_dir)
orp_mkdir "$devnull_unit/etc/systemd/system"
ln -sfn /dev/null "$devnull_unit/etc/systemd/system/svxlink.service"
expect_masks "dev-null symlink without a token" "$devnull_unit" disabled inactive refuse
ok "installer and helper token and unit verdicts match"

attack=$(orp_mktemp_dir)
plant_native_layout "$attack"
orp_mkdir "$attack/usr/sbin" "$attack/etc/openrepeater" \
	"$attack/var/lib/openrepeater/db" \
	"$attack/var/www/openrepeater/upgrade/lib" "$attack/upgrade/lib"
cp "$HELPER" "$attack/usr/sbin/orp_helper"
chmod 755 "$attack/usr/sbin/orp_helper"
printf 'orp-test\n' > "$attack/etc/hostname"
printf 'functional-test\n' > "$attack/etc/openrepeater/operating-mode"
chmod 644 "$attack/etc/openrepeater/operating-mode"
sudo chown 0:0 "$attack/etc/openrepeater/operating-mode"
attack_db="$attack/var/lib/openrepeater/db/openrepeater.db"
cp "$ROOT_DIR/install/sql/openrepeater.db" "$attack_db"
chmod 600 "$attack_db"
apply_ident_profile "$attack_db"
sqlite3 "$attack_db" "UPDATE settings SET value='W1AW' WHERE keyID='callSign'; UPDATE settings SET value='simplex' WHERE keyID='orp_Mode'; UPDATE settings SET value='beep' WHERE keyID='courtesyMode';"
if ! ORP_HELPER_SOURCE_ONLY=1 ORP_BENCH_TEST_HARNESS=1 ORP_ROOT="$attack" ORP_DB_PATH="$attack_db" \
	bash -c '. "$1"; config_render "$2"' _ "$attack/usr/sbin/orp_helper" \
	"$attack/etc/svxlink/svxlink.conf"
then
	bad "could not render the attack-fixture snapshot"
fi
marker="$attack/pwned-marker"
cat > "$attack/upgrade/lib/bench-target.sh" <<EOF
printf 'pwned\n' > '$marker'
EOF
cp "$attack/upgrade/lib/bench-target.sh" "$attack/var/www/openrepeater/upgrade/lib/bench-target.sh"
sudo chown -R www-data:www-data "$attack/upgrade" "$attack/var/www/openrepeater"
if [ "$(stat -c %u "$attack/var/www/openrepeater/upgrade/lib/bench-target.sh")" != "$(id -u www-data)" ]; then
	bad "the planted bench-target.sh is not owned by www-data"
fi
: > "$attack/systemctl.log"
run_attack() {
	ORP_BENCH_TEST_HARNESS=1 ORP_ROOT="$attack" ORP_DB_PATH="$attack_db" \
		ORP_OPERATING_MODE_FILE="$attack/etc/openrepeater/operating-mode" \
		ORP_SYSTEMCTL="$ft_ctl" ORP_SYSTEMCTL_LOG="$attack/systemctl.log" \
		"$attack/usr/sbin/orp_helper" "$@" >/dev/null 2>&1 || true
}
run_attack svxlink start
run_attack svxlink stop
run_attack svxlink restart
run_attack svxlink status
run_attack config publish
run_attack audio inputs
run_attack audio outputs
run_attack audio version
run_attack system uptime
run_attack system user
run_attack info timezone
run_attack info cpu_type
run_attack info cpu_speed
run_attack info cpu_load
run_attack info cpu_temp
run_attack info uptime
run_attack info memory_usage
run_attack info disk_usage
run_attack info os
if [ -e "$marker" ]; then
	bad "orp_helper executed a www-data-owned bench-target.sh"
else
	ok "orp_helper did not execute a www-data-owned bench-target.sh"
fi

legacy=$(orp_mktemp_dir)
orp_mkdir "$legacy/usr/share/svxlink/events.d" "$legacy/usr/local/share/svxlink/events.d" \
	"$legacy/var/www/openrepeater/modules/Foo/svxlink/events.d"
printf 'tcl\n' > "$legacy/var/www/openrepeater/modules/Foo/svxlink/events.d/ModuleFoo.tcl"
printf 'stock\n' > "$legacy/usr/share/svxlink/events.d/Logic.tcl"
ln -s "$legacy/var/www/openrepeater/modules/Foo/svxlink/events.d/ModuleFoo.tcl" \
	"$legacy/usr/share/svxlink/events.d/ModuleFoo.tcl"
ln -s ../../../../../var/www/openrepeater/modules/Foo/svxlink/events.d/ModuleFoo.tcl \
	"$legacy/usr/local/share/svxlink/events.d/ModuleFoo.tcl"
ln -s /etc/hostname "$legacy/usr/share/svxlink/events.d/hostname.tcl"
(
	export ROOT="$legacy"
	# shellcheck source=../lib/bench-target.sh
	. "$ROOT_DIR/upgrade/lib/bench-target.sh"
	bench_remove_legacy_module_symlinks
) > "$tmp/legacy.log"
if [ ! -e "$legacy/usr/share/svxlink/events.d/ModuleFoo.tcl" ] \
	&& [ ! -L "$legacy/usr/share/svxlink/events.d/ModuleFoo.tcl" ] \
	&& [ ! -e "$legacy/usr/local/share/svxlink/events.d/ModuleFoo.tcl" ] \
	&& [ ! -L "$legacy/usr/local/share/svxlink/events.d/ModuleFoo.tcl" ] \
	&& [ -L "$legacy/usr/share/svxlink/events.d/hostname.tcl" ] \
	&& [ "$(cat "$legacy/usr/share/svxlink/events.d/Logic.tcl")" = "stock" ] \
	&& [ "$(cat "$legacy/var/www/openrepeater/modules/Foo/svxlink/events.d/ModuleFoo.tcl")" = "tcl" ] \
	&& grep -q 'removed legacy module symlink' "$tmp/legacy.log" \
	&& grep -q 'bench_remove_legacy_module_symlinks' "$INSTALL"
then
	ok "legacy module symlinks into the web tree are removed"
else
	bad "legacy module symlinks were not removed"
	cat "$tmp/legacy.log" >&2 || true
fi
swapped=$(orp_mktemp_dir)
orp_mkdir "$swapped/real/share/svxlink/events.d" "$swapped/var/www/openrepeater/modules/Foo/svxlink/events.d"
printf 'tcl\n' > "$swapped/var/www/openrepeater/modules/Foo/svxlink/events.d/ModuleFoo.tcl"
ln -s "$swapped/var/www/openrepeater/modules/Foo/svxlink/events.d/ModuleFoo.tcl" \
	"$swapped/real/share/svxlink/events.d/ModuleFoo.tcl"
ln -s "$swapped/real" "$swapped/usr"
set +e
(
	export ROOT="$swapped"
	# shellcheck source=../lib/bench-target.sh
	. "$ROOT_DIR/upgrade/lib/bench-target.sh"
	bench_remove_legacy_module_symlinks
) >"$tmp/swapped.out" 2>"$tmp/swapped.err"
swapped_rc=$?
set -e
if [ "$swapped_rc" -ne 0 ] \
	&& grep -q 'is a symlink' "$tmp/swapped.err" \
	&& [ -L "$swapped/real/share/svxlink/events.d/ModuleFoo.tcl" ]
then
	ok "a symlinked share parent is refused and its links stay"
else
	bad "a symlinked share parent was not refused"
	cat "$tmp/swapped.err" >&2 || true
fi

if [ "$fail" -ne 0 ]; then
	echo "shell checks failed" >&2
	exit 1
fi
echo "shell checks passed"
exit 0
