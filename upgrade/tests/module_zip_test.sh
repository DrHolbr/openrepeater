#!/bin/bash
# ZipArchive refusal and hostile module archives. Nothing is installed.
set -euo pipefail

ROOT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
# shellcheck source=lib/fixture_tmpdir.sh
. "$ROOT_DIR/upgrade/tests/lib/fixture_tmpdir.sh"
orp_use_fixture_tmpdir

php -n "$ROOT_DIR/upgrade/tests/module_zip_test.php" missing
set +e
php "$ROOT_DIR/upgrade/tests/module_zip_test.php" hostile
rc=$?
set -e
sudo -n chown -R "$(id -u):$(id -g)" "$(orp_fixture_root)" || true
if [ "$rc" -ne 0 ]; then
	exit "$rc"
fi
echo "module zip checks passed"
