#!/bin/bash
# Post-installation hook - runs after Nextcloud is installed

# Default phone region (ISO 3166-1 country code)
if [ -n "${DEFAULT_PHONE_REGION}" ]; then
  php occ config:system:set default_phone_region --value="${DEFAULT_PHONE_REGION}"
fi

# Maintenance window start hour (local timezone)
if [ -n "${MAINTENANCE_WINDOW_START}" ]; then
  php occ config:system:set maintenance_window_start --type=integer --value="${MAINTENANCE_WINDOW_START}"
fi

# Set CLI URL to first trusted domain (used for self-checks including HSTS validation)
if [ -n "${NEXTCLOUD_TRUSTED_DOMAINS}" ] && ! echo "${NEXTCLOUD_TRUSTED_DOMAINS}" | grep -q "yourdomain.com"; then
  PRIMARY_DOMAIN=$(echo "${NEXTCLOUD_TRUSTED_DOMAINS}" | awk '{print $1}')
  php occ config:system:set overwrite.cli.url --value="https://${PRIMARY_DOMAIN}"
fi

# Use system cron for background jobs
php occ background:cron

# Install apps from NEXTCLOUD_APPS
for app in ${NEXTCLOUD_APPS}; do
  php occ app:install "$app"
done

# Configure Collabora Online (richdocuments)
if [ -n "${COLLABORA_URL}" ] && ! echo "${COLLABORA_URL}" | grep -q "yourdomain.com"; then
  php occ config:app:set richdocuments wopi_url --value="${COLLABORA_URL}"
  if [ -n "${COLLABORA_WOPI_ALLOWLIST}" ]; then
    php occ config:app:set richdocuments wopi_allowlist --value="${COLLABORA_WOPI_ALLOWLIST}"
  fi
fi

# Register AppAPI deploy daemon (HaRP)
if [ -n "${HP_SHARED_KEY}" ]; then
  php occ app_api:daemon:register harp_proxy_docker "Harp Proxy (Docker)" "docker-install" "http" "nextcloud_harp:8780" "http://nextcloud_app" --net exapps_network --harp --harp_frp_address "nextcloud_harp:8782" --harp_shared_key "${HP_SHARED_KEY}" --set-default
fi

# Add missing database indices
php occ db:add-missing-indices

# Run maintenance repair
php occ maintenance:repair --include-expensive
