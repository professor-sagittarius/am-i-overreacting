#!/usr/bin/env bash
# Clone prod VM to dev VM and assign the hookscript so cloudflared uses
# the dev Cloudflare tunnel token on first boot.
#
# Usage: clone-prod-to-dev.sh [--dry-run]
set -euo pipefail

# --- Config (override via env vars for testing) ---
PROD_VMID="${PROD_VMID:-100}"
DEV_VMID="${DEV_VMID:-101}"
DEV_VM_NAME="${DEV_VM_NAME:-dev-vm}"
HOOKSCRIPT="${HOOKSCRIPT:-local:snippets/dev-vm-hook.sh}"
HOOKSCRIPT_FILE="${HOOKSCRIPT_FILE:-/var/lib/vz/snippets/dev-vm-hook.sh}"
DEV_TOKEN_FILE="${DEV_TOKEN_FILE:-/etc/proxmox/secrets/dev-cloudflare-token}"
LOG_FILE="${LOG_FILE:-/var/log/clone-prod-to-dev.log}"
# --------------------------------------------------

DRY_RUN=false
# shellcheck disable=SC2034  # used in execution flow (Task 5)
[[ "${1:-}" == "--dry-run" ]] && DRY_RUN=true

die() {
	echo "ERROR: $*" >&2
	printf '%s [%s] FAILED: %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "${USER:-unknown}" "$*" \
		>>"$LOG_FILE" 2>/dev/null || true
	exit 1
}

# Pre-flight checks
[[ "$PROD_VMID" != "$DEV_VMID" ]] ||
	die "PROD_VMID and DEV_VMID are the same ($PROD_VMID) - check config block"

qm status "$PROD_VMID" &>/dev/null ||
	die "Prod VM $PROD_VMID does not exist"

prod_name=$(qm config "$PROD_VMID" | awk '/^name:/{print $2}')
qm config "$PROD_VMID" | grep -q "^protection: 1" ||
	die "Prod VM $PROD_VMID (${prod_name:-unknown}) is not protected - refusing to proceed"

dev_exists=false
dev_name=""
if qm status "$DEV_VMID" &>/dev/null; then
	# shellcheck disable=SC2034  # used in execution flow (Task 5)
	dev_exists=true
	dev_name=$(qm config "$DEV_VMID" | awk '/^name:/{print $2}')
	! qm config "$DEV_VMID" | grep -q "^protection: 1" ||
		die "Dev VM $DEV_VMID (${dev_name:-unknown}) is protected - variables may be swapped"
fi

[[ -f "$HOOKSCRIPT_FILE" ]] ||
	die "Hookscript not found at $HOOKSCRIPT_FILE"

[[ -f "$DEV_TOKEN_FILE" && -s "$DEV_TOKEN_FILE" ]] ||
	die "Dev token file not found or empty at $DEV_TOKEN_FILE"
