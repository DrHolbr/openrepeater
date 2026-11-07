#!/bin/bash
# Set the root-owned operating mode for the orp-test host.
# Does not unmask a unit, start svxlink, or drive a GPIO line.
set -euo pipefail

token=${1:-}
case "$token" in
	bench|functional-test) ;;
	*)
		echo "usage: set-operating-mode.sh bench|functional-test" >&2
		exit 2
		;;
esac

if [ "$(id -u)" -ne 0 ]; then
	echo "refused: operating mode is set by root" >&2
	exit 1
fi

root=${ORP_ROOT:-}
host=$(tr -d '[:space:]' < "${root}/etc/hostname")
if [ "$host" != "orp-test" ]; then
	echo "refused: operating mode switch is only for hostname orp-test" >&2
	exit 2
fi

dest="${root}/etc/openrepeater/operating-mode"
if [ -L "$dest" ]; then
	echo "refused: operating-mode is a symbolic link" >&2
	exit 6
fi
mkdir -p "${root}/etc/openrepeater"
tmp=$(mktemp)
printf '%s\n' "$token" > "$tmp"
install -m 644 "$tmp" "$dest"
rm -f "$tmp"
echo "operating-mode=${token}"
echo "no unit was unmasked and no transmitter command was sent"
