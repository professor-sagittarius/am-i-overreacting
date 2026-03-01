#!/bin/bash
# Before-startup hook - runs on every container startup before Apache starts.
# Re-applies all .env-driven configuration, making it possible to add or remove
# optional profiles (COMPOSE_PROFILES) without manual occ commands.
#
# On first startup this runs after post-installation.sh; all operations here
# are idempotent so overlap with post-installation.sh is harmless.
set -euo pipefail

# Helper: check if a profile is enabled in COMPOSE_PROFILES
profile_enabled() { echo ",${COMPOSE_PROFILES:-}," | grep -q ",$1,"; }

# ── System config ─────────────────────────────────────────────────────────────

if [ -n "${DEFAULT_PHONE_REGION:-}" ]; then
  php occ config:system:set default_phone_region --value="${DEFAULT_PHONE_REGION}"
fi

if [ -n "${MAINTENANCE_WINDOW_START:-}" ]; then
  php occ config:system:set maintenance_window_start --type=integer --value="${MAINTENANCE_WINDOW_START}"
fi

# Set CLI URL to primary domain - re-applied on every startup so that updating
# NEXTCLOUD_PRIMARY_DOMAIN in .env and restarting is sufficient to change it.
if [ -n "${NEXTCLOUD_PRIMARY_DOMAIN:-}" ] && \
   ! echo "${NEXTCLOUD_PRIMARY_DOMAIN}" | grep -q "yourdomain.com"; then
  php occ config:system:set overwrite.cli.url --value="https://${NEXTCLOUD_PRIMARY_DOMAIN}"
fi

# Trusted domains - re-applied on every startup so that updating
# NEXTCLOUD_TRUSTED_DOMAINS in .env and restarting is sufficient to change them.
# Deletes first to remove any stale entries left over from a previous larger list.
if [ -n "${NEXTCLOUD_TRUSTED_DOMAINS:-}" ]; then
  php occ config:system:delete trusted_domains 2>/dev/null || true
  i=0
  for domain in ${NEXTCLOUD_TRUSTED_DOMAINS}; do
    php occ config:system:set trusted_domains $i --value="$domain"
    i=$((i + 1))
  done
fi

# Trusted proxies - re-applied on every startup so that updating TRUSTED_PROXIES
# in .env and restarting is sufficient to change them.
if [ -n "${TRUSTED_PROXIES:-}" ]; then
  php occ config:system:delete trusted_proxies 2>/dev/null || true
  i=0
  for proxy in ${TRUSTED_PROXIES}; do
    php occ config:system:set trusted_proxies $i --value="$proxy"
    i=$((i + 1))
  done
fi

# ── App management ────────────────────────────────────────────────────────────
# Install apps that are not yet installed; enable apps that are installed but
# disabled. Idempotent: enable on an already-enabled app is a no-op.

FAILED_APPS=()
for app in ${NEXTCLOUD_APPS:-}; do
  if ! php occ app:enable "$app" 2>&1; then
    php occ app:install "$app" 2>&1 || { echo "Warning: could not install/enable ${app}"; FAILED_APPS+=("$app"); }
  fi
done
if [ "${#FAILED_APPS[@]}" -gt 0 ]; then
  echo "Warning: some apps could not be installed or enabled: ${FAILED_APPS[*]}" >&2
fi

# ── Talk STUN/TURN servers ────────────────────────────────────────────────────
if [ -n "${TALK_TURN_SECRET:-}" ]; then
  if [ -n "${TALK_STUN_SERVER:-}" ] && ! echo "${TALK_STUN_SERVER}" | grep -q "yourdomain.com"; then
    php occ config:app:set spreed stun_servers --value="[\"${TALK_STUN_SERVER}\"]"
  fi
  if [ -n "${TALK_TURN_SERVER:-}" ] && ! echo "${TALK_TURN_SERVER}" | grep -q "yourdomain.com"; then
    php occ config:app:set spreed turn_servers \
      --value="[{\"schemes\":\"${TALK_TURN_SCHEMES}\",\"server\":\"${TALK_TURN_SERVER}\",\"secret\":\"${TALK_TURN_SECRET}\",\"protocols\":\"${TALK_TURN_PROTOCOLS}\"}]"
  fi
fi

# ── Talk signaling server ─────────────────────────────────────────────────────
if [ -n "${TALK_SIGNALING_SECRET:-}" ]; then
  if [ -n "${TALK_SIGNALING_SERVER:-}" ] && ! echo "${TALK_SIGNALING_SERVER}" | grep -q "yourdomain.com"; then
    php occ config:app:set spreed signaling_servers \
      --value="{\"servers\":[{\"server\":\"${TALK_SIGNALING_SERVER}\",\"verify\":true}],\"secret\":\"${TALK_SIGNALING_SECRET}\"}"
  fi
fi

