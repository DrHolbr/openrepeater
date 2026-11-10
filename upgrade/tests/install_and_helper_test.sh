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
	mkdir -p "$root/etc" "$root/var/lib/orp-test" "$root/usr/local/bin" "$root/usr/local/share/svxlink" \
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
	mkdir -p "$root/var/lib/orp-test/build"
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
trap 'rm -rf "$tmp"' EXIT
bin="$tmp/bin"
mkdir -p "$bin"
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
	&& grep -q 'server_name orp-test' "$site"
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
	&& ! grep -E -q 'alsa|gpio_up|set_mixer|unmask' "$sudoers" \
	&& grep -q 'orp_helper svxlink status' "$sudoers" \
	&& grep -q 'orp_helper svxlink start' "$sudoers" \
	&& grep -q 'orp_helper svxlink stop' "$sudoers" \
	&& grep -q 'orp_helper config publish' "$sudoers" \
	&& grep -q 'orp_helper info os' "$sudoers"
then
	ok "sudoers allows exact svxlink lifecycle commands and still has no gpio or unmask"
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
mkdir -p "$good/usr/local/share/svxlink/sounds/en_US"
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
mkdir -p "$linkroot/var/www/openrepeater" "$linkroot/outside"
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
mkdir -p "$ancestor/outside/www"
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
mkdir -p "$rec"
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
mkdir -p "$leaf/var/lib/openrepeater/db"
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
mkdir -p "$real"
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
mkdir -p "$preview/var/lib/openrepeater"
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

if [ "$fail" -ne 0 ]; then
	echo "shell checks failed" >&2
	exit 1
fi
echo "shell checks passed"
exit 0
