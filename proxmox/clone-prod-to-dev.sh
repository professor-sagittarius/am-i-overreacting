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
	dev_exists=true
	dev_name=$(qm config "$DEV_VMID" | awk '/^name:/{print $2}')
	! qm config "$DEV_VMID" | grep -q "^protection: 1" ||
		die "Dev VM $DEV_VMID (${dev_name:-unknown}) is protected - variables may be swapped"
fi

[[ -f "$HOOKSCRIPT_FILE" ]] ||
	die "Hookscript not found at $HOOKSCRIPT_FILE"

[[ -f "$DEV_TOKEN_FILE" && -s "$DEV_TOKEN_FILE" ]] ||
	die "Dev token file not found or empty at $DEV_TOKEN_FILE"

# Show what will happen
echo ""
if $dev_exists; then
	echo "This will DESTROY: ${dev_name:-unknown} ($DEV_VMID)"
else
	echo "This will CREATE:  $DEV_VM_NAME ($DEV_VMID) (first time)"
fi
echo "Re-cloned from:    ${prod_name:-unknown} ($PROD_VMID)"
echo ""

if $DRY_RUN; then
	echo "[dry-run] No changes made."
	exit 0
fi

read -rp "Type 'yes' to continue: " confirmation
[[ "$confirmation" == "yes" ]] || {
	echo "Aborted."
	exit 1
}

# Stop and destroy existing dev VM if present
if $dev_exists; then
	dev_status=$(qm status "$DEV_VMID" | awk '{print $2}')
	[[ "$dev_status" != "running" ]] || qm stop "$DEV_VMID"
	qm destroy "$DEV_VMID"
fi

# Clone, verify, assign hookscript, start
qm clone "$PROD_VMID" "$DEV_VMID" --name "$DEV_VM_NAME" --full

qm config "$DEV_VMID" &>/dev/null ||
	die "Clone verification failed - VM $DEV_VMID has no config after clone"

qm set "$DEV_VMID" --hookscript "$HOOKSCRIPT"
qm start "$DEV_VMID"

printf '%s [%s] SUCCESS: cloned %s (%s) -> %s (%s)\n' \
	"$(date '+%Y-%m-%d %H:%M:%S')" "${USER:-unknown}" \
	"$PROD_VMID" "${prod_name:-unknown}" \
	"$DEV_VMID" "$DEV_VM_NAME" |
	tee -a "$LOG_FILE"
