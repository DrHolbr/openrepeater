#!/bin/bash
# Cloud verification harness. Does not talk to the bench Pi or start a radio.
set -euo pipefail

ROOT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
cd "$ROOT_DIR"

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

php "$ROOT_DIR/upgrade/tests/php_safety_test.php"
bash "$ROOT_DIR/upgrade/tests/install_and_helper_test.sh"
bash "$ROOT_DIR/upgrade/tests/login_session_test.sh"
bash "$ROOT_DIR/upgrade/tests/auth_boundary_test.sh"
bash "$ROOT_DIR/upgrade/tests/wizard_save_test.sh"
bash "$ROOT_DIR/upgrade/tests/identification_page_test.sh"
bash "$ROOT_DIR/upgrade/tests/operating_mode_test.sh"
bash "$ROOT_DIR/upgrade/tests/functional_runtime_test.sh"
bash "$ROOT_DIR/upgrade/tests/config_publish_boundary_test.sh"
bash "$ROOT_DIR/upgrade/tests/uid_split_test.sh"
bash "$ROOT_DIR/upgrade/tests/php_package_policy_test.sh"
echo "harness passed"
