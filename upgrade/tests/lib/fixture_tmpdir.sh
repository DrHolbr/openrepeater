# Fixture directory for tests. ORP_TEST_TMPDIR is explicit because sudo
# env_reset drops TMPDIR. The installer 512 MiB check is unchanged.

orp_fixture_root() {
	local dir owner invoker
	if [ -n "${ORP_TEST_TMPDIR:-}" ]; then
		dir=$ORP_TEST_TMPDIR
	else
		dir=${TMPDIR:-/tmp}
	fi
	if [ "$dir" = "/" ]; then
		echo "refused: ORP_TEST_TMPDIR must not be /, /etc, /var/www, or a live OpenRepeater path" >&2
		return 2
	fi
	dir=${dir%/}
	case "$dir" in
		/*) ;;
		*)
			echo "refused: ORP_TEST_TMPDIR must be an absolute path" >&2
			return 2
			;;
	esac
	case "$dir" in
		..|../*|*/..|*/../*)
			echo "refused: ORP_TEST_TMPDIR must not contain .." >&2
			return 2
			;;
	esac
	case "$dir" in
		/|/etc|/etc/*|/var/www|/var/www/*|/var/lib/openrepeater|/var/lib/openrepeater/*|/usr/local/share/svxlink|/usr/local/share/svxlink/*|/usr/sbin|/usr/sbin/*)
			echo "refused: ORP_TEST_TMPDIR must not be /, /etc, /var/www, or a live OpenRepeater path" >&2
			return 2
			;;
	esac
	if [ -L "$dir" ]; then
		echo "refused: ORP_TEST_TMPDIR is a symbolic link" >&2
		return 2
	fi
	if [ ! -d "$dir" ]; then
		echo "refused: ORP_TEST_TMPDIR does not exist: $dir" >&2
		return 2
	fi
	owner=$(stat -c %u "$dir")
	if [ -n "${ORP_TEST_INVOKER:-}" ]; then
		invoker=$ORP_TEST_INVOKER
	else
		invoker=$(id -u)
	fi
	case "$invoker" in
		''|*[!0-9]*)
			echo "refused: ORP_TEST_INVOKER is not a uid" >&2
			return 2
			;;
	esac
	if [ "$owner" != "0" ] && [ "$owner" != "$invoker" ] && [ "$owner" != "$(id -u)" ]; then
		echo "refused: ORP_TEST_TMPDIR is not owned by the invoking user or root" >&2
		return 2
	fi
	printf '%s' "$dir"
}

orp_use_fixture_tmpdir() {
	local root
	root=$(orp_fixture_root) || return $?
	export ORP_TEST_TMPDIR="$root"
	export TMPDIR="$root"
}

orp_mktemp_dir() {
	local root
	root=$(orp_fixture_root) || return $?
	mktemp -d "${root}/orp-fixture.XXXXXX"
}

# mkdir -p -m only modes the last component. install -d -m 0755 modes
# every component and ignores umask, so a 0002 umask cannot make a
# fixture root group-writable.
orp_mkdir() {
	local dir
	for dir in "$@"; do
		install -d -m 0755 -- "$dir"
	done
}

# A mode or marker file is ignored when it is group or world writable.
orp_private() {
	chmod 644 "$@"
}

# Remove a fixture tree even when an install left it mode 0555.
# chmod stays inside the fixture root.
orp_cleanup_fixture() {
	local root path
	root=$(orp_fixture_root) || return 0
	for path in "$@"; do
		[ -n "$path" ] || continue
		if [ ! -e "$path" ] && [ ! -L "$path" ]; then
			continue
		fi
		case "$path" in
			"$root"|"$root"/*) ;;
			*)
				echo "refused: not cleaning outside the fixture: $path" >&2
				continue
				;;
		esac
		if [ -d "$path" ] && [ ! -L "$path" ]; then
			find -P "$path" -xdev -exec chmod u+w {} + 2>/dev/null || true
		fi
		rm -rf "$path"
	done
}

# Tests that run the installer need 512 MiB on the fixture filesystem.
# This fails before the installer, and it does not change the installer.
orp_require_fixture_space() {
	local root kib
	root=$(orp_fixture_root) || return $?
	kib=$(df -Pk "$root" | awk 'NR==2 {print $4}')
	if [ -z "$kib" ] || [ "$kib" -lt 524288 ]; then
		echo "refused: fixture directory ${root} has ${kib:-0} KiB free, less than 512 MiB. Set ORP_TEST_TMPDIR to an existing absolute directory on a filesystem with at least 512 MiB free, owned by you or root and not a symlink. The installer 512 MiB guard was not changed." >&2
		return 2
	fi
}

orp_reexec_root_if_needed() {
	local root
	if [ "$(id -u)" -eq 0 ]; then
		return 0
	fi
	root=$(orp_fixture_root) || return $?
	exec sudo -n env \
		ORP_TEST_TMPDIR="$root" \
		TMPDIR="$root" \
		ORP_TEST_INVOKER="$(id -u)" \
		ORP_BENCH_TEST_HARNESS="${ORP_BENCH_TEST_HARNESS:-}" \
		bash "$0" "$@"
}
