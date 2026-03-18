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
ENV_FILE_PATH="${ENV_FILE_PATH:-}"    # REQUIRED: e.g. /home/deploy/am-i-overreacting/reverse-proxy/.env
NBD_SLEEP="${NBD_SLEEP:-1}"
# ---------------

[[ "$PHASE" == "pre-start" ]] || exit 0

[[ -n "$ENV_FILE_PATH" ]] || {
	echo "ERROR: ENV_FILE_PATH is not set - edit the config block before deploying" >&2
	exit 1
}

MOUNT_POINT="${HOOKSCRIPT_MOUNT_POINT:-/mnt/dev-vm-${VMID}}"

cleanup() {
	umount "$MOUNT_POINT" 2>/dev/null || true
	qemu-nbd --disconnect /dev/nbd0 2>/dev/null || true
	rmdir "$MOUNT_POINT" 2>/dev/null || true
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
