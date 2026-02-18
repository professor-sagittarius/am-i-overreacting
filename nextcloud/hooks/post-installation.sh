#!/bin/bash
# Post-installation hook - runs after Nextcloud is installed

# Trusted proxies (Docker internal networks)
php occ config:system:set trusted_proxies 0 --value="172.16.0.0/12"
php occ config:system:set trusted_proxies 1 --value="10.0.0.0/8"
php occ config:system:set trusted_proxies 2 --value="192.168.0.0/16"

# Default phone region (ISO 3166-1 country code)
php occ config:system:set default_phone_region --value="${DEFAULT_PHONE_REGION}"

# Maintenance window start hour (local timezone)
php occ config:system:set maintenance_window_start --type=integer --value="${MAINTENANCE_WINDOW_START}"

# Generate HTTPS links through the reverse proxy
php occ config:system:set overwriteprotocol --value="https"

# Add missing database indices
php occ db:add-missing-indices

# Run maintenance repair
php occ maintenance:repair --include-expensive
