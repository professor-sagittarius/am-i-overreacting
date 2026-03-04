#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

# Check if Nextcloud is running
if docker inspect --format '{{.State.Running}}' nextcloud_app 2>/dev/null | grep -q true; then
	NC_RUNNING=true
else
	NC_RUNNING=false
fi

if [ "$NC_RUNNING" = true ]; then
	# Disable maintenance mode on exit (success or failure)
	trap 'docker exec -u www-data nextcloud_app php occ maintenance:mode --off 2>/dev/null \
      || echo "WARNING: Failed to disable maintenance mode - check manually"' EXIT
	docker exec -u www-data nextcloud_app php occ maintenance:mode --on
else
	echo "WARNING: nextcloud_app is not running - skipping maintenance mode. Gitea/Vaultwarden will still be backed up."
fi

docker compose -f "${SCRIPT_DIR}/docker-compose.yaml" --env-file "${SCRIPT_DIR}/.env" run --rm borgmatic borgmatic
