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

if [ -n "${ORP_ROOT:-}" ] || [ "${ORP_INSTALL_OFFLINE:-0}" = 1 ] || [ "${ORP_INSTALL_APPLY_OWNERSHIP:-0}" = 1 ]; then
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
mode_file=$(p /etc/openrepeater/operating-mode)
if [ "$(bench_lstat_kind "$mode_file")" = missing ]; then
	mode_body=$(mktemp)
	printf '%s\n' 'bench' > "$mode_body"
	bench_place_file "$mode_body" "$mode_file"
	rm -f "$mode_body"
fi
bench_chmod 755 "$(p /etc/openrepeater)"
bench_chmod 755 "$(p /var/lib/openrepeater)"
bench_chmod 755 "$(p /var/lib/openrepeater/bench-preview)"
bench_chmod 755 "$(p /var/lib/openrepeater/db)"
bench_chmod 644 "$(p /etc/openrepeater/bench-mode)"
if [ -f "$(p /etc/openrepeater/operating-mode)" ] && [ ! -L "$(p /etc/openrepeater/operating-mode)" ]; then
	bench_chmod 644 "$(p /etc/openrepeater/operating-mode)"
	bench_chown root:root "$(p /etc/openrepeater/operating-mode)"
fi
bench_chown root:root "$(p /etc/openrepeater)"
bench_chown root:root "$(p /etc/openrepeater/bench-mode)"
bench_chown root:root "$(p /var/lib/openrepeater)"
# Directory inodes only. www-data can create new files here and cannot
# replace a root-owned inode. Root does not chown files inside these directories.
if getent group www-data >/dev/null 2>&1 && { [ "${ORP_INSTALL_OFFLINE:-0}" != 1 ] || [ "${ORP_INSTALL_APPLY_OWNERSHIP:-0}" = 1 ]; }; then
	web_group=www-data
else
	web_group=$(id -gn)
fi
bench_chown "root:${web_group}" "$(p /var/lib/openrepeater/bench-preview)"
bench_chmod 1770 "$(p /var/lib/openrepeater/bench-preview)"
bench_chown "root:${web_group}" "$(p /var/lib/openrepeater/db)"

# Same rule as bench_assert_masks. A /dev/null mask is accepted. A trusted
# functional-test token may instead leave the unit inactive and disabled.
# Do not create a mask and do not replace one.
for unit in svxlink.service remotetrx.service svxreflector.service; do
	link=$(p "/etc/systemd/system/${unit}")
	if [ -L "$link" ] && [ "$(readlink "$link")" = "/dev/null" ]; then
		continue
	fi
	enabled=$(unit_enabled_state "$unit")
	active=$(unit_active_state "$unit")
	if bench_mode_is_functional_test && [ "$enabled" = "disabled" ] && [ "$active" = "inactive" ]; then
		continue
	fi
	echo "refused: ${unit} is not a /dev/null mask, and it is not inactive and disabled under a functional-test token. It was not replaced." >&2
	exit 4
done
if ! env ORP_ROOT="$ROOT" "$REPO_ROOT/install/scripts/orp_helper" native inputs; then
	echo "refused: native SvxLink layout is incomplete. No unit was written and no service was unmasked." >&2
	exit 7
fi

if [ "${ORP_INSTALL_OFFLINE:-0}" != 1 ] && [ "${ORP_INSTALL_SKIP_APT:-0}" != 1 ]; then
	install_service_block
	export DEBIAN_FRONTEND=noninteractive
	if ! bench_install_php84; then
		exit 5
	fi
	# PHP is handled above and may move to the security candidate.
	# These packages stay at the version already installed.
	bench_apt install -y --no-install-recommends --no-upgrade \
		nginx gpiod sudo sqlite3
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
	php_unit=php8.4-fpm
	if ! orp_systemctl list-unit-files --no-legend 'php8.4-fpm.service' | awk '{print $1}' | grep -qx 'php8.4-fpm.service'; then
		echo "refused: php8.4-fpm is not installed" >&2
		exit 5
	fi
	orp_systemctl start "$php_unit"
	if [ -S "/run/php/php8.4-fpm.sock" ]; then
		PHP_SOCK="/run/php/php8.4-fpm.sock"
	elif [ -S "/var/run/php/php8.4-fpm.sock" ]; then
		PHP_SOCK="/var/run/php/php8.4-fpm.sock"
	else
		echo "refused: php8.4-fpm socket was not created" >&2
		exit 5
	fi
fi

bench_trace stage-www
stage=$(p /var/lib/openrepeater/stage)
web=$(p /var/www/openrepeater)
sounds=$(p /var/www/openrepeater/sounds)
backup_anchor=$(p /var/www/openrepeater/backup)
hold=$(p "/var/lib/openrepeater/ui-preserve.${STAMP}")
bench_anchor_dir "$(p /var/www)"
for anchor in "$sounds" "$backup_anchor"; do
	case "$(bench_lstat_kind "$anchor")" in
		symlink)
			echo "refused: $anchor is a symbolic link" >&2
			exit 6
			;;
	esac
	bench_require_real_components "$anchor" || exit 6