# ── Collabora Online ──────────────────────────────────────────────────────────
if [ -n "${COLLABORA_URL:-}" ] && ! echo "${COLLABORA_URL}" | grep -q "yourdomain.com"; then
  php occ config:app:set richdocuments wopi_url --value="${COLLABORA_URL}"
  if [ -n "${COLLABORA_WOPI_ALLOWLIST:-}" ]; then
    php occ config:app:set richdocuments wopi_allowlist --value="${COLLABORA_WOPI_ALLOWLIST}"
  fi
fi

# ── Profile: imaginary ────────────────────────────────────────────────────────
if profile_enabled "imaginary"; then
  php occ config:system:set preview_imaginary_url --value="http://nextcloud_imaginary:9000"
  php occ config:system:delete enabledPreviewProviders 2>/dev/null || true
  php occ config:system:set enabledPreviewProviders 0 --value="OC\\Preview\\Imaginary"
  php occ config:system:set enabledPreviewProviders 1 --value="OC\\Preview\\ImaginaryPDF"
  php occ config:system:set enabledPreviewProviders 2 --value="OC\\Preview\\Image"
  php occ config:system:set enabledPreviewProviders 3 --value="OC\\Preview\\MarkDown"
  php occ config:system:set enabledPreviewProviders 4 --value="OC\\Preview\\MP3"
  php occ config:system:set enabledPreviewProviders 5 --value="OC\\Preview\\TXT"
  php occ config:system:set enabledPreviewProviders 6 --value="OC\\Preview\\OpenDocument"
  php occ config:system:set enabledPreviewProviders 7 --value="OC\\Preview\\Movie"
  php occ config:system:set enabledPreviewProviders 8 --value="OC\\Preview\\Krita"
else
  # Remove imaginary-specific config so Nextcloud uses its built-in preview providers
  php occ config:system:delete preview_imaginary_url 2>/dev/null || true
  php occ config:system:delete enabledPreviewProviders 2>/dev/null || true
fi

# ── Profile: whiteboard ───────────────────────────────────────────────────────
if profile_enabled "whiteboard"; then
  php occ app:enable whiteboard 2>/dev/null || true
  php occ config:app:set whiteboard jwt_secret_key --value="${WHITEBOARD_JWT_SECRET:-}"
  if [ -n "${WHITEBOARD_PUBLIC_URL:-}" ] && ! echo "${WHITEBOARD_PUBLIC_URL}" | grep -q "yourdomain.com"; then
    php occ config:app:set whiteboard collabBackendUrl --value="${WHITEBOARD_PUBLIC_URL}"
  fi
else
  php occ app:disable whiteboard 2>/dev/null || true
fi

# ── Profile: fulltextsearch ───────────────────────────────────────────────────
if profile_enabled "fulltextsearch"; then
  php occ app:enable fulltextsearch fulltextsearch_elasticsearch files_fulltextsearch 2>/dev/null || true
  php occ config:app:set fulltextsearch search_platform \
    --value="OCA\\FullTextSearch_Elasticsearch\\Platform\\ElasticSearchPlatform"
  php occ config:app:set fulltextsearch_elasticsearch elastic_host \
    --value="http://nextcloud_elasticsearch:9200"
  php occ config:app:set fulltextsearch_elasticsearch elastic_index --value="nextcloud"
else
  php occ app:disable fulltextsearch fulltextsearch_elasticsearch files_fulltextsearch 2>/dev/null || true
fi

# ── Profile: clamav ───────────────────────────────────────────────────────────
if profile_enabled "clamav"; then
  php occ app:enable files_antivirus 2>/dev/null || true
  php occ config:app:set files_antivirus av_mode --value="daemon"
  php occ config:app:set files_antivirus av_host --value="nextcloud_clamav"
  php occ config:app:set files_antivirus av_port --value="3310"
  php occ config:app:set files_antivirus av_stream_max_length --value="26214400"
  php occ config:app:set files_antivirus av_max_file_size --value="-1"
  # av_infected_action is "only_log": infected files are flagged in logs but not deleted.
  # This avoids disruption from ClamAV false positives. To auto-delete infected files,
  # change to "delete". Monitor Nextcloud logs for antivirus alerts.
  php occ config:app:set files_antivirus av_infected_action --value="only_log"
else
  php occ app:disable files_antivirus 2>/dev/null || true
fi

# ── Profile: harp ─────────────────────────────────────────────────────────────
if profile_enabled "harp" && [ -n "${HP_SHARED_KEY:-}" ]; then
  # app_api:daemon:register is idempotent when the daemon name already exists
  php occ app_api:daemon:register harp_proxy_docker "Harp Proxy (Docker)" \
    "docker-install" "http" "nextcloud_harp:8780" "http://nextcloud_app" \
    --net exapps_network --harp \
    --harp_frp_address "nextcloud_harp:8782" \
    --harp_shared_key "${HP_SHARED_KEY}" \
    --set-default 2>/dev/null || true
fi

# ── Background job scheduler ──────────────────────────────────────────────────
# Ensures system cron is always configured even after container recreation.
php occ background:cron

# ── Database integrity ────────────────────────────────────────────────────────
# Idempotent; catches gaps introduced by Nextcloud upgrades automatically.
php occ db:add-missing-indices
php occ db:add-missing-columns
