#!/bin/bash
# Cloud verification harness. Does not talk to the bench Pi or start a radio.
set -euo pipefail

ROOT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
cd "$ROOT_DIR"
if [ "${ORP_UMASK_MATRIX:-0}" != 1 ]; then
	export ORP_UMASK_MATRIX=1
	# shellcheck source=upgrade/tests/lib/fixture_tmpdir.sh
	. "$ROOT_DIR/upgrade/tests/lib/fixture_tmpdir.sh"
	orp_use_fixture_tmpdir
	payload=$(orp_readonly_payload "$ROOT_DIR")
	cleanup_payload() {
		local root
		root=$(orp_fixture_root) || return 0
		case "$payload" in
			"$root"/orp-fixture.*) ;;
			*)
				echo "refused: not removing a payload outside the fixture" >&2
				return 0
				;;
		esac
		sudo -n rm -rf -- "$payload" 2>/dev/null || rm -rf -- "$payload"
	}
	trap cleanup_payload EXIT
	matrix_fail=0
	for mask in 0022 0002; do
		echo "=== umask ${mask} read-only payload ==="
		if ! (umask "$mask" && bash "$payload/upgrade/tests/run.sh"); then
			echo "FAIL: suite failed under umask ${mask}" >&2
			matrix_fail=1
		fi
		if ! (umask "$mask" && bash "$payload/upgrade/tests/offline_anchor_harness.sh"); then
			echo "FAIL: offline anchor harness failed under umask ${mask}" >&2
			matrix_fail=1
		fi
	done
	if [ "$matrix_fail" -ne 0 ]; then
		exit 1
	fi
	echo "both umasks passed"
	exit 0
fi
# shellcheck source=upgrade/tests/lib/fixture_tmpdir.sh
. "$ROOT_DIR/upgrade/tests/lib/fixture_tmpdir.sh"
orp_use_fixture_tmpdir
# Tests name their own mode file, marker, hostname, and root. They do not
# read the installed operating-mode token or the live svxlink config.
export ORP_BENCH_TEST_HARNESS=1
export PYTHONDONTWRITEBYTECODE=1
export ORP_LIVE_ETC_LOG="$(orp_fixture_root)/orp-live-etc-reads.log"
: > "$ORP_LIVE_ETC_LOG"
# sudo -n is required so the guard can read root-owned trees. A find failure
# is reported here. It is not left for pipefail to abort the suite silently.
host_tree_paths=(
	/var/www/openrepeater
	/etc/openrepeater
	/etc/svxlink
	/etc/sudoers.d
	/etc/systemd/system
	/var/lib/openrepeater
	/usr/local/share/svxlink
	/usr/sbin/orp_helper
)
host_tree_listing() {
	local dest=$1 path raw rc=0 kind file sha line
	: > "$dest"
	raw=$(mktemp)
	for path in "${host_tree_paths[@]}"; do
		if [ ! -e "$path" ] && [ ! -L "$path" ]; then
			printf 'absent %s\n' "$path" >> "$dest"
			continue
		fi
		set +e
		sudo -n find -P "$path" -xdev -printf '%p %y %u %g %m %s %T@\n' > "$raw" 2>"$raw.err"
		rc=$?
		set -e
		if [ "$rc" -ne 0 ]; then
			echo "FAIL: live-tree guard could not list ${path} (sudo find exit ${rc}). Unreadable directories are read with sudo -n, not as the invoking user. This is not a pipefail abort." >&2
			cat "$raw.err" >&2 || true
			rm -f "$raw" "$raw.err"
			return 1
		fi
		rm -f "$raw.err"
		hashes=$(mktemp)
		files=$(mktemp)
		set +e
		sudo -n find -P "$path" -xdev -type f -print0 > "$files"
		find_rc=$?
		hash_rc=0
		if [ "$find_rc" -eq 0 ] && [ -s "$files" ]; then
			sudo -n xargs -0 sha256sum < "$files" > "$hashes"
			hash_rc=$?
		fi
		set -e
		if [ "$find_rc" -ne 0 ] || [ "$hash_rc" -ne 0 ]; then
			echo "FAIL: live-tree guard could not hash regular files under ${path} (find exit ${find_rc}, sha256sum exit ${hash_rc}). sudo -n is required to read root-owned files. This is not a pipefail abort." >&2
			rm -f "$raw" "$hashes" "$files"
			return 1
		fi
		rm -f "$files"
		while IFS= read -r line || [ -n "$line" ]; do
			[ -n "$line" ] || continue
			kind=$(printf '%s\n' "$line" | awk '{print $(NF-5)}')
			if [ "$kind" = "f" ]; then
				file=$(printf '%s\n' "$line" | awk '{
					n = NF
					for (i = 1; i <= n - 6; i++) printf "%s%s", $i, (i < n - 6 ? " " : "")
				}')
				sha=$(awk -v p="$file" '$2 == p { print $1; exit }' "$hashes")
				if [ -z "$sha" ]; then
					echo "FAIL: live-tree guard hashed no bytes for ${file}" >&2
					rm -f "$raw" "$hashes"
					return 1
				fi
				printf '%s %s\n' "$line" "$sha" >> "$dest"
			else
				printf '%s\n' "$line" >> "$dest"
			fi
		done < "$raw"
		rm -f "$hashes"
	done
	rm -f "$raw"
	sort -o "$dest" "$dest"
}
host_tree_before=$(mktemp)
if ! host_tree_listing "$host_tree_before"; then
	echo "FAIL: live-tree guard could not take the before listing" >&2
	exit 1