done
if [ "$(bench_lstat_kind "$sounds")" = dir ] || [ "$(bench_lstat_kind "$backup_anchor")" = dir ]; then
	bench_anchor_dir "$hold"
fi
if [ "$(bench_lstat_kind "$sounds")" = dir ]; then
	mv "$sounds" "$hold/sounds"
fi
if [ "$(bench_lstat_kind "$backup_anchor")" = dir ]; then
	mv "$backup_anchor" "$hold/backup"
fi
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
# Do not copy the source mode or owner. A read-only payload would leave
# the web root mode 0555, and the sounds directory could not be created.
tar -C "$REPO_ROOT" --exclude=.git --exclude=dev -cf - . \
	| tar -C "$stage" --no-same-permissions --no-same-owner -xf -
bench_publish_tree_modes "$stage"
# upgrade/ and install/ stay out of the docroot. The helper is installed
# at /usr/sbin and must not source a file www-data can edit.
tar -C "$stage" --exclude=.git --exclude=dev --exclude=upgrade --exclude=install -cf - . \
	| tar -C "$web" --no-same-permissions --no-same-owner -xf -
bench_publish_tree_modes "$web"
if [ "${ORP_INSTALL_OFFLINE:-0}" != 1 ]; then
	find -P "$web" -xdev ! -type l -exec chown -h www-data:www-data {} +
fi
bench_chown www-data:www-data "$web"
install_web_anchor() {
	local name=$1
	local dest="$web/$name"
	local held="$hold/$name"
	case "$(bench_lstat_kind "$dest")" in
		symlink)
			echo "refused: $dest is a symbolic link" >&2
			exit 6
			;;
	esac
	if [ "$(bench_lstat_kind "$held")" = dir ]; then
		if [ "$(bench_lstat_kind "$dest")" = dir ]; then
			mv "$dest" "$hold/${name}.packaged"
		elif [ "$(bench_lstat_kind "$dest")" != missing ]; then
			echo "refused: $dest is occupied and the preserved $name tree was not restored" >&2
			exit 6
		fi
		mv "$held" "$dest"
	elif [ "$(bench_lstat_kind "$dest")" = missing ]; then
		bench_mkdir_nofollow "$dest" || exit 6
	fi
	bench_chmod 1770 "$dest"
	bench_chown "root:${web_group}" "$dest"
}
install_web_child() {
	local dest=$1
	case "$(bench_lstat_kind "$dest")" in
		symlink)
			echo "refused: $dest is a symbolic link" >&2
			exit 6
			;;
		missing)
			bench_mkdir_nofollow "$dest" || exit 6
			;;
		dir)
			;;
		*)
			echo "refused: $dest is not a directory" >&2
			exit 6
			;;
	esac
	bench_chmod 0755 "$dest"
	bench_chown "${web_group}:${web_group}" "$dest"
}
install_web_anchor sounds
install_web_anchor backup
install_web_child "$web/sounds/courtesy_tones"
install_web_child "$web/sounds/identification"
install_web_child "$web/backup/restore"

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
www-data ALL=(root) NOPASSWD: /usr/sbin/orp_helper svxlink start
www-data ALL=(root) NOPASSWD: /usr/sbin/orp_helper svxlink stop
www-data ALL=(root) NOPASSWD: /usr/sbin/orp_helper svxlink restart
www-data ALL=(root) NOPASSWD: /usr/sbin/orp_helper config publish
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

# Account, log, and state directories for the reviewed unit. The unit file
# goes to the /usr/local vendor directory. The /etc mask is not replaced.
if [ -n "$ROOT" ]; then
	touch "$(p /etc/passwd)" "$(p /etc/group)"
	if ! grep -q '^svxlink:' "$(p /etc/group)"; then
		printf '%s\n' 'svxlink:x:200:' >> "$(p /etc/group)"
	fi
	if ! grep -q '^svxlink:' "$(p /etc/passwd)"; then
		printf '%s\n' 'svxlink:x:200:200::/var/lib/svxlink:/usr/sbin/nologin' >> "$(p /etc/passwd)"
	fi
else
	getent group svxlink >/dev/null || groupadd --system svxlink
	getent passwd svxlink >/dev/null || useradd --system --gid svxlink --home-dir /var/lib/svxlink --shell /usr/sbin/nologin svxlink
