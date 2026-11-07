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

bench_chown() {
	local flag="" spec path
	if [ "$1" = "-R" ]; then
		flag="-R"
		spec=$2
		path=$3
	else
		spec=$1
		path=$2
	fi
	if [ -n "${ORP_CHOWN_LOG:-}" ]; then
		printf '%s %s %s\n' "$flag" "$spec" "$path" >> "$ORP_CHOWN_LOG"
	fi
	if [ "${ORP_INSTALL_OFFLINE:-0}" = 1 ]; then
		return 0
	fi
	if [ -n "$flag" ]; then
		chown -R "$spec" "$path"
	else
		chown "$spec" "$path"
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
	local dest
	dest=$(p /usr/sbin/policy-rc.d)
	mkdir -p "$(dirname "$dest")" "$backup_root"
	if [ -e "$dest" ]; then
		cp -a "$dest" "${backup_root}/policy-rc.d.saved"
	fi
	printf '%s\n' '#!/bin/sh' 'exit 101' > "$dest"
	chmod 755 "$dest"
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
	if [ -e "${backup_root}/etc/nginx/sites-enabled/default" ] && [ ! -e "$(p /etc/nginx/sites-enabled/default)" ]; then
		mkdir -p "$(p /etc/nginx/sites-enabled)"
		cp -a "${backup_root}/etc/nginx/sites-enabled/default" "$(p /etc/nginx/sites-enabled/default)"
	fi
	# The bench marker is a safety boundary. Leave it in place.
	bench_assert_masks >/dev/null 2>&1
	exit "$rc"
}
trap fail_closed EXIT

backup_if_present() {
	local rel full dest_dir
	rel=$1
	full=$(p "/${rel}")
	if [ -e "$full" ] || [ -L "$full" ]; then
		dest_dir="${backup_root}/$(dirname "$rel")"
		mkdir -p "$dest_dir"
		cp -a "$full" "${backup_root}/${rel}"
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
bench_trace marker
mkdir -p "$(p /etc/openrepeater)" "$(p /etc/sudoers.d)" "$(p /var/lib/openrepeater/bench-preview)" "$(p /var/lib/openrepeater/db)" "$(p /usr/sbin)"
cat > "$(p /etc/openrepeater/bench-mode)" <<'EOF'
host=orp-test
radio=blocked
reboot=blocked
gpio=readonly
publish=fixed
preview=/var/lib/openrepeater/bench-preview
EOF
chmod 755 "$(p /etc/openrepeater)" "$(p /var/lib/openrepeater)"
chmod 644 "$(p /etc/openrepeater/bench-mode)"
chmod 2770 "$(p /var/lib/openrepeater/bench-preview)"
bench_chown root:root "$(p /etc/openrepeater)"
bench_chown root:root "$(p /etc/openrepeater/bench-mode)"
bench_chown root:root "$(p /var/lib/openrepeater)"
bench_chown root:www-data "$(p /var/lib/openrepeater/bench-preview)"

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
rm -rf "$stage"
mkdir -p "$stage"
tar -C "$REPO_ROOT" --exclude=.git -cf - . | tar -C "$stage" -xf -
mkdir -p "$(p /var/www/openrepeater)"
tar -C "$stage" -cf - . | tar -C "$(p /var/www/openrepeater)" -xf -
bench_chown -R www-data:www-data "$(p /var/www/openrepeater)"

mkdir -p "$(p /etc/nginx/sites-available)" "$(p /etc/nginx/sites-enabled)"
bench_render_nginx "$PHP_SOCK" "$(p /etc/nginx/sites-available/openrepeater)"
if [ -e "$(p /etc/nginx/sites-enabled/default)" ] || [ -L "$(p /etc/nginx/sites-enabled/default)" ]; then
	rm -f "$(p /etc/nginx/sites-enabled/default)"
fi
ln -sfn ../sites-available/openrepeater "$(p /etc/nginx/sites-enabled/openrepeater)"

bench_trace nginx-test
if ! bench_nginx_test; then
	echo "refused: nginx configuration test failed; site was not started" >&2
	exit 5
fi

cp "$REPO_ROOT/install/scripts/orp_helper" "$(p /usr/sbin/orp_helper)"
chmod 755 "$(p /usr/sbin/orp_helper)"
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
install -m 440 "$sudoers_tmp" "$(p /etc/sudoers.d/openrepeater)"
rm -f "$sudoers_tmp"
bench_chown root:root "$(p /etc/sudoers.d/openrepeater)"

if [ ! -f "$(p /var/lib/openrepeater/db/openrepeater.db)" ]; then
	cp "$REPO_ROOT/install/sql/openrepeater.db" "$(p /var/lib/openrepeater/db/openrepeater.db)"
fi
chmod 640 "$(p /var/lib/openrepeater/db/openrepeater.db)" || true
mkdir -p "$(p /var/lib/openrepeater/db)"
bench_chown www-data:www-data "$(p /var/lib/openrepeater/db)"
bench_chown www-data:www-data "$(p /var/lib/openrepeater/db/openrepeater.db)"

# Re-assert the marker after file publish. It stays root-owned and not web-writable.
chmod 755 "$(p /etc/openrepeater)"
chmod 644 "$(p /etc/openrepeater/bench-mode)"
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