fi
host_tree_check() {
	local after
	after=$(mktemp)
	if ! host_tree_listing "$after"; then
		rm -f "$after"
		echo "FAIL: live-tree guard could not take the after listing" >&2
		return 1
	fi
	if ! cmp -s "$host_tree_before" "$after"; then
		echo "FAIL: a test changed a live host tree" >&2
		diff -u "$host_tree_before" "$after" >&2 || true
		rm -f "$after"
		return 1
	fi
	rm -f "$after"
	echo "ok: live host trees were not changed"
	return 0
}
host_tree_on_exit() {
	local status=$?
	trap - EXIT
	if ! host_tree_check; then
		status=1
	fi
	exit "$status"
}
trap host_tree_on_exit EXIT

if ! command -v php >/dev/null 2>&1; then
	echo "php is required" >&2
	exit 1
fi
if ! command -v node >/dev/null 2>&1; then
	echo "refused: the Debian package nodejs is required for upgrade/tests/logtail_client_test.js" >&2
	exit 1
fi

echo "PHP $(php -r 'echo PHP_VERSION;')"
fail=0
while IFS= read -r file; do
	if ! php -l "$file" >/dev/null; then
		php -l "$file" || true
		fail=1
	fi
done < <(find . -name '*.php' -not -path './.git/*')
if [ "$fail" -ne 0 ]; then
	echo "php -l failed" >&2
	exit 1
fi
echo "ok: php -l"

bash "$ROOT_DIR/upgrade/tests/fixture_tmpdir_test.sh"
php "$ROOT_DIR/upgrade/tests/php_safety_test.php"
bash "$ROOT_DIR/upgrade/tests/harness_isolation_test.sh"
bash "$ROOT_DIR/upgrade/tests/install_and_helper_test.sh"
bash "$ROOT_DIR/upgrade/tests/anchor_chmod_race_test.sh"
bash "$ROOT_DIR/upgrade/tests/login_session_test.sh"
bash "$ROOT_DIR/upgrade/tests/auth_boundary_test.sh"
bash "$ROOT_DIR/upgrade/tests/wizard_save_test.sh"
bash "$ROOT_DIR/upgrade/tests/identification_page_test.sh"
bash "$ROOT_DIR/upgrade/tests/operating_mode_test.sh"
bash "$ROOT_DIR/upgrade/tests/functional_test_lift_test.sh"
bash "$ROOT_DIR/upgrade/tests/functional_runtime_test.sh"
bash "$ROOT_DIR/upgrade/tests/config_publish_boundary_test.sh"
bash "$ROOT_DIR/upgrade/tests/svxlink26_ident_test.sh"
bash "$ROOT_DIR/upgrade/tests/courtesy_override_test.sh"
bash "$ROOT_DIR/upgrade/tests/heather_sounds_test.sh"
bash "$ROOT_DIR/upgrade/tests/log_stream_test.sh"
bash "$ROOT_DIR/upgrade/tests/preset_roundtrip_test.sh"
bash "$ROOT_DIR/upgrade/tests/module_zip_test.sh"
bash "$ROOT_DIR/upgrade/tests/control_roundtrip_test.sh"
php "$ROOT_DIR/upgrade/tests/db_write_boundary_test.php" "$ROOT_DIR"
php "$ROOT_DIR/upgrade/tests/return_url_test.php"
php "$ROOT_DIR/upgrade/tests/stage_only_write_test.php"
bash "$ROOT_DIR/upgrade/tests/uid_split_test.sh"
bash "$ROOT_DIR/upgrade/tests/php_package_policy_test.sh"
if [ -s "$ORP_LIVE_ETC_LOG" ]; then
	echo "FAIL: a test read the live /etc/openrepeater or /etc/hostname path" >&2
	cat "$ORP_LIVE_ETC_LOG" >&2
	exit 1
fi
echo "ok: no test read live /etc/openrepeater or /etc/hostname"
echo "harness passed"
