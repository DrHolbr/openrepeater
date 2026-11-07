#!/bin/bash
# Shared target checks for the bench UI installer.
# ROOT is a path prefix. Empty ROOT means the real filesystem root.

p() {
	printf '%s%s' "${ROOT}" "$1"
}

orp_systemctl() {
	if [ -n "${ORP_SYSTEMCTL:-}" ]; then
		"${ORP_SYSTEMCTL}" "$@"
	else
		systemctl "$@"
	fi
}

unit_enabled_state() {
	local out
	set +e
	out=$(orp_systemctl is-enabled "$1" 2>/dev/null)
	set -e
	printf '%s' "$out"
}

unit_active_state() {
	local out
	set +e
	out=$(orp_systemctl is-active "$1" 2>/dev/null)
	set -e
	printf '%s' "$out"
}

bench_hostname() {
	local file host
	file=$(p /etc/hostname)
	if [ ! -f "$file" ]; then
		printf '%s' ""
		return
	fi
	tr -d '[:space:]' < "$file"
}

bench_arch() {
	if [ -n "${ROOT}" ]; then
		if [ -f "$(p /etc/orp-arch)" ]; then
			tr -d '[:space:]' < "$(p /etc/orp-arch)"
			return
		fi
	fi
	uname -m
}

bench_os_value() {
	local key file
	key=$1
	file=$(p /etc/os-release)
	if [ ! -f "$file" ]; then
		printf '%s' ""
		return
	fi
	sed -n "s/^${key}=//p" "$file" | head -n 1 | tr -d '"'
}

bench_assert_identity() {
	local host arch codename version live
	host=$(bench_hostname)
	arch=$(bench_arch)
	codename=$(bench_os_value VERSION_CODENAME)
	version=$(bench_os_value VERSION_ID)
	if [ "$host" != "orp-test" ]; then
		echo "refused: hostname is '${host}', expected orp-test" >&2
		return 2
	fi
	if [ -z "${ROOT}" ]; then
		live=$(hostname)
		if [ "$live" != "orp-test" ]; then
			echo "refused: live hostname is '${live}', expected orp-test" >&2
			return 2
		fi
	fi
	if [ "$arch" != "aarch64" ]; then
		echo "refused: architecture is '${arch}', expected aarch64" >&2
		return 2
	fi
	if [ "$codename" != "trixie" ] || [ "$version" != "13" ]; then
		echo "refused: OS is ${codename:-unknown} ${version:-unknown}, expected Debian 13 trixie" >&2
		return 2
	fi
	if [ ! -f "$(p /etc/orp-test-image)" ]; then
		echo "refused: /etc/orp-test-image guard is absent" >&2
		return 2
	fi
	return 0
}

bench_assert_bootstrap_idle() {
	local state unit
	if [ ! -f "$(p /var/lib/orp-test/complete)" ]; then
		echo "refused: bootstrap completion marker /var/lib/orp-test/complete is absent" >&2
		return 3
	fi
	for unit in orp-test-bootstrap.service orp-test-bootstrap; do
		state=$(unit_active_state "$unit")
		case "$state" in
			active|activating)
				echo "refused: ${unit} is ${state}; not installing over the bootstrap build" >&2
				return 3
				;;
		esac
	done
	return 0
}

bench_assert_masks() {
	local unit state
	for unit in svxlink.service remotetrx.service svxreflector.service; do
		state=$(unit_enabled_state "$unit")
		if [ "$state" != "masked" ]; then
			echo "refused: ${unit} is '${state}', expected masked" >&2
			return 4
		fi
	done
	return 0
}

bench_free_kib() {
	df -Pk "$(p /)" | awk 'NR==2 {print $4}'
}

# Paths the bootstrap owns. The installer records them and checks them again.
BENCH_PROTECTED_PATHS=(
	etc/orp-test-image
	var/lib/orp-test/complete
	var/lib/orp-test/build
	var/lib/orp-test/build.swap
	usr/local/bin/svxlink
	usr/local/share/svxlink
	opt/orp-test
	usr/local/sbin/orp-test-bootstrap.sh
	etc/svxlink
)

bench_hash_path() {
	local full rel
	rel=$1
	full=$(p "/${rel}")
	if [ ! -e "$full" ]; then
		printf 'ABSENT %s\n' "$rel"
		return
	fi
	if [ -d "$full" ]; then
		local sum
		sum=$(find "$full" -type f -print | LC_ALL=C sort | while IFS= read -r file; do
			sha256sum "$file"
		done | sha256sum | awk '{print $1}')
		printf '%s %s\n' "$sum" "$rel"
		return
	fi
	sha256sum "$full" | awk -v rel="$rel" '{print $1, rel}'
}

bench_snapshot_protected() {
	local rel dest
	dest=$(p /var/backups/orp-ui/protected.sha256)
	mkdir -p "$(dirname "$dest")"
	: > "$dest"
	for rel in "${BENCH_PROTECTED_PATHS[@]}"; do
		bench_hash_path "$rel" >> "$dest"
	done
}

bench_verify_protected() {
	local dest now rel
	dest=$(p /var/backups/orp-ui/protected.sha256)
	now=$(mktemp)
	for rel in "${BENCH_PROTECTED_PATHS[@]}"; do
		bench_hash_path "$rel" >> "$now"
	done
	if ! cmp -s "$dest" "$now"; then
		echo "refused: bootstrap or svxlink path changed during install" >&2
		diff -u "$dest" "$now" >&2 || true
		rm -f "$now"
		return 4
	fi
	rm -f "$now"
	return 0
}

bench_render_nginx() {
	local sock dest
	sock=$1
	dest=$2
	case "$sock" in
		*php5*|*php7*)
			echo "refused: php-fpm socket is not PHP 8 (${sock})" >&2
			return 5
			;;
		*php8*)
			;;
		*)
			echo "refused: php-fpm socket is not PHP 8 (${sock})" >&2
			return 5
			;;
	esac
	sed "s|__PHP_FPM_SOCK__|${sock}|g" "$NGINX_TEMPLATE" > "$dest"
	if grep -q '__PHP_FPM_SOCK__' "$dest"; then
		echo "refused: nginx socket placeholder was not replaced" >&2
		return 5
	fi
	if grep -E -q 'php5-fpm|ssl[[:space:]]+on|listen[[:space:]]+443' "$dest"; then
		echo "refused: nginx site still contains legacy TLS or PHP 5" >&2
		return 5
	fi
	return 0
}
