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

# --- dev-vm-hook.sh: nbd check --------------------------------------------

@test "hook: /dev/nbd0 in use exits non-zero" {
	echo "dev-token-abc" >"$BATS_TEST_TMPDIR/token"
	# Override lsblk to report nbd partition visible
	printf '#!/usr/bin/env bash\nprintf "nbd0p1\\n"\nexit 0\n' >"$MOCK_BIN/lsblk"
	run env DEV_TOKEN_FILE="$BATS_TEST_TMPDIR/token" \
		ENV_FILE_PATH="/home/deploy/am-i-overreacting/reverse-proxy/.env" \
		bash "$REPO_ROOT/proxmox/dev-vm-hook.sh" 101 pre-start
	assert_failure
	assert_output --partial "already in use"
}

# --- dev-vm-hook.sh: disk resolution --------------------------------------

@test "hook: no scsi/virtio disk in config exits non-zero" {
	echo "dev-token-abc" >"$BATS_TEST_TMPDIR/token"
	qm_respond config 101 "name: dev-vm"
	run env DEV_TOKEN_FILE="$BATS_TEST_TMPDIR/token" \
		ENV_FILE_PATH="/home/deploy/am-i-overreacting/reverse-proxy/.env" \
		HOOKSCRIPT_MOUNT_POINT="$BATS_TEST_TMPDIR/mnt" \
		bash "$REPO_ROOT/proxmox/dev-vm-hook.sh" 101 pre-start
	assert_failure
	assert_output --partial "no scsi/virtio disk"
}

# --- dev-vm-hook.sh: .env check and token swap ----------------------------

@test "hook: missing .env on mounted partition exits non-zero" {
	echo "dev-token-abc" >"$BATS_TEST_TMPDIR/token"
	qm_respond config 101 "scsi0: local-lvm:vm-101-disk-0,size=32G"
	local mnt="$BATS_TEST_TMPDIR/mnt"
	mkdir -p "$mnt"
	run env DEV_TOKEN_FILE="$BATS_TEST_TMPDIR/token" \
		ENV_FILE_PATH="/home/deploy/am-i-overreacting/reverse-proxy/.env" \
		HOOKSCRIPT_MOUNT_POINT="$mnt" \
		NBD_SLEEP=0 \
		bash "$REPO_ROOT/proxmox/dev-vm-hook.sh" 101 pre-start
	assert_failure
	assert_output --partial ".env not found"
}

@test "hook: replaces CLOUDFLARE_TUNNEL_TOKEN and leaves other vars unchanged" {
	echo "dev-token-abc" >"$BATS_TEST_TMPDIR/token"
	qm_respond config 101 "scsi0: local-lvm:vm-101-disk-0,size=32G"
	local mnt="$BATS_TEST_TMPDIR/mnt"
	local env_file="$mnt/home/deploy/am-i-overreacting/reverse-proxy/.env"
	mkdir -p "$(dirname "$env_file")"
	printf 'CLOUDFLARE_TUNNEL_TOKEN=prod-token-xyz\nHOST_LAN_IP=192.168.1.100\n' \
		>"$env_file"
	run env DEV_TOKEN_FILE="$BATS_TEST_TMPDIR/token" \
		ENV_FILE_PATH="/home/deploy/am-i-overreacting/reverse-proxy/.env" \
		HOOKSCRIPT_MOUNT_POINT="$mnt" \
		NBD_SLEEP=0 \
		bash "$REPO_ROOT/proxmox/dev-vm-hook.sh" 101 pre-start
	assert_success
	assert_equal "$(grep CLOUDFLARE_TUNNEL_TOKEN "$env_file")" \
		"CLOUDFLARE_TUNNEL_TOKEN=dev-token-abc"
	assert_equal "$(grep HOST_LAN_IP "$env_file")" "HOST_LAN_IP=192.168.1.100"
}

@test "hook: exits non-zero when CLOUDFLARE_TUNNEL_TOKEN line is missing from .env" {
	echo "dev-token-abc" >"$BATS_TEST_TMPDIR/token"
	qm_respond config 101 "scsi0: local-lvm:vm-101-disk-0,size=32G"
	local mnt="$BATS_TEST_TMPDIR/mnt"
	local env_file="$mnt/home/deploy/am-i-overreacting/reverse-proxy/.env"
	mkdir -p "$(dirname "$env_file")"
	printf 'HOST_LAN_IP=192.168.1.100\n' >"$env_file"
	run env DEV_TOKEN_FILE="$BATS_TEST_TMPDIR/token" \
		ENV_FILE_PATH="/home/deploy/am-i-overreacting/reverse-proxy/.env" \
		HOOKSCRIPT_MOUNT_POINT="$mnt" \
		NBD_SLEEP=0 \
		bash "$REPO_ROOT/proxmox/dev-vm-hook.sh" 101 pre-start
	assert_failure
	assert_output --partial "verification failed"
}
