#!/bin/bash
# uid 33 replaces a directory with a symlink after the check and before the
# root attribute change. The outside canary must keep mode 0600.
set -euo pipefail

ROOT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
# shellcheck source=lib/fixture_tmpdir.sh
. "$ROOT_DIR/upgrade/tests/lib/fixture_tmpdir.sh"
orp_reexec_root_if_needed "$@"
orp_use_fixture_tmpdir
orp_require_fixture_space
# shellcheck source=../lib/bench-target.sh
. "$ROOT_DIR/upgrade/lib/bench-target.sh"
# shellcheck source=lib/native_layout.sh
. "$ROOT_DIR/upgrade/tests/lib/native_layout.sh"
INSTALL="$ROOT_DIR/upgrade/install-orp-ui.sh"
fail=0
ok() { echo "ok: $1"; }
bad() { echo "FAIL: $1" >&2; fail=1; }

swap_as_web() {
	local child=$1
	local canary=$2
	setpriv --reuid=33 --regid=33 --clear-groups --inh-caps=-all -- \
		bash -c 'mv -- "$1" "$1.aside" && ln -s "$2" "$1"' bash "$child" "$canary"
}

wait_ready() {
	local pause=$1
	local i
	for i in $(seq 1 200); do
		if [ -f "${pause}.ready" ]; then
			return 0
		fi
		sleep 0.05
	done
	return 1
}

canary_intact() {
	local canary=$1
	[ "$(stat -c %a "$canary")" = "600" ] && [ "$(cat "$canary")" = "SECRET" ]
}

tmp=$(orp_mktemp_dir)
chmod 755 "$tmp"
trap 'rm -rf "$tmp"' EXIT

# bench_chmod: checks see a real directory, then uid 33 swaps the name.
direct=$tmp/direct
orp_mkdir "$direct/parent" "$direct/outside"
chmod 755 "$direct" "$direct/outside"
parent=$direct/parent
child=$parent/child
canary=$direct/outside/canary
printf 'SECRET\n' > "$canary"
chown 0:0 "$canary"
chmod 600 "$canary"
chown 0:33 "$parent"
chmod 1770 "$parent"
mkdir "$child"
chown 33:33 "$child"
chmod 755 "$child"
printf 'clip\n' > "$child/keep.wav"
chown 33:33 "$child/keep.wav"
pause=$tmp/direct.pause
: > "$pause"
(
	ORP_ATTR_PAUSE_FILE=$pause ORP_ATTR_PAUSE_PATH=$child \
		bench_chmod 0755 "$child"
) >"$tmp/direct.out" 2>"$tmp/direct.err" &
dpid=$!
if ! wait_ready "$pause"; then
	bad "bench_chmod did not reach the pause after its checks"
	cat "$tmp/direct.err" >&2 || true
	rm -f "$pause"
	wait "$dpid" || true
else
	swap_as_web "$child" "$canary"
	rm -f "$pause"
	set +e
	wait "$dpid"
	drc=$?
	set -e
	if [ "$drc" -ne 0 ] && canary_intact "$canary" && [ "$(cat "$child.aside/keep.wav")" = "clip" ]; then
		ok "bench_chmod does not follow a uid 33 symlink swap"
	else
		bad "bench_chmod race rc=$drc mode=$(stat -c %a "$canary")"
		cat "$tmp/direct.err" >&2 || true
	fi
fi

# bench_chown uses the same no-follow descriptor.
rm -rf "$child.aside"
rm -f "$child"
mkdir "$child"
chown 33:33 "$child"
chmod 755 "$child"
pause=$tmp/chown.pause
: > "$pause"
(
	ORP_ATTR_PAUSE_FILE=$pause ORP_ATTR_PAUSE_PATH=$child \
		bench_chown 0:0 "$child"
) >"$tmp/chown.out" 2>"$tmp/chown.err" &
cpid=$!
if ! wait_ready "$pause"; then
	bad "bench_chown did not reach the pause after its checks"
	cat "$tmp/chown.err" >&2 || true
	rm -f "$pause"
	wait "$cpid" || true
else
	swap_as_web "$child" "$canary"
	rm -f "$pause"
	set +e
	wait "$cpid"
	crc=$?
	set -e
	if [ "$crc" -ne 0 ] && canary_intact "$canary" && [ "$(stat -c %u:%a "$canary")" = "0:600" ]; then
		ok "bench_chown does not follow a uid 33 symlink swap"
	else
		bad "bench_chown race rc=$crc owner=$(stat -c %u:%a "$canary")"
		cat "$tmp/chown.err" >&2 || true
	fi
fi

# A real directory still changes, and an already-present symlink is refused.
real=$direct/real
mkdir "$real"
if bench_chmod 0700 "$real" && [ "$(stat -c %a "$real")" = "700" ]; then
	ok "bench_chmod changes the opened directory"
else
	bad "bench_chmod did not change a real directory"
fi
ln -s "$canary" "$direct/already"
if bench_chmod 0755 "$direct/already" 2>"$tmp/already.err"; then
	bad "an existing symlink was chmodded"
else
	ok "an existing symlink is refused before chmod"
fi
if canary_intact "$canary"; then
	ok "the canary stayed 0600 after the present-symlink refusal"
else
	bad "the present-symlink refusal changed the canary"
fi

