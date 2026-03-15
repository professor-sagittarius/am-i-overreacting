#!/usr/bin/env bats
# Tier 2: Stack health integration tests. Requires Docker. Local only.
# Each test brings up one stack, verifies health, then tears it down.
# Stub .env files are generated from example.env.
#
# Volume directories are created at fixed paths under /tmp so teardown can
# reliably remove them. docker_chown sets ownership without requiring sudo.
#
# Test secrets are written inside each stack's /tmp volume directory.
# Docker Compose's --project-directory flag makes relative secret paths
# (./secrets/...) in compose files resolve there, so production secret
# files are never read or written.

setup() {
	load 'lib/bats-support/load'
	load 'lib/bats-assert/load'
	load 'helpers/common.bash'
	load 'helpers/stack.bash'

	STUB_DIR="$REPO_ROOT/tests/fixtures/stubs"
	mkdir -p "$STUB_DIR"
}

# Timeout constants with rationale
# Nextcloud app has start_period of 600s in healthcheck
# Allow 50% buffer for CI variability
readonly NC_APP_TIMEOUT=900
# PostgreSQL and Redis have shorter start periods (30s default)
readonly DEPENDENCY_TIMEOUT=120

# -- Nextcloud -----------------------------------------------------------------

_NC_VOL=/tmp/tier2-nextcloud

setup_nextcloud() {
	# Remove any leftover containers from previous failed runs (teardown not called on failure)
	docker rm -f nextcloud_app nextcloud_postgres nextcloud_redis nextcloud_notify_push \
		nextcloud_imaginary nextcloud_whiteboard nextcloud_elasticsearch \
		nextcloud_clamav nextcloud_harp 2>/dev/null || true
	docker_rmdir "${_NC_VOL}" 2>/dev/null || true

	make_stub_env "$REPO_ROOT/nextcloud/example.env" "$STUB_DIR/nextcloud.env"

	# Override all volume paths explicitly (Docker Compose resolves
	# ${DOCKER_VOLUME_DIR}/... references at .env load time using the first
	# definition, so appending DOCKER_VOLUME_DIR alone is insufficient).
	{
		echo "HOST_LAN_IP=127.0.0.1"
		echo "NEXTCLOUD_APP_VOLUME=${_NC_VOL}/app"
		echo "NEXTCLOUD_DATA_VOLUME=${_NC_VOL}/data"
		echo "NEXTCLOUD_DB_VOLUME=${_NC_VOL}/db"
		echo "NEXTCLOUD_REDIS_VOLUME=${_NC_VOL}/redis"
		echo "HARP_CERTS_VOLUME=${_NC_VOL}/harp_certs"
		echo "CLAMAV_DB_VOLUME=${_NC_VOL}/clamav_db"
		echo "ELASTICSEARCH_DATA_VOLUME=${_NC_VOL}/elasticsearch"
	} >>"$STUB_DIR/nextcloud.env"

	# Create volume directories; chown app and data to www-data (uid 33).
	mkdir -p "${_NC_VOL}"/{app,data,db,redis,harp_certs,clamav_db,elasticsearch}
	docker_chown "${_NC_VOL}/app" "33:33"
	docker_chown "${_NC_VOL}/data" "33:33"

	# Secrets go in the temp vol dir. --project-directory below makes Docker
	# Compose resolve ./secrets/... relative to _NC_VOL, not nextcloud/.
	mkdir -p "${_NC_VOL}/secrets"
	echo "test-pg-pass" >"${_NC_VOL}/secrets/postgres_password"
	echo "test-admin-pass" >"${_NC_VOL}/secrets/admin_password"
	echo "test-redis-pass" >"${_NC_VOL}/secrets/redis_password"

	# Copy scripts directory for bind mounts (notify_push_entrypoint.sh)
	cp -r "${REPO_ROOT}/nextcloud/scripts" "${_NC_VOL}/"

	ensure_network "nextcloud_proxy_network"
}

teardown_nextcloud() {
	docker compose -f "$REPO_ROOT/nextcloud/docker-compose.yaml" \
		--project-directory "${_NC_VOL}" \
		--env-file "$STUB_DIR/nextcloud.env" \
		down -v --remove-orphans 2>/dev/null || true
	remove_network "nextcloud_proxy_network"
	docker_rmdir "${_NC_VOL}"
}

