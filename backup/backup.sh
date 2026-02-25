#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

# Always disable maintenance mode on exit (success or failure)
trap 'docker exec -u www-data nextcloud_app php occ maintenance:mode --off' EXIT

docker exec -u www-data nextcloud_app php occ maintenance:mode --on

docker compose -f "${SCRIPT_DIR}/docker-compose.yaml" --env-file "${SCRIPT_DIR}/.env" run --rm borgmatic borgmatic
