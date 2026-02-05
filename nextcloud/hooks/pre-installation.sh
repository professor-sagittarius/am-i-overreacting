#!/bin/bash
# Pre-installation hook - runs before Nextcloud is installed

# Create data directory if it doesn't exist and fix ownership
mkdir -p "${NEXTCLOUD_DATA_DIR:-/var/www/html/data}"
chown -R www-data:www-data "${NEXTCLOUD_DATA_DIR:-/var/www/html/data}"
