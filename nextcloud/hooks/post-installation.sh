#!/bin/bash
# Post-installation hook - runs after Nextcloud is installed

# Trusted proxies (Docker internal networks)
php occ config:system:set trusted_proxies 0 --value="172.16.0.0/12"
php occ config:system:set trusted_proxies 1 --value="10.0.0.0/8"
php occ config:system:set trusted_proxies 2 --value="192.168.0.0/16"

# Default phone region (ISO 3166-1 country code)
if [ -n "${DEFAULT_PHONE_REGION}" ]; then
  php occ config:system:set default_phone_region --value="${DEFAULT_PHONE_REGION}"
fi

# Maintenance window start hour (local timezone)
if [ -n "${MAINTENANCE_WINDOW_START}" ]; then
  php occ config:system:set maintenance_window_start --type=integer --value="${MAINTENANCE_WINDOW_START}"
fi

# Generate HTTPS links through the reverse proxy
php occ config:system:set overwriteprotocol --value="https"

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

# Configure Talk STUN/TURN/signaling servers
if [ -n "${TALK_STUN_SERVER}" ]; then
  php occ config:app:set spreed stun_servers --value="[{\"url\":\"${TALK_STUN_SERVER}\"}]"
fi
if [ -n "${TALK_TURN_SERVER}" ] && ! echo "${TALK_TURN_SERVER}" | grep -q "yourdomain.com"; then
  php occ config:app:set spreed turn_servers --value="[{\"url\":\"${TALK_TURN_SERVER}\",\"secret\":\"${TALK_TURN_SECRET}\",\"protocols\":\"${TALK_TURN_PROTOCOLS}\",\"schemes\":\"${TALK_TURN_SCHEMES}\"}]"
fi
if [ -n "${TALK_SIGNALING_URL}" ] && ! echo "${TALK_SIGNALING_URL}" | grep -q "yourdomain.com"; then
  php occ config:app:set spreed signaling_servers --value="{\"servers\":[{\"url\":\"${TALK_SIGNALING_URL}\",\"verify\":true}],\"secret\":\"${TALK_SIGNALING_SECRET}\"}"
fi

# Configure outgoing email server
if [ -n "${SMTP_NAME}" ]; then
  php occ config:system:set mail_smtpmode --value="smtp"
  php occ config:system:set mail_smtphost --value="${SMTP_HOST}"
  php occ config:system:set mail_smtpport --type=integer --value="${SMTP_PORT}"
  php occ config:system:set mail_smtpsecure --value="${SMTP_SECURE}"
  php occ config:system:set mail_smtpauth --type=integer --value="${SMTP_AUTH}"
  php occ config:system:set mail_smtpname --value="${SMTP_NAME}"
  if [ -n "${SMTP_PASSWORD}" ]; then
    php occ config:system:set mail_smtppassword --value="${SMTP_PASSWORD}"
  fi
  if [ -n "${MAIL_FROM_ADDRESS}" ]; then
    php occ config:system:set mail_from_address --value="${MAIL_FROM_ADDRESS}"
  fi
  if [ -n "${MAIL_DOMAIN}" ] && ! echo "${MAIL_DOMAIN}" | grep -q "yourdomain.com"; then
    php occ config:system:set mail_domain --value="${MAIL_DOMAIN}"
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
