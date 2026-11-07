#!/bin/bash
# Install the English Heather clips into the source-install sounds tree.
# This script does not download. It refuses an unverified archive, a symlink,
# and any tar member that leaves the en_US directory.
set -euo pipefail

ROOT=${ORP_ROOT:-}
ROOT=${ROOT%/}
SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
PIN_FILE=${ORP_SOUNDS_PIN:-$SCRIPT_DIR/share/heather-16k-25.05.sha256}
ARCHIVE=${1:-${ORP_SOUNDS_ARCHIVE:-}}
DEST="${ROOT}/usr/local/share/svxlink/sounds/en_US"

if [ "${ORP_SOUNDS_TEST_HARNESS:-0}" != 1 ] && [ "$(id -u)" -ne 0 ]; then
	echo "refused: sound installation runs as root" >&2
	exit 1
fi
if [ -z "$ARCHIVE" ]; then
	echo "refused: no archive path was given. Nothing was extracted." >&2
	exit 2
fi
case "$ARCHIVE" in
	/*) ;;
	*) echo "refused: archive path is not absolute. Nothing was extracted." >&2; exit 2 ;;
esac
if [ -L "$ARCHIVE" ] || [ ! -f "$ARCHIVE" ]; then
	echo "refused: archive is not a regular file. Nothing was extracted." >&2
	exit 2
fi
acc=""
rest=${ARCHIVE#/}
while [ -n "$rest" ]; do
	part=${rest%%/*}
	if [ "$rest" = "$part" ]; then rest=""; else rest=${rest#*/}; fi
	acc="${acc}/${part}"
	if [ -n "$rest" ] && [ -L "$acc" ]; then
		echo "refused: symbolic link in the archive path at ${acc}. Nothing was extracted." >&2
		exit 2
	fi
done

pin=$(grep -v '^[[:space:]]*#' "$PIN_FILE" | head -n 1 | tr -d '[:space:]')
if [ -z "$pin" ] || [ "$pin" = "UNVERIFIED" ]; then
	echo "refused: Heather archive digest is not pinned. Nothing was extracted." >&2
	exit 2
fi
if ! printf '%s\n' "$pin" | grep -qxE '[0-9a-f]{64}'; then
	echo "refused: pinned digest is not 64 hex characters. Nothing was extracted." >&2
	exit 2
fi
actual=$(sha256sum "$ARCHIVE" | awk '{print $1}')
if [ "$actual" != "$pin" ]; then
	echo "refused: archive digest does not match the pin. Nothing was extracted." >&2
	exit 2
fi

list=$(tar -tjf "$ARCHIVE")
while IFS= read -r member; do
	case "$member" in
		""|*..*|..|/*|*\\*)
			echo "refused: archive member ${member} escapes en_US. Nothing was extracted." >&2
			exit 2
			;;
	esac
done <<EOF
$list
EOF

if [ -L "$DEST" ]; then
	echo "refused: sounds destination is a symbolic link. Nothing was extracted." >&2
	exit 2
fi
parent=$(dirname "$DEST")
if [ ! -d "$parent" ] || [ -L "$parent" ]; then
	echo "refused: sounds parent is not a real directory. Nothing was extracted." >&2
	exit 2
fi
stage=$(mktemp -d)
tar -xjf "$ARCHIVE" -C "$stage"
if [ ! -d "$stage/en_US" ] || [ -L "$stage/en_US" ]; then
	rm -rf "$stage"
	echo "refused: archive does not contain a real en_US directory. Nothing was installed." >&2
	exit 2
fi
rm -rf "$DEST"
mkdir -p "$DEST"
cp -a "$stage/en_US/." "$DEST/"
rm -rf "$stage"
find "$DEST" -type l -print | grep -q . && {
	echo "refused: installed sounds contain a symbolic link." >&2
	exit 2
}
echo "installed ${DEST}"
