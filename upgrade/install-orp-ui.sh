#!/bin/bash
# Install the OpenRepeater UI onto the orp-test bench only.
# Refuses unless Debian 13 Trixie, aarch64, hostname orp-test, the image guard,
# and the bootstrap completion marker are all present. Does not start radio
# services, does not clear their masks, and does not modify the bootstrap tree.
# The bench marker is written before any web files and is left in place on failure.
set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
REPO_ROOT=$(cd "$SCRIPT_DIR/.." && pwd)
ROOT=${ORP_ROOT:-}
ROOT=${ROOT%/}
NGINX_TEMPLATE=${NGINX_TEMPLATE:-$REPO_ROOT/upgrade/nginx/openrepeater.conf.template}
# shellcheck source=lib/bench-target.sh
. "$SCRIPT_DIR/lib/bench-target.sh"

if [ -n "${ORP_ROOT:-}" ] || [ "${ORP_INSTALL_OFFLINE:-0}" = 1 ]; then
	if ! bench_test_harness_allowed; then
		echo "refused: test overrides are ignored on the bench host" >&2
		exit 1
	fi
fi

if [ "${ORP_INSTALL_OFFLINE:-0}" = 1 ] && [ -z "${ORP_ROOT:-}" ]; then
	echo "refused: offline install requires ORP_ROOT" >&2
	exit 1
fi

if [ "${ORP_INSTALL_OFFLINE:-0}" != 1 ] && [ "$(id -u)" -ne 0 ]; then
	echo "refused: run as root on the bench" >&2
	exit 1
fi

bench_assert_identity
bench_assert_bootstrap_idle
bench_assert_masks

free_kib=$(bench_free_kib)
if [ -z "$free_kib" ] || [ "$free_kib" -lt 524288 ]; then
	echo "refused: less than 512 MiB free on the target filesystem" >&2
	exit 2
fi

STAMP=$(date -u +%Y%m%dT%H%M%S%NZ)
backup_root=$(p "/var/backups/orp-ui/${STAMP}")
POLICY_BLOCK=0
FAIL_CLOSED_RAN=0

bench_trace() {
	if [ -n "${ORP_INSTALL_TRACE:-}" ]; then
		printf '%s\n' "$1" >> "$ORP_INSTALL_TRACE"
	fi
}

bench_nginx_test() {
	if [ -n "${ORP_NGINX_TEST:-}" ]; then
		"$ORP_NGINX_TEST"
		return
	fi
	if [ "${ORP_INSTALL_OFFLINE:-0}" = 1 ]; then
		return 0
	fi
	nginx -t
}

install_service_block() {
	local dest block
	dest=$(p /usr/sbin/policy-rc.d)
	bench_anchor_dir "$(dirname "$dest")"
	bench_anchor_dir "$backup_root"
	if [ "$(bench_lstat_kind "$dest")" = symlink ]; then
		echo "refused: policy-rc.d is a symbolic link" >&2
		exit 6
	fi
	if [ -f "$dest" ]; then
		cp -a "$dest" "${backup_root}/policy-rc.d.saved"
	fi
	block=$(mktemp)
	printf '%s\n' '#!/bin/sh' 'exit 101' > "$block"
	bench_place_file "$block" "$dest"
	rm -f "$block"
	bench_chmod 755 "$dest"
	POLICY_BLOCK=1
}

remove_service_block() {
	local dest
	dest=$(p /usr/sbin/policy-rc.d)
	if [ "$POLICY_BLOCK" != 1 ]; then
		return 0
	fi
	if [ -e "${backup_root}/policy-rc.d.saved" ]; then
		cp -a "${backup_root}/policy-rc.d.saved" "$dest"
	else
		rm -f "$dest"
	fi
	POLICY_BLOCK=0
}

