#!/bin/bash
# Fixture checks for the bench installer and orp_helper. No apt, no radio, no GPIO.
set -euo pipefail

ROOT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
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
}

checksum() { sha256sum "$1" | awk '{print $1}'; }

tmp=$(mktemp -d)
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
set +e
ORP_INSTALL_OFFLINE=1 ORP_ROOT="$good" ORP_SYSTEMCTL="$bin/systemctl" ORP_SYSTEMCTL_LOG="$log" \
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
printf 'preserve\n' >> "$db"
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

if [ "$fail" -ne 0 ]; then
	echo "shell checks failed" >&2
	exit 1
fi
echo "shell checks passed"
exit 0
