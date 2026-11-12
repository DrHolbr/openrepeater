# Live-tree guard. Listings use sudo -n so mode 1770 root:www-data
# directories are readable. A find failure is reported here. pipefail is
# turned off around the pipeline so a find status does not abort the suite
# by itself. Live database writes or apt activity can change these trees
# and trip the guard.

host_tree_default_paths() {
	printf '%s\n' \
		/var/www/openrepeater \
		/etc/openrepeater \
		/etc/svxlink \
		/etc/sudoers.d \
		/etc/systemd/system \
		/var/lib/openrepeater \
		/usr/local/share/svxlink \
		/usr/sbin/orp_helper
}

host_tree_meta() {
	local dest=$1 path raw rc
	shift
	: > "$dest"
	raw=$(mktemp)
	for path in "$@"; do
		if [ ! -e "$path" ] && [ ! -L "$path" ]; then
			printf 'absent %s\n' "$path" >> "$dest"
			continue
		fi
		set +e
		sudo -n find -P "$path" -xdev -printf '%p %y %u %g %m %s %T@\n' > "$raw" 2>"$raw.err"
		rc=$?
		set -e
		if [ "$rc" -ne 0 ]; then
			echo "FAIL: live-tree guard could not list ${path} (sudo find exit ${rc}). Live database writes or apt activity can change these trees and trip the guard. This is not a pipefail abort." >&2
			cat "$raw.err" >&2 || true
			rm -f "$raw" "$raw.err"
			return 1
		fi
		rm -f "$raw.err"
		cat "$raw" >> "$dest"
	done
	rm -f "$raw"
	sort -o "$dest" "$dest"
}

# One pipeline for every existing path. -print0 and xargs -0 keep spaces.
host_tree_sha() {
	local dest=$1 path raw st
	shift
	local existing=()
	: > "$dest"
	for path in "$@"; do
		if [ ! -e "$path" ] && [ ! -L "$path" ]; then
			printf 'absent %s\n' "$path" >> "$dest"
			continue
		fi
		existing+=("$path")
	done
	if [ "${#existing[@]}" -eq 0 ]; then
		sort -o "$dest" "$dest"
		return 0
	fi
	raw=$(mktemp)
	set +e
	set +o pipefail
	sudo -n find -P "${existing[@]}" -xdev -type f -print0 | sudo -n xargs -0 -r sha256sum | sort > "$raw"
	st=("${PIPESTATUS[@]}")
	set -o pipefail
	set -e
	if [ "${#st[@]}" -lt 3 ] || [ "${st[0]}" -ne 0 ] || [ "${st[1]}" -ne 0 ] || [ "${st[2]}" -ne 0 ]; then
		echo "FAIL: live-tree guard sha listing failed (statuses ${st[*]:-unknown}). Live database writes or apt activity can change these trees and trip the guard. This is not a pipefail abort." >&2
		rm -f "$raw"
		return 1
	fi
	cat "$raw" >> "$dest"
	rm -f "$raw"
	sort -o "$dest" "$dest"
}
