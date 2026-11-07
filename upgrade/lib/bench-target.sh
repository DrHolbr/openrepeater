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
	if [ -L "$full" ]; then
		printf 'LINK %s %s\n' "$(readlink "$full")" "$rel"
		return
	fi
	if [ -d "$full" ]; then
		local sum
		sum=$(find -P "$full" -xdev ! -type l -type f -print | LC_ALL=C sort | while IFS= read -r file; do
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
	bench_anchor_dir "$(dirname "$dest")"
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
		*php8.4-fpm.sock) ;;
		*)
			echo "refused: php-fpm socket is not Debian PHP 8.4 (${sock})" >&2
			return 5
			;;
	esac
	local rendered
	rendered=$(mktemp)
	sed "s|__PHP_FPM_SOCK__|${sock}|g" "$NGINX_TEMPLATE" > "$rendered"
	if ! bench_place_file "$rendered" "$dest"; then
		rm -f "$rendered"
		return 5
	fi
	rm -f "$rendered"
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

# A privileged chmod/chown/create is safe only for a direct child of a trust
# anchor: a real directory owned by the installer and not writable by group
# or other. Inspecting a path inside a www-data-writable directory and then
# chmod/chown is not safe. test -f and chmod follow symlinks, and the leaf
# can be swapped, or an ancestor can be a symlink, after the check.

bench_test_harness_allowed() {
	[ "${ORP_BENCH_TEST_HARNESS:-}" = 1 ] || return 1
	local real
	real=$(tr -d '[:space:]' < /etc/hostname 2>/dev/null || true)
	[ "$real" = "orp-test" ] && return 1
	[ -f /etc/openrepeater/bench-mode ] && return 1
	return 0
}

bench_installer_uid() {
	id -u
}

bench_lstat_kind() {
	local path=$1
	if [ -L "$path" ]; then
		printf '%s' symlink
		return
	fi
	if [ ! -e "$path" ]; then
		printf '%s' missing
		return
	fi
	if [ -d "$path" ]; then
		printf '%s' dir
		return
	fi
	if [ -f "$path" ]; then
		printf '%s' file
		return
	fi
	printf '%s' other
}

