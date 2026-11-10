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
echo "fixture tmpdir checks passed"
