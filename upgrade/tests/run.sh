#!/bin/bash
# Cloud verification harness. Does not talk to the bench Pi or start a radio.
set -euo pipefail

ROOT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
cd "$ROOT_DIR"
if [ "${ORP_UMASK_MATRIX:-0}" != 1 ]; then
	export ORP_UMASK_MATRIX=1
	matrix_fail=0
	for mask in 0022 0002; do
		echo "=== umask ${mask} ==="
		if ! (umask "$mask" && bash "$0"); then
			echo "FAIL: suite failed under umask ${mask}" >&2
			matrix_fail=1
		fi
		if ! (umask "$mask" && bash "$ROOT_DIR/upgrade/tests/offline_anchor_harness.sh"); then
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

if ! command -v php >/dev/null 2>&1; then
	echo "php is required" >&2
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
bash "$ROOT_DIR/upgrade/tests/install_and_helper_test.sh"
bash "$ROOT_DIR/upgrade/tests/anchor_chmod_race_test.sh"
bash "$ROOT_DIR/upgrade/tests/login_session_test.sh"
bash "$ROOT_DIR/upgrade/tests/auth_boundary_test.sh"
bash "$ROOT_DIR/upgrade/tests/wizard_save_test.sh"
bash "$ROOT_DIR/upgrade/tests/identification_page_test.sh"
bash "$ROOT_DIR/upgrade/tests/operating_mode_test.sh"
bash "$ROOT_DIR/upgrade/tests/functional_runtime_test.sh"
bash "$ROOT_DIR/upgrade/tests/config_publish_boundary_test.sh"
bash "$ROOT_DIR/upgrade/tests/svxlink26_ident_test.sh"
bash "$ROOT_DIR/upgrade/tests/courtesy_override_test.sh"
bash "$ROOT_DIR/upgrade/tests/heather_sounds_test.sh"
bash "$ROOT_DIR/upgrade/tests/log_stream_test.sh"
bash "$ROOT_DIR/upgrade/tests/preset_roundtrip_test.sh"
bash "$ROOT_DIR/upgrade/tests/control_roundtrip_test.sh"
php "$ROOT_DIR/upgrade/tests/db_write_boundary_test.php" "$ROOT_DIR"
php "$ROOT_DIR/upgrade/tests/return_url_test.php"
php "$ROOT_DIR/upgrade/tests/stage_only_write_test.php"
bash "$ROOT_DIR/upgrade/tests/uid_split_test.sh"
bash "$ROOT_DIR/upgrade/tests/php_package_policy_test.sh"
echo "harness passed"