bench_nonowner_can_write() {
	local mode=$((8#$1))
	[ $((mode & 0022)) -ne 0 ]
}

bench_assert_anchor() {
	local dir=$1
	local uid mode
	[ "$(bench_lstat_kind "$dir")" = dir ] || return 1
	uid=$(stat -c %u "$dir")
	mode=$(stat -c %a "$dir")
	[ "$uid" = "$(bench_installer_uid)" ] || return 1
	if bench_nonowner_can_write "$mode"; then
		return 1
	fi
	return 0
}

bench_require_real_components() {
	local path=$1
	local prefix rel acc rest part kind
	case "$path" in
		/*) ;;
		*)
			echo "refused: relative path $path" >&2
			return 1
			;;
	esac
	case "$path" in
		*$'\n'*|*'..'*|*'//'*)
			echo "refused: unsafe path $path" >&2
			return 1
			;;
	esac
	if [ -n "${ROOT:-}" ]; then
		prefix=$ROOT
		case "$path" in
			"$ROOT"|"$ROOT"/*) rel=${path#"$ROOT"} ;;
			*)
				echo "refused: $path is outside the install root" >&2
				return 1
				;;
		esac
		acc=$prefix
		if ! bench_assert_anchor "$acc"; then
			echo "refused: install root $acc is not a trust anchor" >&2
			return 1
		fi
	else
		acc=
		rel=$path
		if ! bench_assert_anchor /; then
			echo "refused: / is not a trust anchor" >&2
			return 1
		fi
	fi
	rest=${rel#/}
	while [ -n "$rest" ]; do
		part=${rest%%/*}
		if [ "$rest" = "$part" ]; then
			rest=
		else
			rest=${rest#*/}
		fi
		[ -n "$part" ] || continue
		if [ "$part" = "." ] || [ "$part" = ".." ]; then
			echo "refused: unsafe component in $path" >&2
			return 1
		fi
		acc="${acc}/${part}"
		kind=$(bench_lstat_kind "$acc")
		if [ "$kind" = symlink ]; then
			echo "refused: symbolic link in trusted path: $acc" >&2
			return 1
		fi
		if [ "$kind" = missing ]; then
			return 0
		fi
	done
	return 0
}

bench_chown() {
	local spec=$1
	local path=$2
	bench_require_real_components "$path" || return 1
	if [ "$(bench_lstat_kind "$path")" = symlink ]; then
		echo "refused: not chowning symbolic link $path" >&2
		return 1
	fi
	if [ -n "${ORP_CHOWN_LOG:-}" ]; then
		printf '%s %s %s\n' "" "$spec" "$path" >> "$ORP_CHOWN_LOG"
	fi
	if [ "${ORP_INSTALL_OFFLINE:-0}" = 1 ] && ! bench_apply_real_ownership; then
		return 0
	fi
	chown -h "$spec" "$path"
}

# Real chown during an offline fixture run is allowed only for the cloud
# harness. On hostname orp-test the harness is refused, so this cannot retarget
# ownership of the bench.
bench_apply_real_ownership() {
	[ "${ORP_INSTALL_APPLY_OWNERSHIP:-0}" = 1 ] || return 1
	bench_test_harness_allowed
}

bench_chmod() {
	local mode=$1
	local path=$2
	bench_require_real_components "$path" || return 1
	if [ "$(bench_lstat_kind "$path")" = symlink ]; then
		echo "refused: not chmodding symbolic link $path" >&2
		return 1
	fi
	if [ "$(bench_lstat_kind "$path")" = missing ]; then
		echo "refused: not chmodding missing path $path" >&2
		return 1
	fi
	chmod "$mode" "$path"
}

bench_anchor_dir() {
	local path=$1
	local prefix rel acc rest part kind
	if [ -n "${ROOT:-}" ]; then
		prefix=$ROOT
		case "$path" in
			"$ROOT"|"$ROOT"/*) rel=${path#"$ROOT"} ;;
			*)
				echo "refused: $path is outside the install root" >&2
				return 1
				;;
		esac
		if ! bench_assert_anchor "$prefix"; then
			echo "refused: install root $prefix is not a trust anchor" >&2
			return 1
		fi
		acc=$prefix
	else
		if ! bench_assert_anchor /; then
			echo "refused: / is not a trust anchor" >&2
			return 1
		fi
		acc=
		rel=$path
	fi
	rest=${rel#/}
	if [ -n "${ROOT:-}" ] && [ "$path" = "$ROOT" ]; then
		return 0
	fi
	while [ -n "$rest" ]; do
		part=${rest%%/*}
		if [ "$rest" = "$part" ]; then
			rest=
		else
			rest=${rest#*/}
		fi
		[ -n "$part" ] || continue
		acc="${acc}/${part}"
		kind=$(bench_lstat_kind "$acc")
		case "$kind" in
			symlink)
				echo "refused: symbolic link at $acc" >&2
				return 1
				;;
			missing)
				mkdir "$acc"
				chmod 755 "$acc"
				;;
			dir)
				if ! bench_assert_anchor "$acc"; then
					chmod 755 "$acc"
					if [ "${ORP_INSTALL_OFFLINE:-0}" != 1 ]; then
						chown -h "$(bench_installer_uid):$(id -g)" "$acc"
					fi
					if ! bench_assert_anchor "$acc"; then
						echo "refused: $acc is still writable by someone other than the installer" >&2
						return 1
					fi
				fi
				;;
			*)
				echo "refused: $acc is not a directory" >&2
				return 1
				;;
		esac
	done
	return 0
}

bench_place_file() {
	local src=$1
	local dest=$2
	local dir kind tmp
	dir=$(dirname "$dest")
	bench_anchor_dir "$dir" || return 1
	kind=$(bench_lstat_kind "$dest")
	case "$kind" in
		symlink)
			echo "refused: not writing through symbolic link $dest" >&2
			return 1
			;;
		dir|other)
			echo "refused: $dest is not a regular file" >&2
			return 1
			;;
	esac
	tmp=$(mktemp "$dir/.orp.XXXXXX")
	cp "$src" "$tmp"
	if [ "$(bench_lstat_kind "$dest")" = symlink ]; then
		rm -f "$tmp"
		echo "refused: $dest became a symbolic link" >&2
		return 1
	fi
	mv -f "$tmp" "$dest"
}