fail_closed() {
	local rc=$?
	if [ "$FAIL_CLOSED_RAN" = 1 ]; then
		exit "$rc"
	fi
	FAIL_CLOSED_RAN=1
	if [ "$rc" -eq 0 ]; then
		return 0
	fi
	set +e
	remove_service_block
	orp_systemctl stop nginx >/dev/null 2>&1
	orp_systemctl disable nginx >/dev/null 2>&1
	rm -f "$(p /etc/nginx/sites-enabled/openrepeater)"
	if [ -e "${backup_root}/etc/nginx/sites-enabled/default" ] && [ ! -e "$(p /etc/nginx/sites-enabled/default)" ] \
		&& [ "$(bench_lstat_kind "$(p /etc/nginx/sites-enabled)")" = dir ]
	then
		cp -a "${backup_root}/etc/nginx/sites-enabled/default" "$(p /etc/nginx/sites-enabled/default)"
	fi
	# The bench marker is a safety boundary. Leave it in place.
	bench_assert_masks >/dev/null 2>&1
	exit "$rc"
}
trap fail_closed EXIT

# Stop web writers before repairing paths. Stopping them is not the
# boundary; a planted symlink is still refused below.
orp_systemctl stop nginx || true
orp_systemctl stop php8.4-fpm || true
orp_systemctl stop php-fpm || true

backup_if_present() {
	local rel full dest_dir
	rel=$1
	full=$(p "/${rel}")
	if [ -e "$full" ] || [ -L "$full" ]; then
		bench_require_real_components "$(dirname "$full")"
		dest_dir="${backup_root}/$(dirname "$rel")"
		bench_anchor_dir "$dest_dir"
		if [ -L "$full" ]; then
			# Copy the link itself. Do not follow it into the target.
			cp -P "$full" "${backup_root}/${rel}"
		else
			cp -a "$full" "${backup_root}/${rel}"
		fi
	fi
}

bench_snapshot_protected

for rel in \
	var/www/openrepeater \
	etc/nginx/sites-available/openrepeater \
	etc/nginx/sites-enabled/openrepeater \
	etc/nginx/sites-enabled/default \
	etc/openrepeater \
	etc/sudoers.d/openrepeater \
	usr/sbin/orp_helper \
	var/lib/openrepeater
do
	backup_if_present "$rel"
done

# Root-owned policy before any files are published and before apt can start nginx.
# Every directory is anchored from its parent before a child is created or chmod'd.
bench_trace marker
bench_anchor_dir "$(p /etc/openrepeater)"
bench_anchor_dir "$(p /etc/sudoers.d)"
bench_anchor_dir "$(p /var/lib/openrepeater)"
bench_anchor_dir "$(p /var/lib/openrepeater/bench-preview)"
bench_anchor_dir "$(p /var/lib/openrepeater/db)"
bench_anchor_dir "$(p /usr/sbin)"
marker_body=$(mktemp)
cat > "$marker_body" <<'EOF'
host=orp-test
radio=blocked
reboot=blocked
gpio=readonly
publish=fixed
preview=/var/lib/openrepeater/bench-preview
EOF
bench_place_file "$marker_body" "$(p /etc/openrepeater/bench-mode)"
rm -f "$marker_body"
bench_chmod 755 "$(p /etc/openrepeater)"
bench_chmod 755 "$(p /var/lib/openrepeater)"
bench_chmod 755 "$(p /var/lib/openrepeater/bench-preview)"
bench_chmod 755 "$(p /var/lib/openrepeater/db)"
bench_chmod 644 "$(p /etc/openrepeater/bench-mode)"
bench_chown root:root "$(p /etc/openrepeater)"
bench_chown root:root "$(p /etc/openrepeater/bench-mode)"
bench_chown root:root "$(p /var/lib/openrepeater)"
bench_chown root:root "$(p /var/lib/openrepeater/bench-preview)"
bench_chown root:root "$(p /var/lib/openrepeater/db)"

if [ "${ORP_INSTALL_OFFLINE:-0}" != 1 ] && [ "${ORP_INSTALL_SKIP_APT:-0}" != 1 ]; then
	install_service_block
	export DEBIAN_FRONTEND=noninteractive
	apt-get update
	apt-get install -y --no-install-recommends --no-upgrade \
		nginx php-fpm php-cli php-sqlite3 gpiod sudo sqlite3
	remove_service_block
	orp_systemctl stop nginx || true
	orp_systemctl disable nginx || true
fi

