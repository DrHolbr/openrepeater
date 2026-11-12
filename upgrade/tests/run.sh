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
	# shellcheck source=lib/host_tree_guard.sh
	. "$ROOT_DIR/upgrade/tests/lib/host_tree_guard.sh"
	mapfile -t guard_paths < <(host_tree_default_paths)
	guard_meta_before=$(mktemp)
	guard_sha_before=$(mktemp)
	if ! host_tree_meta "$guard_meta_before" "${guard_paths[@]}"; then
		echo "FAIL: live-tree guard could not take the before listing" >&2
		cleanup_payload || true
		exit 1
	fi
	if ! host_tree_sha "$guard_sha_before" "${guard_paths[@]}"; then
		echo "FAIL: live-tree guard could not take the before sha listing" >&2
		cleanup_payload || true
		exit 1
	fi
	finish_matrix() {
		local status=$?
		trap - EXIT
		local meta_after sha_after
		meta_after=$(mktemp)
		sha_after=$(mktemp)
		if ! host_tree_meta "$meta_after" "${guard_paths[@]}"; then
			status=1
		elif ! cmp -s "$guard_meta_before" "$meta_after"; then
			echo "FAIL: the umask matrix or the offline harness changed a live host tree. Live database writes or apt activity can also trip this guard." >&2
			diff -u "$guard_meta_before" "$meta_after" >&2 || true
			status=1
		fi
		if ! host_tree_sha "$sha_after" "${guard_paths[@]}"; then
			status=1
		elif ! cmp -s "$guard_sha_before" "$sha_after"; then
			echo "FAIL: the umask matrix or the offline harness changed a live file hash. Live database writes or apt activity can also trip this guard." >&2
			diff -u "$guard_sha_before" "$sha_after" >&2 || true
			status=1
		fi
		rm -f "$meta_after" "$sha_after"
		cleanup_payload || true
		if [ "$status" -eq 0 ]; then
			echo "ok: live host trees were not changed"
		fi
		exit "$status"
	}
	trap finish_matrix EXIT
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
# shellcheck source=lib/host_tree_guard.sh
. "$ROOT_DIR/upgrade/tests/lib/host_tree_guard.sh"
mapfile -t host_tree_paths < <(host_tree_default_paths)
host_tree_meta_before=$(mktemp)
host_tree_sha_before=$(mktemp)
if ! host_tree_meta "$host_tree_meta_before" "${host_tree_paths[@]}"; then
	echo "FAIL: live-tree guard could not take the before listing" >&2
	exit 1
fi
if ! host_tree_sha "$host_tree_sha_before" "${host_tree_paths[@]}"; then
	echo "FAIL: live-tree guard could not take the before sha listing" >&2
	exit 1
fi
host_tree_check() {
	local meta_after sha_after
	meta_after=$(mktemp)
	sha_after=$(mktemp)
	if ! host_tree_meta "$meta_after" "${host_tree_paths[@]}"; then
		rm -f "$meta_after" "$sha_after"
		return 1
	fi
	if ! host_tree_sha "$sha_after" "${host_tree_paths[@]}"; then
		rm -f "$meta_after" "$sha_after"
		return 1
	fi
	if ! cmp -s "$host_tree_meta_before" "$meta_after"; then
		echo "FAIL: a test changed a live host tree. Live database writes or apt activity can also trip this guard." >&2
		diff -u "$host_tree_meta_before" "$meta_after" >&2 || true
		rm -f "$meta_after" "$sha_after"
		return 1
	fi
	if ! cmp -s "$host_tree_sha_before" "$sha_after"; then
		echo "FAIL: a test changed a live file hash. Live database writes or apt activity can also trip this guard." >&2
		diff -u "$host_tree_sha_before" "$sha_after" >&2 || true
		rm -f "$meta_after" "$sha_after"
		return 1
	fi
	rm -f "$meta_after" "$sha_after"
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
bash "$ROOT_DIR/upgrade/tests/host_tree_guard_test.sh"
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