bench_ensure_regular() {
	local dest=$1
	local kind
	kind=$(bench_lstat_kind "$dest")
	case "$kind" in
		symlink)
			echo "refused: symbolic link at $dest" >&2
			return 1
			;;
		dir|other)
			echo "refused: $dest is not a regular file" >&2
			return 1
			;;
		missing|file)
			return 0
			;;
	esac
	return 1
}

# Debian Trixie PHP 8.4 from the already enabled security suite.
# These three packages may be installed or upgraded to the apt candidate.
# Nothing else is upgraded here. No third-party PHP repository is added.
BENCH_PHP84_PACKAGES=(php8.4-fpm php8.4-cli php8.4-sqlite3)

bench_apt() {
	if [ -n "${ORP_APT_GET:-}" ]; then
		"${ORP_APT_GET}" "$@"
	else
		apt-get "$@"
	fi
}

bench_apt_cache() {
	if [ -n "${ORP_APT_CACHE:-}" ]; then
		"${ORP_APT_CACHE}" "$@"
	else
		apt-cache "$@"
	fi
}

bench_php_security_enabled() {
	local dir file
	dir="${ROOT:-}/etc/apt"
	if [ ! -d "$dir" ]; then
		echo "refused: apt sources directory $dir is absent" >&2
		return 1
	fi
	if grep -R -l -E --include='sources.list' --include='*.list' --include='*.sources' '^[^#]*trixie-security' "$dir" >/dev/null 2>&1; then
		return 0
	fi
	echo "refused: Debian trixie-security is not enabled in $dir" >&2
	return 1
}

bench_php_policy_field() {
	local pkg=$1
	local field=$2
	bench_apt_cache policy "$pkg" | awk -v field="${field}:" '$1 == field { print $2; exit }'
}

bench_php_candidate_is_84() {
	local ver=$1
	ver=${ver#*:}
	case "$ver" in
		8.4.*) return 0 ;;
		*) return 1 ;;
	esac
}

# Refresh apt, then install or upgrade only the PHP 8.4 runtime and the
# sqlite3 extension up to the candidate from the enabled distro repositories.
# --no-upgrade is intentionally not used here: a reinstall must not keep an
# older installed PHP when the candidate is newer. Returns 0 only when each
# package's installed version equals that candidate.
bench_install_php84() {
	local pkg installed candidate
	local -a stale=()
	if ! bench_apt update; then
		echo "refused: apt-get update failed" >&2
		return 5
	fi
	if ! bench_php_security_enabled; then
		return 5
	fi
	for pkg in "${BENCH_PHP84_PACKAGES[@]}"; do
		candidate=$(bench_php_policy_field "$pkg" Candidate)
		installed=$(bench_php_policy_field "$pkg" Installed)
		if [ -z "$candidate" ] || [ "$candidate" = "(none)" ]; then
			echo "refused: apt has no candidate for ${pkg}" >&2
			return 5
		fi
		if ! bench_php_candidate_is_84 "$candidate"; then
			echo "refused: candidate for ${pkg} is ${candidate}, expected PHP 8.4 from Debian" >&2
			return 5
		fi
		if [ "$installed" != "$candidate" ]; then
			stale+=("$pkg")
		fi
	done
	if [ "${#stale[@]}" -gt 0 ]; then
		if ! bench_apt install -y --no-install-recommends "${stale[@]}"; then
			echo "refused: PHP 8.4 package install failed" >&2
			return 5
		fi
	fi
	for pkg in "${BENCH_PHP84_PACKAGES[@]}"; do
		candidate=$(bench_php_policy_field "$pkg" Candidate)
		installed=$(bench_php_policy_field "$pkg" Installed)
		if [ "$installed" != "$candidate" ] || ! bench_php_candidate_is_84 "$installed"; then
			echo "refused: ${pkg} installed (${installed:-none}) is not the apt candidate (${candidate:-none})" >&2
			return 5
		fi
	done
	return 0
}