if [ "${ORP_INSTALL_OFFLINE:-0}" = 1 ]; then
	PHP_SOCK=${ORP_PHP_FPM_SOCK:-/run/php/php8.4-fpm.sock}
else
	if [ ! -f /etc/nginx/snippets/fastcgi-php.conf ]; then
		echo "refused: /etc/nginx/snippets/fastcgi-php.conf is absent" >&2
		exit 5
	fi
	php_unit=$(orp_systemctl list-unit-files --no-legend 'php*-fpm.service' | awk '{print $1}' | grep '^php8' | head -n 1 || true)
	php_unit=${php_unit%.service}
	if [ -z "$php_unit" ]; then
		echo "refused: no PHP 8 FPM unit is installed" >&2
		exit 5
	fi
	orp_systemctl start "$php_unit"
	if [ -S "/run/php/${php_unit}.sock" ]; then
		PHP_SOCK="/run/php/${php_unit}.sock"
	elif [ -S "/var/run/php/${php_unit}.sock" ]; then
		PHP_SOCK="/var/run/php/${php_unit}.sock"
	else
		echo "refused: PHP 8 FPM socket for ${php_unit} was not created" >&2
		exit 5
	fi
fi

bench_trace stage-www
stage=$(p /var/lib/openrepeater/stage)
web=$(p /var/www/openrepeater)
bench_anchor_dir "$(p /var/www)"
case "$(bench_lstat_kind "$web")" in
	symlink)
		echo "refused: web root is a symbolic link" >&2
		exit 6
		;;
	dir)
		# Replace the directory inode. Do not extract or chown through
		# symlinks the web user may have planted inside the old tree.
		mv "$web" "${web}.previous.${STAMP}"
		;;
esac
mkdir "$web"
bench_chmod 755 "$web"
if [ "$(bench_lstat_kind "$stage")" = symlink ]; then
	echo "refused: stage path is a symbolic link" >&2
	exit 6
fi
if [ "$(bench_lstat_kind "$stage")" = dir ]; then
	mv "$stage" "${stage}.previous.${STAMP}"
fi
mkdir "$stage"
bench_chmod 755 "$stage"
tar -C "$REPO_ROOT" --exclude=.git --exclude=dev -cf - . | tar -C "$stage" -xf -
tar -C "$stage" -cf - . | tar -C "$web" -xf -
if [ "${ORP_INSTALL_OFFLINE:-0}" != 1 ]; then
	find -P "$web" -xdev ! -type l -exec chown -h www-data:www-data {} +
fi
bench_chown www-data:www-data "$web"

bench_anchor_dir "$(p /etc/nginx/sites-available)"
bench_anchor_dir "$(p /etc/nginx/sites-enabled)"
bench_render_nginx "$PHP_SOCK" "$(p /etc/nginx/sites-available/openrepeater)"
if [ "$(bench_lstat_kind "$(p /etc/nginx/sites-enabled/default)")" = symlink ] || [ -e "$(p /etc/nginx/sites-enabled/default)" ]; then
	rm -f "$(p /etc/nginx/sites-enabled/default)"
fi
ln -sfn ../sites-available/openrepeater "$(p /etc/nginx/sites-enabled/openrepeater)"

bench_trace nginx-test
if ! bench_nginx_test; then
	echo "refused: nginx configuration test failed; site was not started" >&2
	exit 5
fi

if [ "$(bench_lstat_kind "$(p /usr/sbin/orp_helper)")" = symlink ]; then
	echo "refused: /usr/sbin/orp_helper is a symbolic link" >&2
	exit 6
fi
bench_place_file "$REPO_ROOT/install/scripts/orp_helper" "$(p /usr/sbin/orp_helper)"
bench_chmod 755 "$(p /usr/sbin/orp_helper)"
bench_chown root:root "$(p /usr/sbin/orp_helper)"

