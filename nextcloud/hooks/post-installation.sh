#!/bin/bash
# Post-installation hook - runs after Nextcloud is installed

# Helper: check if a profile is enabled in COMPOSE_PROFILES
profile_enabled() { echo ",${COMPOSE_PROFILES:-}," | grep -q ",$1,"; }

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

# Configure Talk STUN/TURN servers (spreed)
if [ -n "${TALK_TURN_SECRET}" ]; then
  # stun_servers is a simple string array: ["host:port"]
  if [ -n "${TALK_STUN_SERVER}" ] && ! echo "${TALK_STUN_SERVER}" | grep -q "yourdomain.com"; then
    php occ config:app:set spreed stun_servers --value="[\"${TALK_STUN_SERVER}\"]"
  fi
  # turn_servers uses "server" key (not "url"): [{"schemes":"...","server":"...","secret":"...","protocols":"..."}]
  if [ -n "${TALK_TURN_SERVER}" ] && ! echo "${TALK_TURN_SERVER}" | grep -q "yourdomain.com"; then
    php occ config:app:set spreed turn_servers --value="[{\"schemes\":\"${TALK_TURN_SCHEMES}\",\"server\":\"${TALK_TURN_SERVER}\",\"secret\":\"${TALK_TURN_SECRET}\",\"protocols\":\"${TALK_TURN_PROTOCOLS}\"}]"
  fi
fi

# Configure Talk signaling server (spreed)
if [ -n "${TALK_SIGNALING_SECRET}" ]; then
  if [ -n "${TALK_SIGNALING_SERVER}" ] && ! echo "${TALK_SIGNALING_SERVER}" | grep -q "yourdomain.com"; then
    php occ config:app:set spreed signaling_servers --value="{\"servers\":[{\"server\":\"${TALK_SIGNALING_SERVER}\",\"verify\":true}],\"secret\":\"${TALK_SIGNALING_SECRET}\"}"
  fi
fi

# Configure Collabora Online (richdocuments)
if [ -n "${COLLABORA_URL}" ] && ! echo "${COLLABORA_URL}" | grep -q "yourdomain.com"; then
  php occ config:app:set richdocuments wopi_url --value="${COLLABORA_URL}"
  if [ -n "${COLLABORA_WOPI_ALLOWLIST}" ]; then
    php occ config:app:set richdocuments wopi_allowlist --value="${COLLABORA_WOPI_ALLOWLIST}"
  fi
fi

# Configure Imaginary for server-side preview generation
if profile_enabled "imaginary"; then
  php occ config:system:set preview_imaginary_url --value="http://nextcloud_imaginary:9000"
  php occ config:system:set enabledPreviewProviders 0 --value="OC\\Preview\\Imaginary"
  php occ config:system:set enabledPreviewProviders 1 --value="OC\\Preview\\ImaginaryPDF"
  php occ config:system:set enabledPreviewProviders 2 --value="OC\\Preview\\Image"
  php occ config:system:set enabledPreviewProviders 3 --value="OC\\Preview\\MarkDown"
  php occ config:system:set enabledPreviewProviders 4 --value="OC\\Preview\\MP3"
  php occ config:system:set enabledPreviewProviders 5 --value="OC\\Preview\\TXT"
  php occ config:system:set enabledPreviewProviders 6 --value="OC\\Preview\\OpenDocument"
  php occ config:system:set enabledPreviewProviders 7 --value="OC\\Preview\\Movie"
  php occ config:system:set enabledPreviewProviders 8 --value="OC\\Preview\\Krita"
fi

# Configure Whiteboard server
if profile_enabled "whiteboard"; then
  php occ config:app:set whiteboard jwt_secret_key --value="${WHITEBOARD_JWT_SECRET}"
  if [ -n "${WHITEBOARD_PUBLIC_URL}" ] && ! echo "${WHITEBOARD_PUBLIC_URL}" | grep -q "yourdomain.com"; then
    php occ config:app:set whiteboard collabBackendUrl --value="${WHITEBOARD_PUBLIC_URL}"
  fi
fi

# Configure Full Text Search (fulltextsearch + elasticsearch)
if profile_enabled "fulltextsearch"; then
  php occ config:app:set fulltextsearch search_platform --value="OCA\\FullTextSearch_Elasticsearch\\Platform\\ElasticSearchPlatform"
  php occ config:app:set fulltextsearch_elasticsearch elastic_host --value="http://nextcloud_elasticsearch:9200"
  php occ config:app:set fulltextsearch_elasticsearch elastic_index --value="nextcloud"
fi

# Configure ClamAV antivirus (files_antivirus) in daemon mode
if profile_enabled "clamav"; then
  php occ config:app:set files_antivirus av_mode --value="daemon"
  php occ config:app:set files_antivirus av_host --value="nextcloud_clamav"
  php occ config:app:set files_antivirus av_port --value="3310"
  php occ config:app:set files_antivirus av_stream_max_length --value="26214400"
  php occ config:app:set files_antivirus av_max_file_size --value="-1"
  php occ config:app:set files_antivirus av_infected_action --value="only_log"
fi

# Register AppAPI deploy daemon (HaRP)
if [ -n "${HP_SHARED_KEY}" ]; then
  php occ app_api:daemon:register harp_proxy_docker "Harp Proxy (Docker)" "docker-install" "http" "nextcloud_harp:8780" "http://nextcloud_app" --net exapps_network --harp --harp_frp_address "nextcloud_harp:8782" --harp_shared_key "${HP_SHARED_KEY}" --set-default
fi

# Add missing database indices
php occ db:add-missing-indices

# Run maintenance repair
php occ maintenance:repair --include-expensive
