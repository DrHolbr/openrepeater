#!/bin/bash
# Host reboot, shutdown, and halt verdicts. The harness must not execute them.
set -euo pipefail

ROOT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
# shellcheck source=lib/fixture_tmpdir.sh
. "$ROOT_DIR/upgrade/tests/lib/fixture_tmpdir.sh"
orp_use_fixture_tmpdir
tmp=$(orp_mktemp_dir)
trap 'rm -rf "$tmp"' EXIT
HELPER="$ROOT_DIR/install/scripts/orp_helper"
mkdir -p "$tmp/bin"
cat > "$tmp/bin/shutdown" <<'EOF'
#!/bin/bash
printf 'shutdown %s\n' "$*" >> "${POWER_LOG:?}"
exit 99
EOF
cat > "$tmp/bin/halt" <<'EOF'
#!/bin/bash
printf 'halt %s\n' "$*" >> "${POWER_LOG:?}"
exit 99
EOF
chmod 755 "$tmp/bin/shutdown" "$tmp/bin/halt"
power_log="$tmp/power.log"
: > "$power_log"

verdict() {
	local verb=$1
	local out rc
	set +e
	out=$(PATH="$tmp/bin:$PATH" POWER_LOG="$power_log" ORP_BENCH_TEST_HARNESS=1 "$HELPER" system "$verb" 2>&1)
	rc=$?
	set -e
	if [ "$rc" -ne 0 ] || [ "$out" != "host-action-accepted system ${verb}" ]; then
		echo "FAIL: system ${verb} rc=${rc} out=${out}" >&2
		exit 1
	fi
	echo "ok: system ${verb} is accepted and does not run the power command"
}

verdict reboot
verdict shutdown
verdict halt
if [ -s "$power_log" ]; then
	echo "FAIL: a power command ran: $(cat "$power_log")" >&2
	exit 1
fi

set +e
alias_out=$(PATH="$tmp/bin:$PATH" POWER_LOG="$power_log" ORP_BENCH_TEST_HARNESS=1 "$HELPER" system restart 2>&1)
alias_rc=$?
set -e
if [ "$alias_rc" -eq 0 ] || ! printf '%s\n' "$alias_out" | grep -q 'INVALID OPTION'; then
	echo "FAIL: system restart is still a host power verb: ${alias_out}" >&2
	exit 1
fi
if [ -s "$power_log" ]; then
	echo "FAIL: the rejected verb ran a power command" >&2
	exit 1
fi
echo "ok: system restart is not host reboot"
echo "host power verdicts passed"
