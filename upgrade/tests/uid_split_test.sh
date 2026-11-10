#!/bin/bash
# Root-owned anchors and an unprivileged www-data writer. Same-UID fixtures do not cover this.
set -euo pipefail

if ! sudo -n true; then
	echo "sudo is required for the two-UID test" >&2
	exit 1
fi
ROOT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
# shellcheck source=lib/fixture_tmpdir.sh
. "$ROOT_DIR/upgrade/tests/lib/fixture_tmpdir.sh"
orp_use_fixture_tmpdir
orp_require_fixture_space
INSTALL="$ROOT_DIR/upgrade/install-orp-ui.sh"
base=$(orp_mktemp_dir)
chmod 755 "$base"
trap 'sudo rm -rf "$base"' EXIT
root="$base/fixture"
log="$base/systemctl.log"
sys="$base/systemctl"
hostfile="$base/hostname-orp"
printf 'orp-test\n' > "$hostfile"

cat > "$sys" <<'EOF'
#!/bin/bash
echo "$*" >> "${ORP_SYSTEMCTL_LOG:?}"
cmd=$1
shift || true
case "$cmd" in
	is-enabled)
		case "$1" in
			svxlink.service|remotetrx.service|svxreflector.service) echo masked; exit 1 ;;
			*) echo disabled; exit 1 ;;
		esac
		;;
	is-active)
		echo inactive
		exit 3
		;;
	*) exit 0 ;;
esac
EOF
chmod 755 "$sys"

sudo mkdir -m 755 "$root"
sudo chown root:root "$root"
sudo mkdir -p "$root/etc/nginx/sites-enabled" "$root/var/lib/orp-test/build" \
	"$root/usr/local/bin" "$root/usr/local/share/svxlink" "$root/usr/local/sbin" \
	"$root/opt/orp-test" "$root/etc/svxlink"
sudo tee "$root/etc/hostname" >/dev/null <<<'orp-test'
sudo tee "$root/etc/orp-arch" >/dev/null <<<'aarch64'
sudo tee "$root/etc/os-release" >/dev/null <<'EOF'
ID=debian
VERSION_ID="13"
VERSION_CODENAME=trixie
EOF
printf 'guard\n' | sudo tee "$root/etc/orp-test-image" >/dev/null
printf 'done\n' | sudo tee "$root/var/lib/orp-test/complete" >/dev/null
printf 'object\n' | sudo tee "$root/var/lib/orp-test/build/keep.o" >/dev/null
printf 'bin\n' | sudo tee "$root/usr/local/bin/svxlink" >/dev/null
printf 'share\n' | sudo tee "$root/usr/local/share/svxlink/keep" >/dev/null
printf 'bootstrap\n' | sudo tee "$root/usr/local/sbin/orp-test-bootstrap.sh" >/dev/null
printf 'archive\n' | sudo tee "$root/opt/orp-test/keep" >/dev/null
printf 'CANARY-BYTES\n' | sudo tee "$root/etc/svxlink/svxlink.conf" >/dev/null
sudo chmod 600 "$root/etc/svxlink/svxlink.conf"
sudo bash -c 'source "$1"; plant_native_layout "$2"' bash "$ROOT_DIR/upgrade/tests/lib/native_layout.sh" "$root"
printf 'default-site\n' | sudo tee "$root/etc/nginx/sites-enabled/default" >/dev/null

run_install() {
	sudo -n env ORP_BENCH_TEST_HARNESS=1 ORP_INSTALL_OFFLINE=1 ORP_INSTALL_APPLY_OWNERSHIP=1 \
		ORP_ROOT="$root" ORP_SYSTEMCTL="$sys" ORP_SYSTEMCTL_LOG="$log" \
		ORP_PHP_FPM_SOCK=/run/php/php8.4-fpm.sock ORP_BOOTSTRAP_ACTIVE=0 \
		bash "$INSTALL"
}

: > "$log"
run_install

preview="$root/var/lib/openrepeater/bench-preview"
dbdir="$root/var/lib/openrepeater/db"
db="$dbdir/openrepeater.db"
canary="$root/etc/svxlink/svxlink.conf"
stat_line() { sudo stat -c '%u %g %a' "$1"; sudo cat "$1"; }

if [ "$(sudo stat -c '%u %g %a' "$preview")" != "0 33 1770" ]; then
	echo "FAIL: bench-preview ownership $(sudo stat -c '%u %g %a' "$preview")" >&2
	exit 1
fi
echo "ok: bench-preview is root:www-data 1770"
if [ "$(sudo stat -c '%u %g %a' "$dbdir")" != "0 33 1770" ]; then
	echo "FAIL: db directory $(sudo stat -c '%u %g %a' "$dbdir")" >&2
	exit 1
