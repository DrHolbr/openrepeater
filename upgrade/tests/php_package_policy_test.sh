#!/bin/bash
# Fixture for the Trixie PHP 8.4 candidate check. No apt network and no Pi.
set -euo pipefail

ROOT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
# shellcheck source=lib/fixture_tmpdir.sh
. "$ROOT_DIR/upgrade/tests/lib/fixture_tmpdir.sh"
# shellcheck source=../lib/bench-target.sh
. "$ROOT_DIR/upgrade/lib/bench-target.sh"
orp_use_fixture_tmpdir

tmp=$(orp_mktemp_dir)
trap 'orp_cleanup_fixture "$tmp"' EXIT
state="$tmp/state"
log="$tmp/apt.log"
: > "$state"
: > "$log"

write_pi_sources() {
	orp_mkdir "$tmp/root" "$tmp/root/etc/apt/sources.list.d"
	cat > "$tmp/root/etc/apt/sources.list.d/debian.sources" <<'EOF'
# Raspberry Pi OS Trixie keeps Debian and Debian security as separate stanzas.
Types: deb
URIs: http://deb.debian.org/debian
Suites: trixie trixie-updates
Components: main contrib non-free non-free-firmware
Signed-By: /usr/share/keyrings/debian-archive-keyring.gpg

Types: deb
URIs: http://deb.debian.org/debian-security
Suites: trixie-security
Components: main contrib non-free non-free-firmware
Signed-By: /usr/share/keyrings/debian-archive-keyring.gpg

# deb-src is not an install source
Types: deb-src
URIs: http://deb.debian.org/debian
Suites: trixie
Components: main
Enabled: no
EOF
	cat > "$tmp/root/etc/apt/sources.list.d/raspi.sources" <<'EOF'
Types: deb
URIs: http://archive.raspberrypi.com/debian
Suites: trixie
Components: main
EOF
	cat > "$tmp/root/etc/apt/sources.list.d/debian.sources.bak" <<'EOF'
Types: deb
URIs: http://deb.debian.org/debian-security
Suites: trixie-security
Components: main
Enabled: no
EOF
}
write_pi_sources

seed_pkg() {
	local pkg=$1 installed=$2 candidate=$3
	printf '%s %s %s\n' "$pkg" "$installed" "$candidate" >> "$state"
}

reset_state() {
	: > "$state"
	: > "$log"
	seed_pkg php8.4-fpm "$1" "$2"
	seed_pkg php8.4-cli "$3" "$4"
	seed_pkg php8.4-sqlite3 "$5" "$6"
	seed_pkg php8.4-common "$4" "$4"
	seed_pkg php8.4-opcache "$4" "$4"
	seed_pkg php8.4-zip "$5" "$6"
}

cat > "$tmp/apt-get" <<'EOF'
#!/bin/bash
echo "$*" >> "${PHP_APT_LOG:?}"
if [ "$1" = "install" ]; then
	shift
	while [ $# -gt 0 ]; do
		case "$1" in
			-*) shift; continue ;;
		esac
		pkg=$1
		shift
		if [ "${PHP_APT_STICK:-0}" = 1 ]; then
			continue
		fi
		tmp_state=$(mktemp)
		while read -r name inst cand; do
			if [ "$name" = "$pkg" ]; then
				inst=$cand
			fi
			printf '%s %s %s\n' "$name" "$inst" "$cand"
		done < "${PHP_APT_STATE:?}" > "$tmp_state"
		mv "$tmp_state" "$PHP_APT_STATE"
	done
fi
exit 0
EOF
cat > "$tmp/apt-cache" <<'EOF'
#!/bin/bash
pkg=$2
installed='(none)'
candidate=
while read -r name inst cand; do
	if [ "$name" = "$pkg" ]; then
		installed=$inst
		candidate=$cand
	fi
done < "${PHP_APT_STATE:?}"
printf 'Installed: %s\n' "$installed"
printf 'Candidate: %s\n' "$candidate"
printf 'Version table:\n'
if [ -n "$candidate" ] && [ "$candidate" != "(none)" ]; then
	printf ' *** %s 500\n' "$candidate"
	origin_file="${PHP_APT_ORIGINS:-}/$pkg"
	if [ -f "$origin_file" ]; then
		while read -r uri suite; do
			[ -n "$uri" ] || continue
			printf '        500 %s %s/main arm64 Packages\n' "$uri" "$suite"
		done < "$origin_file"
	else
		printf '        500 http://deb.debian.org/debian-security trixie-security/main arm64 Packages\n'
	fi
fi
EOF
chmod 755 "$tmp/apt-get" "$tmp/apt-cache"

run_php() {
	ROOT="$tmp/root" ORP_APT_GET="$tmp/apt-get" ORP_APT_CACHE="$tmp/apt-cache" \
		PHP_APT_LOG="$log" PHP_APT_STATE="$state" PHP_APT_STICK="${1:-0}" \
		bench_install_php84
}

reset_state 8.4.11-1 8.4.16-1+deb13u1 8.4.16-1+deb13u1 8.4.16-1+deb13u1 '(none)' 8.4.16-1+deb13u1
if run_php 0; then
	echo "ok: stale and missing PHP 8.4 packages are installed to the candidate"
else
	echo "FAIL: stale PHP was not accepted" >&2
	exit 1
fi
if grep -q -- '--no-upgrade' "$log"; then
	echo "FAIL: PHP install used --no-upgrade" >&2
	exit 1
fi
if grep -Eq 'dist-upgrade|full-upgrade|nginx|php8\.3|php-fpm ' "$log"; then
	echo "FAIL: PHP install was not limited to php8.4 packages" >&2
	cat "$log" >&2
	exit 1
