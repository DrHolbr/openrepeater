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

# A trusted functional-test token is a regular file, not a symlink, not
# group or world writable, and owned by root. A fixture ROOT may be owned
# by the user running the installer. Anything else is not a token.
bench_mode_is_functional_test() {
	local file perm owner token
	file=$(p /etc/openrepeater/operating-mode)
	if [ ! -f "$file" ] || [ -L "$file" ]; then
		return 1
	fi
	perm=$(stat -c %a "$file")
	case "$perm" in
		''|*[!0-7]*) return 1 ;;
	esac
	if [ $((8#$perm & 022)) -ne 0 ]; then
		return 1
	fi
	owner=$(stat -c %u "$file")
	if [ -z "${ROOT}" ]; then
		if [ "$owner" != "0" ]; then
			return 1
		fi
	elif [ "$owner" != "0" ] && [ "$owner" != "$(id -u)" ]; then
		return 1
	fi
	token=$(tr -d '[:space:]' < "$file")
	[ "$token" = "functional-test" ]
}

# Masked units are the install state. Functional-test may instead be
# inactive and disabled, and only when the mode token is trusted. An
# enabled unit, a running unit, or a disabled unit without that token
# is refused.
bench_assert_masks() {
	local unit enabled active
	for unit in svxlink.service remotetrx.service svxreflector.service; do
		enabled=$(unit_enabled_state "$unit")
		active=$(unit_active_state "$unit")
		if [ "$enabled" = "masked" ]; then
			continue
		fi
		if bench_mode_is_functional_test && [ "$enabled" = "disabled" ] && [ "$active" = "inactive" ]; then
			continue
		fi
		echo "refused: ${unit} is enabled '${enabled}' active '${active}', expected masked, or inactive and disabled with a functional-test token" >&2
		return 4
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
	if ! grep -q 'location \^~ /modules/' "$dest" \
		|| ! grep -q 'location \^~ /sounds/' "$dest" \
		|| ! grep -q 'location \^~ /backup/' "$dest"
	then
		echo "refused: nginx site does not keep uploaded scripts out of PHP" >&2
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
	# Fixture installs must name an isolated root. This does not read the
	# installed hostname, operating-mode token, or bench marker.
	[ -n "${ORP_ROOT:-}" ] || return 1
	case "${ORP_ROOT}" in
		/|/.|/etc|/etc/*|/usr|/usr/*|/var/www|/var/www/*|/var/lib/openrepeater|/var/lib/openrepeater/*)
			return 1
			;;
	esac
	[ -d "${ORP_ROOT}" ] || return 1
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
	bench_attr_pause "$path"
	bench_fd_apply chown "$spec" "$path"
}

# Real chown during an offline fixture run is allowed only for the cloud
# harness. On hostname orp-test the harness is refused, so this cannot retarget
# ownership of the bench.
bench_apply_real_ownership() {
	[ "${ORP_INSTALL_APPLY_OWNERSHIP:-0}" = 1 ] || return 1
	bench_test_harness_allowed
}

# Pause after the path check and before the file-descriptor operation so a
# test can replace the name. The operation below does not use that name.
bench_attr_pause() {
	local path=$1
	local pause=${ORP_ATTR_PAUSE_FILE:-}
	local want=${ORP_ATTR_PAUSE_PATH:-}
	[ -n "$pause" ] || return 0
	if [ -n "$want" ] && [ "$path" != "$want" ]; then
		return 0
	fi
	: > "${pause}.ready"
	while [ -e "$pause" ]; do
		sleep 0.05
	done
}

# Open each component with O_NOFOLLOW. chmod and chown use the resulting
# descriptor, so a name swapped for a symlink is not followed.
bench_fd_apply() {
	local op=$1
	local spec=$2
	local path=$3
	python3 - "$op" "$spec" "$path" <<'PY'
import grp
import os
import pwd
import sys

op, spec, path = sys.argv[1], sys.argv[2], sys.argv[3]
if not path.startswith("/") or "\0" in path or "//" in path:
    sys.stderr.write("refused: unsafe path %s\n" % path)
    sys.exit(1)
parts = [part for part in path.split("/") if part]
if not parts or any(part in (".", "..") for part in parts):
    sys.stderr.write("refused: unsafe path %s\n" % path)
    sys.exit(1)
dir_flags = os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW | getattr(os, "O_CLOEXEC", 0)
leaf_flags = os.O_RDONLY | os.O_NOFOLLOW | getattr(os, "O_CLOEXEC", 0)
parent = os.open("/", dir_flags)
try:
    for part in parts[:-1]:
        nxt = os.open(part, dir_flags, dir_fd=parent)
        os.close(parent)
        parent = nxt
    leaf = parts[-1]
    if op == "mkdir":
        os.mkdir(leaf, int(spec, 8), dir_fd=parent)
    else:
        opened = os.open(leaf, leaf_flags, dir_fd=parent)
        try:
            if op == "chmod":
                os.fchmod(opened, int(spec, 8))
            elif op == "chown":
                user, group = spec.split(":", 1)
                try:
                    uid = int(user)
                except ValueError:
                    uid = pwd.getpwnam(user).pw_uid
                try:
                    gid = int(group)
                except ValueError:
                    gid = grp.getgrnam(group).gr_gid
                os.fchown(opened, uid, gid)
            else:
                sys.stderr.write("refused: unknown operation %s\n" % op)
                sys.exit(1)
        finally:
            os.close(opened)
except OSError as exc:
    sys.stderr.write("refused: no-follow %s %s: %s\n" % (op, path, exc.strerror))
    sys.exit(1)
finally:
    os.close(parent)
PY
}

# The published tree must not keep the source tree's mode. A read-only
# payload is 0555, and tar applies that to the destination directory.
# Walk with O_NOFOLLOW and fchmod the opened descriptor.
bench_publish_tree_modes() {
	local root=$1
	python3 - "$root" \
		install/scripts/orp_helper \
		upgrade/install-orp-ui.sh \
		upgrade/install-svxlink-sounds.sh \
		upgrade/install_heather_sounds.py \
		upgrade/set-operating-mode.sh \
		upgrade/lib/bench-target.sh <<'PY'
import os
import stat
import sys

root = sys.argv[1]
intended = set(sys.argv[2:])
if not root.startswith("/") or "\0" in root or "//" in root:
    sys.stderr.write("refused: unsafe tree %s\n" % root)
    sys.exit(1)
parts = [part for part in root.split("/") if part]
if not parts or any(part in (".", "..") for part in parts):
    sys.stderr.write("refused: unsafe tree %s\n" % root)
    sys.exit(1)

def open_at(parent, name, directory):
    flags = os.O_RDONLY | os.O_NOFOLLOW | getattr(os, "O_CLOEXEC", 0)
    if directory:
        flags |= os.O_DIRECTORY
    return os.open(name, flags, dir_fd=parent)

def walk(fd, rel):
    os.fchmod(fd, 0o755)
    for name in os.listdir(fd):
        if name in (".", "..") or "/" in name or name in (".", ".."):
            continue
        info = os.lstat(name, dir_fd=fd)
        child_rel = name if rel == "" else rel + "/" + name
        if stat.S_ISLNK(info.st_mode):
            continue
        if stat.S_ISDIR(info.st_mode):
            child = open_at(fd, name, True)
            try:
                walk(child, child_rel)
            finally:
                os.close(child)
        elif stat.S_ISREG(info.st_mode):
            opened = open_at(fd, name, False)
            try:
                os.fchmod(opened, 0o755 if child_rel in intended else 0o644)
            finally:
                os.close(opened)

dir_flags = os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW | getattr(os, "O_CLOEXEC", 0)
fd = os.open("/", dir_flags)
try:
    for part in parts:
        nxt = os.open(part, dir_flags, dir_fd=fd)
        os.close(fd)
        fd = nxt
    walk(fd, "")
except OSError as exc:
    sys.stderr.write("refused: no-follow tree mode %s: %s\n" % (root, exc.strerror))
    sys.exit(1)
finally:
    os.close(fd)
PY
}

bench_mkdir_nofollow() {
	local path=$1
	bench_require_real_components "$path" || return 1
	if [ "$(bench_lstat_kind "$path")" = symlink ]; then
		echo "refused: not mkdir through symbolic link $path" >&2
		return 1
	fi
	if [ "$(bench_lstat_kind "$path")" != missing ]; then
		return 0
	fi
	bench_attr_pause "$path"
	bench_fd_apply mkdir 0755 "$path"
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
	bench_attr_pause "$path"
	bench_fd_apply chmod "$mode" "$path"
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
				bench_fd_apply chmod 755 "$acc"
				;;
			dir)
				if ! bench_assert_anchor "$acc"; then
					bench_fd_apply chmod 755 "$acc"
					if [ "${ORP_INSTALL_OFFLINE:-0}" != 1 ]; then
						bench_fd_apply chown "$(bench_installer_uid):$(id -g)" "$acc"
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

# Debian Trixie PHP 8.4 from enabled Debian archive and security suites.
# Raspberry Pi OS also enables archive.raspberrypi.com; that archive is not
# a Debian origin for these packages. No apt source is added or edited.
BENCH_PHP84_PACKAGES=(php8.4-fpm php8.4-cli php8.4-common php8.4-sqlite3 php8.4-opcache php8.4-zip)

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

bench_php_uri_kind() {
	local uri=${1%/}
	case "$uri" in
		http://deb.debian.org/debian-security|https://deb.debian.org/debian-security|\
		http://security.debian.org|https://security.debian.org|\
		http://security.debian.org/debian-security|https://security.debian.org/debian-security|\
		http://ftp.debian.org/debian-security|https://ftp.debian.org/debian-security)
			printf '%s' security
			;;
		http://deb.debian.org/debian|https://deb.debian.org/debian|\
		http://ftp.debian.org/debian|https://ftp.debian.org/debian)
			printf '%s' archive
			;;
		*)
			printf '%s' other
			;;
	esac
}

bench_php_note_origin() {
	local kind suite
	kind=$(bench_php_uri_kind "$1")
	suite=$2
	case "${kind}:${suite}" in
		security:trixie-security) BENCH_SAW_DEBIAN_SECURITY=1 ;;
		archive:trixie|archive:trixie-updates) BENCH_SAW_DEBIAN_ARCHIVE=1 ;;
	esac
}

bench_php_origin_authorized() {
	local kind suite
	kind=$(bench_php_uri_kind "$1")
	suite=${2%%/*}
	case "${kind}:${suite}" in
		security:trixie-security|archive:trixie|archive:trixie-updates) return 0 ;;
		*) return 1 ;;
	esac
}

# Read one deb822 or one-line apt source file. Enabled: no, commented lines,
# deb-src-only stanzas, and backup filenames are not treated as enabled.
# Prints nothing. Sets BENCH_SAW_DEBIAN_SECURITY and BENCH_SAW_DEBIAN_ARCHIVE.
bench_php_read_source_file() {
	local file=$1
	local base tmp_origins
	base=$(basename "$file")
	tmp_origins=$(mktemp)
	case "$base" in
		*.bak|*.save|*.disabled|*.dpkg-old|*~) return 0 ;;
	esac
	[ -f "$file" ] || return 0
	[ -L "$file" ] && return 0
	case "$base" in
		*.sources)
			awk '
				function flush() {
					if (types == "" && uris == "" && suites == "") return
					enabled = tolower(enabled)
					if (enabled == "no") return
					n = split(types, tv, /[[:space:]]+/)
					hasdeb = 0
					for (i = 1; i <= n; i++) if (tv[i] == "deb") hasdeb = 1
					if (!hasdeb) return
					nu = split(uris, uv, /[[:space:]]+/)
					ns = split(suites, sv, /[[:space:]]+/)
					for (ui = 1; ui <= nu; ui++) {
						if (uv[ui] == "") continue
						for (si = 1; si <= ns; si++) {
							if (sv[si] == "") continue
							print uv[ui], sv[si]
						}
					}
				}
				BEGIN { types = ""; uris = ""; suites = ""; enabled = "yes"; key = "" }
				/^[[:space:]]*#/ || /^[[:space:]]*$/ {
					if ($0 ~ /^[[:space:]]*$/) flush()
					if ($0 ~ /^[[:space:]]*$/) { types = ""; uris = ""; suites = ""; enabled = "yes"; key = "" }
					next
				}
				{
					line = $0
					if (line ~ /^[[:space:]]/) {
						sub(/^[[:space:]]+/, "", line)
						if (key == "types") types = types " " line
						else if (key == "uris") uris = uris " " line
						else if (key == "suites") suites = suites " " line
						else if (key == "enabled") enabled = enabled " " line
						next
					}
					split(line, kv, /:[[:space:]]*/)
					key = tolower(kv[1])
					val = line
					sub(/^[^:]+:[[:space:]]*/, "", val)
					if (key == "types") types = val
					else if (key == "uris") uris = val
					else if (key == "suites") suites = val
					else if (key == "enabled") enabled = val
				}
				END { flush() }
			' "$file" > "$tmp_origins"
			while read -r uri suite; do
				bench_php_note_origin "$uri" "$suite"
			done < "$tmp_origins"
			;;
		sources.list|*.list)
			while IFS= read -r line || [ -n "$line" ]; do
				case "$line" in
					''|\#*) continue ;;
				esac
				set -- $line
				[ "$1" = "deb" ] || continue
				shift
				if [ "${1#-}" != "$1" ] || [ "${1#\[}" != "$1" ]; then
					opts=$1
					shift
					case "$(printf '%s' "$opts" | tr '[:upper:]' '[:lower:]')" in
						*enabled=no*) continue ;;
					esac
				fi
				[ $# -ge 2 ] || continue
				bench_php_note_origin "$1" "$2"
			done < "$file"
			;;
	esac
	rm -f "$tmp_origins"
}