# Installer reaches install_web_child, then the same swap happens.
root=$tmp/install
orp_mkdir "$root" "$root/etc" "$root/var/lib/orp-test" "$root/usr/local/bin" "$root/usr/local/share/svxlink" \
	"$root/usr/local/sbin" "$root/opt/orp-test" "$root/etc/svxlink" "$root/etc/nginx/sites-enabled" \
	"$root/outside" "$root/var/www/openrepeater/sounds/courtesy_tones" \
	"$root/usr/local/share/svxlink/sounds/en_US"
chmod 755 "$root" "$root/var" "$root/var/www" "$root/var/www/openrepeater" "$root/outside"
printf 'orp-test\n' > "$root/etc/hostname"
printf 'aarch64\n' > "$root/etc/orp-arch"
cat > "$root/etc/os-release" <<'EOF'
ID=debian
VERSION_ID="13"
VERSION_CODENAME=trixie
EOF
printf 'guard\n' > "$root/etc/orp-test-image"
printf 'done\n' > "$root/var/lib/orp-test/complete"
printf 'bin\n' > "$root/usr/local/bin/svxlink"
printf 'share\n' > "$root/usr/local/share/svxlink/keep"
printf 'bootstrap\n' > "$root/usr/local/sbin/orp-test-bootstrap.sh"
printf 'archive\n' > "$root/opt/orp-test/keep"
printf 'stock-svxlink\n' > "$root/etc/svxlink/svxlink.conf"
printf 'default-site\n' > "$root/etc/nginx/sites-enabled/default"
printf 'heather-canary\n' > "$root/usr/local/share/svxlink/sounds/en_US/heather.wav"
plant_native_layout "$root"
chown 0:33 "$root/var/www/openrepeater/sounds"
chmod 1770 "$root/var/www/openrepeater/sounds"
chown 33:33 "$root/var/www/openrepeater/sounds/courtesy_tones"
chmod 755 "$root/var/www/openrepeater/sounds/courtesy_tones"
printf 'user-clip\n' > "$root/var/www/openrepeater/sounds/courtesy_tones/keep.wav"
chown 33:33 "$root/var/www/openrepeater/sounds/courtesy_tones/keep.wav"
orp_mkdir "$root/var/lib/openrepeater/db"
printf 'db-sentinel\n' > "$root/var/lib/openrepeater/db/openrepeater.db"
chmod 600 "$root/var/lib/openrepeater/db/openrepeater.db"
printf 'SECRET\n' > "$root/outside/canary"
chown 0:0 "$root/outside/canary"
chmod 600 "$root/outside/canary"
heather=$(sha256sum "$root/usr/local/share/svxlink/sounds/en_US/heather.wav" | awk '{print $1}')
dbsum=$(sha256sum "$root/var/lib/openrepeater/db/openrepeater.db" | awk '{print $1}')
cat > "$tmp/systemctl" <<'EOF'
#!/bin/bash
echo "$*" >> "${ORP_SYSTEMCTL_LOG:?}"
case "$1" in
	is-enabled) echo masked; exit 1 ;;
	is-active) echo inactive; exit 3 ;;
	*) exit 0 ;;
esac
EOF
chmod 755 "$tmp/systemctl"
: > "$tmp/systemctl.log"
child=$root/var/www/openrepeater/sounds/courtesy_tones
icanary=$root/outside/canary
pause=$tmp/install.pause
: > "$pause"
(
	ORP_BENCH_TEST_HARNESS=1 ORP_INSTALL_OFFLINE=1 ORP_ROOT="$root" \
		ORP_SYSTEMCTL="$tmp/systemctl" ORP_SYSTEMCTL_LOG="$tmp/systemctl.log" \
		ORP_BOOTSTRAP_ACTIVE=0 ORP_PHP_FPM_SOCK=/run/php/php8.4-fpm.sock \
		ORP_ATTR_PAUSE_FILE=$pause ORP_ATTR_PAUSE_PATH=$child \
		"$INSTALL" >"$tmp/install.out" 2>"$tmp/install.err"
) &
ipid=$!
if ! wait_ready "$pause"; then
	bad "installer did not pause at the courtesy directory"
	cat "$tmp/install.err" >&2 || true
	rm -f "$pause"
	wait "$ipid" || true
else
	swap_as_web "$child" "$icanary"
	rm -f "$pause"
	set +e
	wait "$ipid"
	irc=$?
	set -e
	wav=$child.aside/keep.wav
	if [ "$irc" -ne 0 ] && canary_intact "$icanary" \
		&& [ -f "$wav" ] && [ "$(cat "$wav")" = "user-clip" ] \
		&& [ "$(sha256sum "$root/usr/local/share/svxlink/sounds/en_US/heather.wav" | awk '{print $1}')" = "$heather" ] \
		&& [ "$(sha256sum "$root/var/lib/openrepeater/db/openrepeater.db" | awk '{print $1}')" = "$dbsum" ]
	then
		ok "installer child chmod does not follow a uid 33 symlink swap"
	else
		bad "installer race rc=$irc canary=$(stat -c %a "$icanary" 2>/dev/null || echo missing)"
		cat "$tmp/install.err" >&2 || true
	fi
fi

if [ "$fail" -ne 0 ]; then
	exit 1
fi
echo "anchor chmod race checks passed"
