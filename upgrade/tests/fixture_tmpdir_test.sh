#!/bin/bash
# ORP_TEST_TMPDIR is absolute, real, and not a live OpenRepeater path.
set -euo pipefail

ROOT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
# shellcheck source=lib/fixture_tmpdir.sh
. "$ROOT_DIR/upgrade/tests/lib/fixture_tmpdir.sh"

expect_refuse() {
	local value=$1 needle=$2
	local out rc
	set +e
	out=$(ORP_TEST_TMPDIR="$value" orp_fixture_root 2>&1)
	rc=$?
	set -e
	if [ "$rc" -eq 0 ]; then
		echo "FAIL: ORP_TEST_TMPDIR=$value was accepted" >&2
		exit 1
	fi
	printf '%s\n' "$out" | grep -q "$needle"
	printf '%s\n' "$out" | grep -q 'ORP_TEST_TMPDIR'
}

expect_refuse /var/www 'live OpenRepeater'
expect_refuse /etc/openrepeater 'live OpenRepeater'
expect_refuse / 'live OpenRepeater'
expect_refuse relative 'absolute'
target=$(mktemp -d)
link="$target/link"
ln -s "$target" "$link"
expect_refuse "$link" 'symbolic link'

mine=$(mktemp -d)
trap 'rm -rf "$mine" "$target"' EXIT
got=$(ORP_TEST_TMPDIR="$mine" orp_fixture_root)
[ "$got" = "$mine" ]
made=$(ORP_TEST_TMPDIR="$mine" orp_mktemp_dir)
case "$made" in
	"$mine"/orp-fixture.*) ;;
	*)
		echo "FAIL: mktemp left the fixture directory: $made" >&2
		exit 1
		;;
esac
rmdir "$made"
saved=$(umask)
umask 0002
umask_dir=$(mktemp -d)
orp_mkdir "$umask_dir/root/etc/openrepeater"
if [ "$(stat -c %a "$umask_dir/root")" != "755" ] || [ "$(stat -c %a "$umask_dir/root/etc")" != "755" ]; then
	echo "FAIL: umask 0002 left a fixture directory group-writable" >&2
	stat -c '%a %n' "$umask_dir/root" "$umask_dir/root/etc" >&2
	exit 1
fi
rm -rf "$umask_dir"
umask "$saved"
echo "ok: fixture directories stay mode 0755 under umask 0002"
echo "ok: ORP_TEST_TMPDIR rejects live paths and symlinks"
fake=$(mktemp -d)
trap 'rm -rf "$mine" "$target" "$fake"' EXIT
orp_mkdir "$fake/bin"
cat > "$fake/bin/df" <<'EOF'
#!/bin/bash
echo 'Filesystem 1024-blocks Used Available Capacity Mounted on'
echo 'tmpfs 1000 0 100 1% /fixture'
EOF
chmod 755 "$fake/bin/df"
set +e
out=$(PATH="$fake/bin:$PATH" ORP_TEST_TMPDIR="$mine" orp_require_fixture_space 2>&1)
rc=$?
set -e
if [ "$rc" -eq 0 ]; then
	echo "FAIL: a 100 KiB fixture filesystem was accepted" >&2
	exit 1
fi
printf '%s\n' "$out" | grep -q 'ORP_TEST_TMPDIR'
printf '%s\n' "$out" | grep -q '512 MiB'
echo "ok: a small fixture filesystem names ORP_TEST_TMPDIR before the installer runs"
ro_src="$mine/orp-readonly-source"
printf 'sqlite' > "$ro_src"
chmod 0444 "$ro_src"
ro_dest="$mine/orp-fixture-copy/db"
mkdir -p "$ro_dest"
ORP_TEST_TMPDIR="$mine" orp_copy_writable "$ro_src" "$ro_dest/openrepeater.db"
if [ "$(stat -c %a "$ro_dest/openrepeater.db")" != "600" ]; then
	echo "FAIL: a 0444 source was not copied as mode 0600" >&2
	exit 1
fi
printf 'still' > "$ro_dest/openrepeater.db"
set +e
out=$(ORP_TEST_TMPDIR="$mine" orp_copy_writable "$ro_src" "/tmp/orp-outside-copy-$$" 2>&1)
rc=$?
set -e
if [ "$rc" -eq 0 ]; then
	echo "FAIL: a copy outside the fixture was accepted" >&2
	exit 1
fi
printf '%s\n' "$out" | grep -q 'outside the fixture'
echo "ok: a read-only source becomes a mode 0600 copy inside the fixture"
walk_parent=$(mktemp -d)
mkdir -m 700 "$walk_parent/created"
parent_mode=$(stat -c %a "$walk_parent")
vartmp_mode=$(stat -c %a /var/tmp)
ORP_TEST_TMPDIR="$walk_parent" orp_fixture_traverse "$walk_parent/created"
[ "$(stat -c %a "$walk_parent")" = "$parent_mode" ]
[ "$(stat -c %a /var/tmp)" = "$vartmp_mode" ]
[ "$(stat -c %a "$walk_parent/created")" = "711" ] || [ "$(stat -c %a "$walk_parent/created")" = "751" ]
set +e
ORP_TEST_TMPDIR="$walk_parent" orp_fixture_traverse /var/tmp >/tmp/orp-traverse-outside.txt 2>&1
walk_rc=$?
set -e
[ "$walk_rc" -ne 0 ]
grep -q 'outside the fixture' /tmp/orp-traverse-outside.txt
rm -f /tmp/orp-traverse-outside.txt
rm -rf "$walk_parent"
echo "ok: fixture traverse does not chmod the temp parent"
echo "fixture tmpdir checks passed"