fi
# These directories are owned by the svxlink user after the first install.
# Repeat installs must not try to reclaim that ownership as the installer.
ensure_service_dir() {
	local path=$1
	case "$(bench_lstat_kind "$path")" in
		symlink|file|other)
			echo "refused: $path is not a directory" >&2
			exit 6
			;;
		missing)
			bench_anchor_dir "$(dirname "$path")"
			mkdir -m 755 "$path"
			;;
	esac
	bench_chmod 755 "$path"
	bench_chown svxlink:svxlink "$path"
}
ensure_service_dir "$(p /var/lib/svxlink)"
ensure_service_dir "$(p /var/spool/svxlink)"
bench_anchor_dir "$(p /var/log)"
svx_log=$(p /var/log/svxlink)
case "$(bench_lstat_kind "$svx_log")" in
	symlink|dir|other)
		echo "refused: /var/log/svxlink is not a regular file" >&2
		exit 6
		;;
	missing)
		: > "$svx_log"
		;;
esac
bench_chmod 755 "$(p /var/lib/svxlink)"
bench_chmod 755 "$(p /var/spool/svxlink)"
bench_chmod 644 "$svx_log"
bench_chown svxlink:svxlink "$(p /var/lib/svxlink)"
bench_chown svxlink:svxlink "$(p /var/spool/svxlink)"
bench_chown svxlink:svxlink "$svx_log"
# A masked bench receives the reviewed vendor unit and keeps its /dev/null
# symlinks. A functional-test bench does not get that file installed over
# anything, and its /etc unit files are not replaced or enabled.
write_vendor_unit=1
for unit in svxlink.service remotetrx.service svxreflector.service; do
	link=$(p "/etc/systemd/system/${unit}")
	if [ -L "$link" ] && [ "$(readlink "$link")" = "/dev/null" ]; then
		continue
	fi
	write_vendor_unit=0
	break
done
if [ "$write_vendor_unit" -eq 1 ]; then
	unit_body=$(mktemp)
	env ORP_ROOT="$ROOT" "$(p /usr/sbin/orp_helper)" native unit > "$unit_body"
	bench_place_file "$unit_body" "$(p /usr/local/lib/systemd/system/svxlink.service)"
	rm -f "$unit_body"
	bench_chmod 644 "$(p /usr/local/lib/systemd/system/svxlink.service)"
	bench_chown root:root "$(p /usr/local/lib/systemd/system/svxlink.service)"
fi
for unit in svxlink.service remotetrx.service svxreflector.service; do
	link=$(p "/etc/systemd/system/${unit}")
	if [ -L "$link" ] && [ "$(readlink "$link")" = "/dev/null" ]; then
		continue
	fi
	enabled=$(unit_enabled_state "$unit")
	active=$(unit_active_state "$unit")
	if bench_mode_is_functional_test && [ "$enabled" = "disabled" ] && [ "$active" = "inactive" ]; then
		continue
	fi
	echo "refused: ${unit} is not a /dev/null mask, and it is not inactive and disabled under a functional-test token. It was not replaced." >&2
	exit 4
done
if ! env ORP_ROOT="$ROOT" "$(p /usr/sbin/orp_helper)" native preflight; then
	echo "refused: native preflight failed after the vendor unit was written" >&2
	exit 7
fi
orp_systemctl daemon-reload

db_file=$(p /var/lib/openrepeater/db/openrepeater.db)
# Parent is anchored above, so a planted symlink cannot be swapped in now.
if ! bench_ensure_regular "$db_file"; then
	exit 6
fi
# An existing database is the station account and configuration. A reinstall
# copies the stock file only when this path is missing. It does not seed
# over users, settings, ports, or modules.
if [ "$(bench_lstat_kind "$db_file")" = missing ]; then
	bench_place_file "$REPO_ROOT/install/sql/openrepeater.db" "$db_file"
fi
bench_chmod 660 "$db_file"
bench_chown "root:${web_group}" "$db_file"
# Sticky and group-writable only after the database inode is root-owned.
# www-data can create SQLite journals and cannot replace that inode.
bench_chmod 1770 "$(p /var/lib/openrepeater/db)"

# Re-assert the marker after file publish. It stays root-owned and not web-writable.
bench_chmod 755 "$(p /etc/openrepeater)"
bench_chmod 644 "$(p /etc/openrepeater/bench-mode)"
if [ -f "$(p /etc/openrepeater/operating-mode)" ] && [ ! -L "$(p /etc/openrepeater/operating-mode)" ]; then
	bench_chmod 644 "$(p /etc/openrepeater/operating-mode)"
	bench_chown root:root "$(p /etc/openrepeater/operating-mode)"
fi
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
echo "Bootstrap binary, share tree, and /etc/svxlink/svxlink.conf were not modified."
if [ "$write_vendor_unit" -eq 1 ]; then
	echo "The reviewed unit is /usr/local/lib/systemd/system/svxlink.service. The /dev/null masks were left in place."
else
	echo "Radio units stayed inactive and disabled. No vendor unit was installed and no unit was enabled."
fi
echo "No GPIO output, audio, or RF test was run."
if [ -d "$backup_root" ]; then
	echo "Backup of previous mutable files: ${backup_root}"
fi
