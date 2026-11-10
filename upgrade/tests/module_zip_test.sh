#!/bin/bash
# ZipArchive refusal and hostile module archives. Nothing is installed.
set -euo pipefail

ROOT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
# shellcheck source=lib/fixture_tmpdir.sh
. "$ROOT_DIR/upgrade/tests/lib/fixture_tmpdir.sh"
orp_use_fixture_tmpdir

php -n "$ROOT_DIR/upgrade/tests/module_zip_test.php" missing
php "$ROOT_DIR/upgrade/tests/module_zip_test.php" hostile
echo "module zip checks passed"