@test "nextcloud: all core containers reach healthy status" {
	setup_nextcloud

	# start_period for nextcloud_app is 600s; allow up to 15 minutes.
	docker compose -f "$REPO_ROOT/nextcloud/docker-compose.yaml" \
		--project-directory "${_NC_VOL}" \
		--env-file "$STUB_DIR/nextcloud.env" up -d

	wait_healthy "nextcloud_postgres" "$DEPENDENCY_TIMEOUT"
	wait_healthy "nextcloud_redis" "$DEPENDENCY_TIMEOUT"
	wait_healthy "nextcloud_app" "$NC_APP_TIMEOUT"

	run curl -sf http://localhost:8888/status.php
	assert_success
	assert_output --partial '"installed":true'

	teardown_nextcloud
}

# -- Forgejo -------------------------------------------------------------------

_FORGEJO_VOL=/tmp/tier2-forgejo

setup_forgejo() {
	make_stub_env "$REPO_ROOT/forgejo/example.env" "$STUB_DIR/forgejo.env"
	{
		echo "HOST_LAN_IP=127.0.0.1"
		echo "FORGEJO_DATA_VOLUME=${_FORGEJO_VOL}/forgejo"
		echo "FORGEJO_DB_VOLUME=${_FORGEJO_VOL}/forgejo_db"
	} >>"$STUB_DIR/forgejo.env"

	mkdir -p "${_FORGEJO_VOL}"/{forgejo,forgejo_db}

	mkdir -p "${_FORGEJO_VOL}/secrets"
	echo "test-forgejo-pg-pass" >"${_FORGEJO_VOL}/secrets/postgres_password"

	ensure_network "forgejo_proxy_network"
}

teardown_forgejo() {
	docker compose -f "$REPO_ROOT/forgejo/docker-compose.yaml" \
		--project-directory "${_FORGEJO_VOL}" \
		--env-file "$STUB_DIR/forgejo.env" \
		down -v --remove-orphans 2>/dev/null || true
	remove_network "forgejo_proxy_network"
	docker_rmdir "${_FORGEJO_VOL}"
}

@test "forgejo: container starts and serves HTTP" {
	setup_forgejo
	# forgejo_app has a Docker healthcheck; wait for postgres then poll HTTP.
	docker compose -f "$REPO_ROOT/forgejo/docker-compose.yaml" \
		--project-directory "${_FORGEJO_VOL}" \
		--env-file "$STUB_DIR/forgejo.env" up -d
	wait_healthy "forgejo_postgres" 120

	wait_http "http://127.0.0.1:3000/api/healthz" 120

	run curl -sf http://127.0.0.1:3000/api/healthz
	assert_success

	teardown_forgejo
}

# -- Vaultwarden ---------------------------------------------------------------

_VW_VOL=/tmp/tier2-vaultwarden

@test "vaultwarden: container reaches healthy status" {
	make_stub_env "$REPO_ROOT/vaultwarden/example.env" "$STUB_DIR/vaultwarden.env"
	echo "VAULTWARDEN_DATA_VOLUME=${_VW_VOL}/data" >>"$STUB_DIR/vaultwarden.env"
	mkdir -p "${_VW_VOL}/data"

	mkdir -p "${_VW_VOL}/secrets"
	echo "test-vw-token" >"${_VW_VOL}/secrets/admin_token"

	ensure_network "vaultwarden_proxy_network"

	# Vaultwarden has no host port mapping; verify via Docker healthcheck.
	docker compose -f "$REPO_ROOT/vaultwarden/docker-compose.yaml" \
		--project-directory "${_VW_VOL}" \
		--env-file "$STUB_DIR/vaultwarden.env" up -d
	wait_healthy "vaultwarden" 120

	docker compose -f "$REPO_ROOT/vaultwarden/docker-compose.yaml" \
		--project-directory "${_VW_VOL}" \
		--env-file "$STUB_DIR/vaultwarden.env" \
		down -v --remove-orphans 2>/dev/null || true
	remove_network "vaultwarden_proxy_network"
	docker_rmdir "${_VW_VOL}"
}

# -- Uptime Kuma ---------------------------------------------------------------

_KUMA_VOL=/tmp/tier2-uptime-kuma

