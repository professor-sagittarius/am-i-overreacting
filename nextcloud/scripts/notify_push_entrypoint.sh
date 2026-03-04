#!/bin/sh
set -e
ARCH="$(uname -m)"
BINARY="/var/www/html/custom_apps/notify_push/bin/${ARCH}/notify_push"
MAX_WAIT=60

echo "notify_push: waiting for binary at ${BINARY}..."
n=0
until [ -f "${BINARY}" ] || [ "$n" -ge "$MAX_WAIT" ]; do
	sleep 10
	n=$((n + 1))
	echo "notify_push: waited $((n * 10))s..."
done

if [ ! -f "${BINARY}" ]; then
	echo "ERROR: notify_push binary not found after $((MAX_WAIT * 10))s - is notify_push in NEXTCLOUD_APPS?"
	exit 1
fi

echo "notify_push: binary found. Waiting for Nextcloud to be ready..."
until curl -sf -o /dev/null http://nextcloud_app/status.php; do
	sleep 10
done

echo "notify_push: starting..."
exec "${BINARY}" /var/www/html/config/config.php