fi
if [ "$(sudo stat -c '%u %g %a' "$db")" != "0 33 660" ]; then
	echo "FAIL: database file $(sudo stat -c '%u %g %a' "$db")" >&2
	exit 1
fi
echo "ok: database file is root:www-data 660 in a sticky directory"

before_canary=$(stat_line "$canary")
sudo -n -u www-data env TMPDIR="$(orp_fixture_root)" ORP_TEST_TMPDIR="$(orp_fixture_root)" php "$ROOT_DIR/upgrade/tests/uid_split_writer.php" create "$preview" "$hostfile"
sudo -n -u www-data env TMPDIR="$(orp_fixture_root)" ORP_TEST_TMPDIR="$(orp_fixture_root)" php "$ROOT_DIR/upgrade/tests/uid_split_writer.php" overwrite "$preview" "$hostfile"
if [ "$(sudo stat -c '%u' "$preview/svxlink.conf")" != "33" ]; then
	echo "FAIL: preview file owner is $(sudo stat -c '%u' "$preview/svxlink.conf"), expected www-data" >&2
	exit 1
fi
if [ "$(sudo cat "$preview/svxlink.conf")" != "overwritten-by-www-data" ]; then
	echo "FAIL: overwrite did not replace the preview bytes" >&2
	exit 1
fi
echo "ok: www-data created and overwrote a preview in the installed directory"

work="$(orp_fixture_root)/orp-preview-uidwork-$$"
sudo mkdir -m 1770 "$work"
sudo chown root:www-data "$work"
sudo -n -u www-data env TMPDIR="$(orp_fixture_root)" ORP_TEST_TMPDIR="$(orp_fixture_root)" php "$ROOT_DIR/upgrade/tests/uid_split_writer.php" publish "$work" "$hostfile"
echo "ok: write_config reports success and disarms PTT"

locked="$(orp_fixture_root)/orp-preview-uidlocked-$$"
sudo mkdir -m 755 "$locked"
sudo chown root:root "$locked"
sudo -n -u www-data env TMPDIR="$(orp_fixture_root)" ORP_TEST_TMPDIR="$(orp_fixture_root)" php "$ROOT_DIR/upgrade/tests/uid_split_writer.php" fail-locked "$locked" "$hostfile"
if sudo test -e "$locked/svxlink.conf"; then
	echo "FAIL: locked preview gained a file" >&2
	exit 1
fi
echo "ok: unwritable preview is reported as failure"

linkdir="$(orp_fixture_root)/orp-preview-uidlink-$$"
sudo mkdir -m 1770 "$linkdir"
sudo chown root:www-data "$linkdir"
sudo ln -s "$canary" "$linkdir/svxlink.conf"
sudo -n -u www-data env TMPDIR="$(orp_fixture_root)" ORP_TEST_TMPDIR="$(orp_fixture_root)" php "$ROOT_DIR/upgrade/tests/uid_split_writer.php" fail-symlink "$linkdir" "$hostfile"
after_canary=$(stat_line "$canary")
if [ "$before_canary" != "$after_canary" ]; then
	echo "FAIL: symlink write changed the canary" >&2
	printf 'before %s\nafter %s\n' "$before_canary" "$after_canary" >&2
	exit 1
fi
echo "ok: failed symlink write did not change the root canary"

sudo -n -u www-data env TMPDIR="$(orp_fixture_root)" ORP_TEST_TMPDIR="$(orp_fixture_root)" php "$ROOT_DIR/upgrade/tests/uid_split_writer.php" sqlite "$db"
echo "ok: www-data SQLite CRUD kept the root-owned database inode"

preview_file_before=$(sudo stat -c '%u %g %a' "$preview/svxlink.conf")
: > "$log"
run_install
preview_file_after=$(sudo stat -c '%u %g %a' "$preview/svxlink.conf")
after_canary=$(stat_line "$canary")
if [ "$before_canary" != "$after_canary" ]; then
	echo "FAIL: reinstall changed the canary" >&2
	exit 1
fi
if [ "$preview_file_before" != "$preview_file_after" ]; then
	echo "FAIL: reinstall chowned a www-data preview file ($preview_file_before -> $preview_file_after)" >&2
	exit 1
fi
if [ "$(sudo stat -c '%u %g %a' "$preview")" != "0 33 1770" ]; then
	echo "FAIL: reinstall dropped bench-preview permissions" >&2
	exit 1
fi
if [ ! -f "$root/etc/openrepeater/bench-mode" ]; then
	echo "FAIL: reinstall removed the bench marker" >&2
	exit 1
fi
echo "ok: reinstall preserved the canary, preview ownership, and marker"
sudo rm -rf "$locked" "$linkdir" "$work"
echo "uid split checks passed"
