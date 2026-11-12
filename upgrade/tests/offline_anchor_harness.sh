#!/bin/bash
# Offline anchor checks for one payload tree. Nothing here is given a live
# ORP_ROOT, the station database, or /etc. On the Pi, /tmp is too small:
#   mkdir -m 755 /var/tmp/orp-fixtures
#   ORP_TEST_TMPDIR=/var/tmp/orp-fixtures bash upgrade/tests/offline_anchor_harness.sh
# A umask of 0002 does not make the fixture root group-writable.
set -euo pipefail

ROOT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
# shellcheck source=lib/fixture_tmpdir.sh
. "$ROOT_DIR/upgrade/tests/lib/fixture_tmpdir.sh"
orp_use_fixture_tmpdir
orp_require_fixture_space
real=$(readlink -f "$ROOT_DIR")
case "$real" in
	/|/etc|/etc/*|/var/www|/var/www/*|/usr/local|/usr/local/*|/usr/sbin|/usr/sbin/*)
		echo "refused: payload path is a live system tree" >&2
		exit 2
		;;
esac
unset ORP_ROOT ORP_DB_PATH ORP_LIVE_CONFIG_ROOT ORP_OPERATING_MODE_FILE
export ORP_BENCH_TEST_HARNESS=1
echo "fixture=$(orp_fixture_root)"

echo "kernel=$(uname -srm)"
echo "python=$(python3 --version 2>&1)"
if command -v php >/dev/null 2>&1; then
	echo "php=$(php -v | head -n 1)"
else
	echo "php=absent"
fi

bash "$ROOT_DIR/upgrade/tests/anchor_chmod_race_test.sh"
bash "$ROOT_DIR/upgrade/tests/install_and_helper_test.sh"
bash "$ROOT_DIR/upgrade/tests/uid_split_test.sh"
echo "offline anchor harness passed"
echo "canary=0600 for bench_chmod, bench_chown, and the courtesy directory"
