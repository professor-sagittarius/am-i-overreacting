#!/bin/bash
# Post-installation hook - runs after Nextcloud is installed

# Trusted domains from environment variable (space-separated)
index=0
for domain in ${NEXTCLOUD_TRUSTED_DOMAINS}; do
    php occ config:system:set trusted_domains $index --value="$domain"
    ((index++))
done

# LAN IP with port for direct access
if [ -n "${NEXTCLOUD_LAN_IP}" ]; then
    php occ config:system:set trusted_domains $index --value="${NEXTCLOUD_LAN_IP}:${NEXTCLOUD_LAN_PORT:-8888}"
fi

# Trusted proxies (Docker internal networks)
php occ config:system:set trusted_proxies 0 --value="172.16.0.0/12"
php occ config:system:set trusted_proxies 1 --value="10.0.0.0/8"
php occ config:system:set trusted_proxies 2 --value="192.168.0.0/16"

# Default phone region (ISO 3166-1 country code)
php occ config:system:set default_phone_region --value="${DEFAULT_PHONE_REGION}"

# Maintenance window start hour (local timezone)
php occ config:system:set maintenance_window_start --type=integer --value="${MAINTENANCE_WINDOW_START}"

# Add missing database indices
php occ db:add-missing-indices

# Run maintenance repair
php occ maintenance:repair --include-expensive
