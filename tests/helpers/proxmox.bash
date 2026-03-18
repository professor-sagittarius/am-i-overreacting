# Helpers for testing Proxmox scripts.
# Sets up a mock bin/ directory on PATH with configurable responses for
# qm, pvesm, and disk commands. All qm invocations are logged to
# $BATS_TEST_TMPDIR/qm.calls for assertion.

MOCK_BIN="$BATS_TEST_TMPDIR/bin"
QM_MOCK_DIR="$BATS_TEST_TMPDIR/qm_mock"

setup_proxmox_mocks() {
	mkdir -p "$MOCK_BIN" "$QM_MOCK_DIR"
	export PATH="$MOCK_BIN:$PATH"
	_write_qm_mock
	_write_disk_mocks
}

# Set canned output and exit code for a qm subcommand + vmid pair.
# Usage: qm_respond <subcmd> <vmid> <output> [exit_code]
qm_respond() {
	local subcmd="$1" vmid="$2" output="$3" code="${4:-0}"
	printf '%s\n' "$output" >"$QM_MOCK_DIR/${subcmd}_${vmid}"
	printf '%s\n' "$code" >"$QM_MOCK_DIR/${subcmd}_${vmid}.exit"
}

assert_qm_called() {
	if ! grep -qF "$*" "$BATS_TEST_TMPDIR/qm.calls" 2>/dev/null; then
		fail "expected qm to be called with: $*"
	fi
}

refute_qm_called() {
	if grep -qF "$*" "$BATS_TEST_TMPDIR/qm.calls" 2>/dev/null; then
		fail "expected qm NOT to be called with: $*"
	fi
}

_write_qm_mock() {
	cat >"$MOCK_BIN/qm" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"${BATS_TEST_TMPDIR}/qm.calls"
subcmd="${1:-}"
vmid="${2:-}"
f="${BATS_TEST_TMPDIR}/qm_mock/${subcmd}_${vmid}"
if [[ -f "$f" ]]; then
	cat "$f"
	exit "$(cat "${f}.exit" 2>/dev/null || printf '0')"
fi
exit 0
EOF
	chmod +x "$MOCK_BIN/qm"
}

_write_disk_mocks() {
	# pvesm path: return a fake disk path
	cat >"$MOCK_BIN/pvesm" <<'EOF'
#!/usr/bin/env bash
[[ "${1:-}" == "path" ]] && printf '/dev/fake/disk0\n' && exit 0
exit 0
EOF
	# lsblk: no nbd partitions visible by default (nbd0 is free)
	printf '#!/usr/bin/env bash\nexit 0\n' >"$MOCK_BIN/lsblk"
	# Disk commands: all no-ops
	for cmd in modprobe qemu-nbd umount mount; do
		printf '#!/usr/bin/env bash\nexit 0\n' >"$MOCK_BIN/$cmd"
	done
	chmod +x "$MOCK_BIN/pvesm" "$MOCK_BIN/lsblk" "$MOCK_BIN/modprobe" \
		"$MOCK_BIN/qemu-nbd" "$MOCK_BIN/umount" "$MOCK_BIN/mount"
}
