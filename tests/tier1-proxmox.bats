#!/usr/bin/env bats
# Tier 1: Unit tests for Proxmox scripts. No Docker or Proxmox required.

setup() {
	load 'lib/bats-support/load'
	load 'lib/bats-assert/load'
	load 'helpers/common.bash'
	load 'helpers/proxmox.bash'
	setup_proxmox_mocks
}

# --- dev-vm-hook.sh: phase check ------------------------------------------

@test "hook: non-pre-start phase exits 0 without doing anything" {
	run bash "$REPO_ROOT/proxmox/dev-vm-hook.sh" 101 post-start
	assert_success
	refute_qm_called "config 101"
}

# --- dev-vm-hook.sh: token file validation --------------------------------

@test "hook: unset ENV_FILE_PATH exits non-zero" {
	run env ENV_FILE_PATH="" \
		DEV_TOKEN_FILE="$BATS_TEST_TMPDIR/token" \
		HOOKSCRIPT_MOUNT_POINT="$BATS_TEST_TMPDIR/mnt" \
		bash "$REPO_ROOT/proxmox/dev-vm-hook.sh" 101 pre-start
	assert_failure
	assert_output --partial "ENV_FILE_PATH"
}

@test "hook: missing token file exits non-zero" {
	run env ENV_FILE_PATH="/home/deploy/am-i-overreacting/reverse-proxy/.env" \
		DEV_TOKEN_FILE="$BATS_TEST_TMPDIR/nonexistent" \
		HOOKSCRIPT_MOUNT_POINT="$BATS_TEST_TMPDIR/mnt" \
		bash "$REPO_ROOT/proxmox/dev-vm-hook.sh" 101 pre-start
	assert_failure
	assert_output --partial "token file not found"
}

@test "hook: empty token file exits non-zero" {
	touch "$BATS_TEST_TMPDIR/empty-token"
	run env ENV_FILE_PATH="/home/deploy/am-i-overreacting/reverse-proxy/.env" \
		DEV_TOKEN_FILE="$BATS_TEST_TMPDIR/empty-token" \
		HOOKSCRIPT_MOUNT_POINT="$BATS_TEST_TMPDIR/mnt" \
		bash "$REPO_ROOT/proxmox/dev-vm-hook.sh" 101 pre-start
	assert_failure
	assert_output --partial "empty"
}