fi
grep -q 'php8.4-fpm' "$log"
grep -q 'php8.4-sqlite3' "$log"
grep -q 'php8.4-zip' "$log"
if grep -q 'install -y --no-install-recommends php8.4-cli' "$log"; then
	echo "FAIL: an already-current PHP package was reinstalled" >&2
	exit 1
fi
echo "ok: already-current php8.4-cli was not reinstalled"

reset_state 8.4.16-1+deb13u1 8.4.16-1+deb13u1 8.4.16-1+deb13u1 8.4.16-1+deb13u1 8.4.16-1+deb13u1 8.4.16-1+deb13u1
if run_php 0; then
	echo "ok: PHP already at the candidate does not need an install"
else
	echo "FAIL: current PHP was refused" >&2
	exit 1
fi
if grep -q '^install ' "$log"; then
	echo "FAIL: current PHP still called install" >&2
	exit 1
fi

reset_state 8.3.30-1 8.3.31-1 8.4.16-1 8.4.16-1 8.4.16-1 8.4.16-1
set +e
run_php 0 >"$tmp/old.out" 2>"$tmp/old.err"
rc=$?
set -e
if [ "$rc" -ne 0 ] && grep -q 'expected PHP 8.4' "$tmp/old.err" && ! grep -q '^install ' "$log"; then
	echo "ok: a non-8.4 candidate is refused before install"
else
	echo "FAIL: non-8.4 candidate rc=$rc" >&2
	cat "$tmp/old.err" >&2
	exit 1
fi

rm -rf "$tmp/root/etc/apt"
set +e
run_php 0 >"$tmp/nosec.out" 2>"$tmp/nosec.err"
rc=$?
set -e
if [ "$rc" -ne 0 ] && grep -q 'refused:' "$tmp/nosec.err"; then
	echo "ok: missing trixie-security is refused"
else
	echo "FAIL: missing security suite rc=$rc" >&2
	exit 1
fi

write_pi_sources
reset_state 8.4.11-1 8.4.16-1 8.4.16-1 8.4.16-1 8.4.16-1 8.4.16-1
set +e
run_php 1 >"$tmp/stick.out" 2>"$tmp/stick.err"
rc=$?
set -e
if [ "$rc" -ne 0 ] && grep -q 'is not the apt candidate' "$tmp/stick.err"; then
	echo "ok: install that leaves PHP behind the candidate is refused"
else
	echo "FAIL: sticky stale PHP rc=$rc" >&2
	cat "$tmp/stick.err" >&2
	exit 1
fi

NGINX_TEMPLATE="$ROOT_DIR/upgrade/nginx/openrepeater.conf.template"
set +e
bench_render_nginx /run/php/php8.3-fpm.sock "$tmp/bad-site" >"$tmp/sock.out" 2>"$tmp/sock.err"
rc=$?
set -e
if [ "$rc" -ne 0 ] && grep -q 'not Debian PHP 8.4' "$tmp/sock.err"; then
	echo "ok: php8.3 fpm socket is rejected"
else
	echo "FAIL: php8.3 socket rc=$rc" >&2
	exit 1
fi

if grep -n -- '--no-upgrade' "$ROOT_DIR/upgrade/install-orp-ui.sh" | grep -E 'php8\.4|php-fpm|php-cli|php-sqlite3'; then
	echo "FAIL: installer still applies --no-upgrade to PHP" >&2
	exit 1
fi
echo "ok: installer --no-upgrade does not cover PHP"

disabled="$tmp/disabled-root"
orp_mkdir "$disabled" "$disabled/etc/apt/sources.list.d"
cat > "$disabled/etc/apt/sources.list.d/debian.sources" <<'EOF'
# Suites: trixie-security
Types: deb
URIs: http://deb.debian.org/debian
Suites: trixie trixie-updates
Components: main

Types: deb
URIs: http://deb.debian.org/debian-security
Suites: trixie-security
Components: main
Enabled: no
EOF
if ROOT="$disabled" bench_php_security_enabled; then
	echo "FAIL: Enabled: no security stanza was accepted" >&2
	exit 1
fi
echo "ok: disabled deb822 trixie-security is not an enabled source"

orp_mkdir "$tmp/origins"
cat > "$tmp/origins/php8.4-fpm" <<'EOF'
http://deb.debian.org/debian-security trixie-security
https://packages.example.com/php trixie
EOF
for pkg in php8.4-cli php8.4-common php8.4-sqlite3 php8.4-opcache php8.4-zip; do
	printf '%s\n' 'http://deb.debian.org/debian-security trixie-security' > "$tmp/origins/$pkg"
done
reset_state 8.4.27-1~deb13u1 8.4.27-1~deb13u1 8.4.27-1~deb13u1 8.4.27-1~deb13u1 8.4.27-1~deb13u1 8.4.27-1~deb13u1
set +e
ROOT="$tmp/root" ORP_APT_GET="$tmp/apt-get" ORP_APT_CACHE="$tmp/apt-cache" \
	PHP_APT_LOG="$log" PHP_APT_STATE="$state" PHP_APT_ORIGINS="$tmp/origins" PHP_APT_STICK=0 \
	bench_install_php84 >"$tmp/third.out" 2>"$tmp/third.err"
rc=$?
set -e
if [ "$rc" -ne 0 ] && grep -q 'outside Debian' "$tmp/third.err" && ! grep -q '^install ' "$log"; then
	echo "ok: same-version third-party origin is refused"
else
	echo "FAIL: third-party origin rc=$rc" >&2
	cat "$tmp/third.err" >&2
	exit 1
fi
echo "php package policy checks passed"