setup_uptime_kuma() {
	make_stub_env "$REPO_ROOT/uptime-kuma/example.env" "$STUB_DIR/uptime-kuma.env"
	echo "UPTIME_KUMA_DATA_VOLUME=${_KUMA_VOL}/data" >>"$STUB_DIR/uptime-kuma.env"
	mkdir -p "${_KUMA_VOL}/data"

	ensure_network "uptime_kuma_proxy_network"
}

teardown_uptime_kuma() {
	docker compose -f "$REPO_ROOT/uptime-kuma/docker-compose.yaml" \
		--env-file "$STUB_DIR/uptime-kuma.env" down -v --remove-orphans 2>/dev/null || true
	remove_network "uptime_kuma_proxy_network"
	docker_rmdir "${_KUMA_VOL}"
}

@test "uptime-kuma: container starts without error" {
	setup_uptime_kuma

	# Uptime Kuma has no healthcheck and no host port mapping; just verify
	# compose up exits 0 and the container is running.
	run docker compose -f "$REPO_ROOT/uptime-kuma/docker-compose.yaml" \
		--env-file "$STUB_DIR/uptime-kuma.env" up -d
	assert_success

	run docker inspect --format='{{.State.Status}}' uptime_kuma
	assert_output "running"

	teardown_uptime_kuma
}

# -- Reverse proxy -------------------------------------------------------------

_NPM_VOL=/tmp/tier2-reverse-proxy

@test "reverse-proxy: nginx-proxy-manager starts without error" {
	make_stub_env "$REPO_ROOT/reverse-proxy/example.env" "$STUB_DIR/reverse-proxy.env"
	{
		echo "HOST_LAN_IP=127.0.0.1"
		echo "NPM_DATA_VOLUME=${_NPM_VOL}/npm"
		echo "NPM_LETSENCRYPT_VOLUME=${_NPM_VOL}/letsencrypt"
	} >>"$STUB_DIR/reverse-proxy.env"
	mkdir -p "${_NPM_VOL}"/{npm,letsencrypt}

	ensure_network "nextcloud_proxy_network"
	ensure_network "forgejo_proxy_network"
	ensure_network "vaultwarden_proxy_network"
	ensure_network "uptime_kuma_proxy_network"

	# NPM has no Docker healthcheck; just verify the container starts.
	run docker compose -f "$REPO_ROOT/reverse-proxy/docker-compose.yaml" \
		--env-file "$STUB_DIR/reverse-proxy.env" up -d nginx-proxy-manager
	assert_success

	run docker inspect --format='{{.State.Status}}' nginx-proxy-manager
	assert_output "running"

	docker compose -f "$REPO_ROOT/reverse-proxy/docker-compose.yaml" \
		--env-file "$STUB_DIR/reverse-proxy.env" down -v --remove-orphans 2>/dev/null || true
	remove_network "nextcloud_proxy_network"
	remove_network "forgejo_proxy_network"
	remove_network "vaultwarden_proxy_network"
	remove_network "uptime_kuma_proxy_network"
	docker_rmdir "${_NPM_VOL}"
}

# -- Backup --------------------------------------------------------------------

_BACKUP_VOL=/tmp/tier2-backup

@test "backup: borgmatic container starts without error" {
	make_stub_env "$REPO_ROOT/backup/example.env" "$STUB_DIR/backup.env"

	mkdir -p "${_BACKUP_VOL}/secrets"
	echo "test-borg-pass" >"${_BACKUP_VOL}/secrets/borg_passphrase"

	ensure_network "nextcloud_network"
	ensure_network "forgejo_network"

	# borgmatic has no healthcheck; just verify it starts.
	run docker compose -f "$REPO_ROOT/backup/docker-compose.yaml" \
		--project-directory "${_BACKUP_VOL}" \
		--env-file "$STUB_DIR/backup.env" up -d
	assert_success

	docker compose -f "$REPO_ROOT/backup/docker-compose.yaml" \
		--project-directory "${_BACKUP_VOL}" \
		--env-file "$STUB_DIR/backup.env" \
		down -v --remove-orphans 2>/dev/null || true
	remove_network "nextcloud_network"
	remove_network "forgejo_network"
	docker_rmdir "${_BACKUP_VOL}"
}
