#!/usr/bin/env bash
# Proxmox hookscript: swaps CLOUDFLARE_TUNNEL_TOKEN in the dev VM .env
# before the VM boots. Assigned to dev VM only; no-op for all lifecycle
# phases except pre-start.
#
# Usage (called by Proxmox): dev-vm-hook.sh <vmid> <phase>
set -euo pipefail

VMID="${1:?vmid required}"
PHASE="${2:?phase required}"

# --- Config ---
# DEV_TOKEN_FILE and DISK_PARTITION have safe defaults.
# ENV_FILE_PATH has NO default - it must be set correctly for your VM layout
# before deploying. The script will refuse to run if it is empty.
DEV_TOKEN_FILE="${DEV_TOKEN_FILE:-/etc/proxmox/secrets/dev-cloudflare-token}"
DISK_PARTITION="${DISK_PARTITION:-1}"
ENV_FILE_PATH="${ENV_FILE_PATH:-}" # REQUIRED: e.g. /home/deploy/am-i-overreacting/reverse-proxy/.env
NBD_SLEEP="${NBD_SLEEP:-1}"
# ---------------

[[ "$PHASE" == "pre-start" ]] || exit 0

[[ -n "$ENV_FILE_PATH" ]] || {
	echo "ERROR: ENV_FILE_PATH is not set - edit the config block before deploying" >&2
	exit 1
}

MOUNT_POINT="${HOOKSCRIPT_MOUNT_POINT:-/mnt/dev-vm-${VMID}}"
_MOUNT_POINT_CREATED=0

cleanup() {
	umount "$MOUNT_POINT" 2>/dev/null || true
	qemu-nbd --disconnect /dev/nbd0 2>/dev/null || true
	[[ "$_MOUNT_POINT_CREATED" == "1" ]] && rm -rf "$MOUNT_POINT" 2>/dev/null || true
}

[[ -f "$DEV_TOKEN_FILE" ]] || {
	echo "ERROR: dev token file not found: $DEV_TOKEN_FILE" >&2
	exit 1
}
dev_token=$(cat "$DEV_TOKEN_FILE")
[[ -n "$dev_token" ]] || {
	echo "ERROR: dev token file is empty" >&2
	exit 1
}

# Check /dev/nbd0 availability
if lsblk -n -o NAME /dev/nbd0 2>/dev/null | grep -qE "nbd0p"; then
	echo "ERROR: /dev/nbd0 is already in use - disconnect it first" >&2
	exit 1
fi

# Resolve disk path from VM config
disk_entry=$(qm config "$VMID" | grep -E "^(scsi|virtio)[0-9]+:" | head -1 || true)
[[ -n "$disk_entry" ]] || {
	echo "ERROR: no scsi/virtio disk found in VM $VMID config" >&2
	exit 1
}
disk_ref=$(echo "$disk_entry" | sed 's/^[^:]*: //' | cut -d, -f1)
disk_path=$(pvesm path "$disk_ref")

# Mount disk and swap token
trap cleanup EXIT
modprobe nbd
[[ -d "$MOUNT_POINT" ]] || {
	mkdir -p "$MOUNT_POINT"
	_MOUNT_POINT_CREATED=1
}
qemu-nbd --connect=/dev/nbd0 "$disk_path"
sleep "$NBD_SLEEP"
mount "/dev/nbd0p${DISK_PARTITION}" "$MOUNT_POINT"

# Verify .env exists on mounted partition
env_file="${MOUNT_POINT}/${ENV_FILE_PATH#/}"
[[ -f "$env_file" ]] || {
	echo "ERROR: .env not found at $env_file" >&2
	exit 1
}

# Replace token
sed -i "s|^CLOUDFLARE_TUNNEL_TOKEN=.*|CLOUDFLARE_TUNNEL_TOKEN=${dev_token}|" "$env_file"

# Verify replacement succeeded
actual_token=$(grep "^CLOUDFLARE_TUNNEL_TOKEN=" "$env_file" | cut -d= -f2- || true)
[[ "$actual_token" == "$dev_token" ]] || {
	echo "ERROR: token replacement verification failed - CLOUDFLARE_TUNNEL_TOKEN line may be missing from .env" >&2
	exit 1
}

echo "dev-vm-hook: CLOUDFLARE_TUNNEL_TOKEN swapped successfully for VM $VMID"