sudoers_tmp=$(mktemp)
cat > "$sudoers_tmp" <<'EOF'
# Closed command list. No password is stored here.
# www-data cannot pass an arbitrary helper argument.
www-data ALL=(root) NOPASSWD: /usr/sbin/orp_helper info timezone
www-data ALL=(root) NOPASSWD: /usr/sbin/orp_helper info cpu_type
www-data ALL=(root) NOPASSWD: /usr/sbin/orp_helper info cpu_speed
www-data ALL=(root) NOPASSWD: /usr/sbin/orp_helper info cpu_load
www-data ALL=(root) NOPASSWD: /usr/sbin/orp_helper info cpu_temp
www-data ALL=(root) NOPASSWD: /usr/sbin/orp_helper info uptime
www-data ALL=(root) NOPASSWD: /usr/sbin/orp_helper info memory_usage
www-data ALL=(root) NOPASSWD: /usr/sbin/orp_helper info disk_usage
www-data ALL=(root) NOPASSWD: /usr/sbin/orp_helper info os
www-data ALL=(root) NOPASSWD: /usr/sbin/orp_helper svxlink status
www-data ALL=(root) NOPASSWD: /usr/sbin/orp_helper audio inputs
www-data ALL=(root) NOPASSWD: /usr/sbin/orp_helper audio outputs
www-data ALL=(root) NOPASSWD: /usr/sbin/orp_helper audio version
www-data ALL=(root) NOPASSWD: /usr/sbin/orp_helper system uptime
www-data ALL=(root) NOPASSWD: /usr/sbin/orp_helper system user
EOF
if [ "$(bench_lstat_kind "$(p /etc/sudoers.d/openrepeater)")" = symlink ]; then
	rm -f "$sudoers_tmp"
	echo "refused: sudoers fragment is a symbolic link" >&2
	exit 6
fi
bench_place_file "$sudoers_tmp" "$(p /etc/sudoers.d/openrepeater)"
rm -f "$sudoers_tmp"
bench_chmod 440 "$(p /etc/sudoers.d/openrepeater)"
bench_chown root:root "$(p /etc/sudoers.d/openrepeater)"

db_file=$(p /var/lib/openrepeater/db/openrepeater.db)
# Parent is anchored above, so a planted symlink cannot be swapped in now.
if ! bench_ensure_regular "$db_file"; then
	exit 6
fi
if [ "$(bench_lstat_kind "$db_file")" = missing ]; then
	bench_place_file "$REPO_ROOT/install/sql/openrepeater.db" "$db_file"
fi
bench_chmod 660 "$db_file"
if getent group www-data >/dev/null 2>&1 && [ "${ORP_INSTALL_OFFLINE:-0}" != 1 ]; then
	bench_chown "root:www-data" "$db_file"
	bench_chown "root:www-data" "$(p /var/lib/openrepeater/db)"
else
	bench_chown "root:$(id -gn)" "$db_file"
	bench_chown "root:$(id -gn)" "$(p /var/lib/openrepeater/db)"
fi
# Sticky and group-writable only after the database inode is root-owned.
# www-data can create SQLite journals and cannot replace that inode.
bench_chmod 1770 "$(p /var/lib/openrepeater/db)"

# Re-assert the marker after file publish. It stays root-owned and not web-writable.
bench_chmod 755 "$(p /etc/openrepeater)"
bench_chmod 644 "$(p /etc/openrepeater/bench-mode)"
bench_chown root:root "$(p /etc/openrepeater)"
bench_chown root:root "$(p /etc/openrepeater/bench-mode)"

bench_trace nginx-enable
php_unit=$(basename "$PHP_SOCK")
php_unit=${php_unit%.sock}
if [ "${ORP_INSTALL_OFFLINE:-0}" != 1 ] || [ -n "${ORP_SYSTEMCTL:-}" ]; then
	orp_systemctl enable --now "$php_unit"
	orp_systemctl enable --now nginx
fi

bench_verify_protected
bench_assert_masks

echo "OpenRepeater UI files are staged for orp-test."
echo "Radio units were not started and their masks were checked again."
echo "The bench marker remains at /etc/openrepeater/bench-mode and is not web-writable."
echo "Bootstrap files under /var/lib/orp-test, /usr/local, and /opt/orp-test were not modified."
echo "No GPIO output, audio, or RF test was run."
if [ -d "$backup_root" ]; then
	echo "Backup of previous mutable files: ${backup_root}"
fi
