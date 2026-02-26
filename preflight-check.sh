#!/bin/bash
# Run before 'docker compose up' to catch unconfigured placeholders.
set -euo pipefail
FOUND=0
for f in nextcloud/.env gitea/.env vaultwarden/.env backup/.env reverse-proxy/.env; do
  if [ ! -f "$f" ]; then
    echo "WARNING: $f not found - copy from example.env and configure"
    FOUND=$((FOUND+1))
    continue
  fi
  if grep -qE '^[A-Za-z_]+=changeme( |#|$)' "$f"; then
    echo "ERROR: Placeholder values remain in $f:"
    grep -E '^[A-Za-z_]+=changeme( |#|$)' "$f"
    FOUND=$((FOUND+1))
  fi
done
[ "$FOUND" -eq 0 ] && echo "Preflight OK: no placeholder values found." || exit 1
