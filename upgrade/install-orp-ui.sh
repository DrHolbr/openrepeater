#!/bin/bash
# Install the OpenRepeater UI onto the orp-test bench only.
# Refuses unless Debian 13 Trixie, aarch64, hostname orp-test, the image guard,
# and the bootstrap completion marker are all present. Does not start radio
# services, does not clear their masks, and does not modify the bootstrap tree.
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

if [ "${ORP_INSTALL_OFFLINE:-0}" != 1 ] && [ "${ORP_INSTALL_SKIP_APT:-0}" != 1 ]; then
	export DEBIAN_FRONTEND=noninteractive
	apt-get update
	apt-get install -y --no-install-recommends --no-upgrade \
		nginx php-fpm php-cli php-sqlite3 gpiod sudo sqlite3
fi

mkdir -p "$(p /var/www/openrepeater)"
tar -C "$REPO_ROOT" --exclude=.git -cf - . | tar -C "$(p /var/www/openrepeater)" -xf -

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
	orp_systemctl enable --now "$php_unit"
	if [ -S "/run/php/${php_unit}.sock" ]; then
		PHP_SOCK="/run/php/${php_unit}.sock"
	elif [ -S "/var/run/php/${php_unit}.sock" ]; then
		PHP_SOCK="/var/run/php/${php_unit}.sock"
	else
		echo "refused: PHP 8 FPM socket for ${php_unit} was not created" >&2
		exit 5
	fi
fi

mkdir -p "$(p /etc/nginx/sites-available)" "$(p /etc/nginx/sites-enabled)"
bench_render_nginx "$PHP_SOCK" "$(p /etc/nginx/sites-available/openrepeater)"
if [ -e "$(p /etc/nginx/sites-enabled/default)" ] || [ -L "$(p /etc/nginx/sites-enabled/default)" ]; then
	rm -f "$(p /etc/nginx/sites-enabled/default)"
fi
ln -sfn ../sites-available/openrepeater "$(p /etc/nginx/sites-enabled/openrepeater)"

mkdir -p "$(p /etc/openrepeater)" "$(p /etc/sudoers.d)" "$(p /var/lib/openrepeater/bench-preview)" "$(p /var/lib/openrepeater/db)" "$(p /usr/sbin)"
cat > "$(p /etc/openrepeater/bench-mode)" <<'EOF'
host=orp-test
radio=blocked
reboot=blocked
gpio=readonly
publish=preview
preview=/var/lib/openrepeater/bench-preview
EOF

cp "$REPO_ROOT/install/scripts/orp_helper" "$(p /usr/sbin/orp_helper)"
chmod 755 "$(p /usr/sbin/orp_helper)"

sudoers_tmp=$(mktemp)
cat > "$sudoers_tmp" <<'EOF'
# OpenRepeater UI may run only this helper. No password is stored here.
www-data ALL=(root) NOPASSWD: /usr/sbin/orp_helper
EOF
install -m 440 "$sudoers_tmp" "$(p /etc/sudoers.d/openrepeater)"
rm -f "$sudoers_tmp"

if [ ! -f "$(p /var/lib/openrepeater/db/openrepeater.db)" ]; then
	cp "$REPO_ROOT/install/sql/openrepeater.db" "$(p /var/lib/openrepeater/db/openrepeater.db)"
fi
chmod 640 "$(p /var/lib/openrepeater/db/openrepeater.db)" || true

if [ "${ORP_INSTALL_OFFLINE:-0}" != 1 ]; then
	if id www-data >/dev/null 2>&1; then
		chown -R www-data:www-data "$(p /var/www/openrepeater)" "$(p /var/lib/openrepeater)" "$(p /etc/openrepeater)"
	fi
	php_unit=$(basename "$PHP_SOCK")
	php_unit=${php_unit%.sock}
	orp_systemctl enable --now "$php_unit"
	orp_systemctl enable --now nginx
	nginx -t
	orp_systemctl reload nginx || orp_systemctl restart nginx
else
	php_unit=$(basename "$PHP_SOCK")
	php_unit=${php_unit%.sock}
	if [ -n "${ORP_SYSTEMCTL:-}" ]; then
		orp_systemctl enable --now "$php_unit"
		orp_systemctl enable --now nginx
	fi
fi

bench_verify_protected
bench_assert_masks

echo "OpenRepeater UI files are staged for orp-test."
echo "Radio units were not started and their masks were checked again."
echo "Bootstrap files under /var/lib/orp-test, /usr/local, and /opt/orp-test were not modified."
echo "No GPIO output, audio, or RF test was run."
if [ -n "$backup_root" ] && [ -d "$backup_root" ]; then
	echo "Backup of previous mutable files: ${backup_root}"
fi