bench_php_security_enabled() {
	local dir
	dir="${ROOT:-}/etc/apt"
	if [ ! -d "$dir" ]; then
		echo "refused: apt sources directory $dir is absent" >&2
		return 1
	fi
	BENCH_SAW_DEBIAN_SECURITY=0
	BENCH_SAW_DEBIAN_ARCHIVE=0
	if [ -f "$dir/sources.list" ]; then
		bench_php_read_source_file "$dir/sources.list"
	fi
	local file
	for file in "$dir"/sources.list.d/*.list "$dir"/sources.list.d/*.sources; do
		[ -e "$file" ] || continue
		bench_php_read_source_file "$file"
	done
	if [ "$BENCH_SAW_DEBIAN_SECURITY" != 1 ] || [ "$BENCH_SAW_DEBIAN_ARCHIVE" != 1 ]; then
		echo "refused: enabled Debian trixie and trixie-security sources are required" >&2
		return 1
	fi
	return 0
}

bench_php_candidate_origins_ok() {
	local pkg=$1
	local candidate=$2
	local saw=0 bad=0 uri suitecomp
	while read -r uri suitecomp; do
		[ -n "$uri" ] || continue
		saw=1
		if ! bench_php_origin_authorized "$uri" "$suitecomp"; then
			bad=1
		fi
	done < <(bench_apt_cache policy "$pkg" | awk -v cand="$candidate" '
		BEGIN { inver = 0 }
		{
			line = $0
			sub(/\r$/, "", line)
		}
		line ~ /^ +(\*\*\* +)?[^ ]+ +[0-9]+$/ {
			ver = line
			sub(/^ +\*+ +/, "", ver)
			sub(/^ +/, "", ver)
			split(ver, parts, /[[:space:]]+/)
			inver = (parts[1] == cand)
			next
		}
		inver && line ~ /^ +[0-9]+ +https?:\/\// {
			print $2, $3
			next
		}
		line ~ /^[^[:space:]]/ { inver = 0 }
	')
	if [ "$saw" != 1 ]; then
		echo "refused: apt did not report a Debian origin for ${pkg} candidate ${candidate}" >&2
		return 1
	fi
	if [ "$bad" != 0 ]; then
		echo "refused: ${pkg} candidate ${candidate} is also published outside Debian trixie or trixie-security" >&2
		return 1
	fi
	return 0
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

# Refresh apt, then install or upgrade only the PHP 8.4 runtime packages
# up to the candidate from enabled Debian trixie and trixie-security.
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
		if ! bench_php_candidate_origins_ok "$pkg" "$candidate"; then
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
		if ! bench_php_candidate_origins_ok "$pkg" "$candidate"; then
			return 5
		fi
	done
	return 0
}
