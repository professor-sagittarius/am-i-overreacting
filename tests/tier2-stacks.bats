#!/usr/bin/env bats
# Tier 2: Stack health integration tests. Requires Docker. Local only.
# Each test brings up one stack, verifies health, then tears it down.
# Stub .env files are generated from example.env.
#
# Volume directories are created at fixed paths under /tmp so teardown can
# reliably remove them. docker_chown sets ownership without requiring sudo.

setup() {
	load 'lib/bats-support/load'
	load 'lib/bats-assert/load'
	load 'helpers/common.bash'
	load 'helpers/stack.bash'

	STUB_DIR="$REPO_ROOT/tests/fixtures/stubs"
	mkdir -p "$STUB_DIR"
}

# -- Nextcloud -----------------------------------------------------------------

_NC_VOL=/tmp/tier2-nextcloud

setup_nextcloud() {
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

	mkdir -p "$REPO_ROOT/nextcloud/secrets"
	echo "test-pg-pass" >"$REPO_ROOT/nextcloud/secrets/postgres_password"
	echo "test-admin-pass" >"$REPO_ROOT/nextcloud/secrets/admin_password"
	echo "test-redis-pass" >"$REPO_ROOT/nextcloud/secrets/redis_password"

	ensure_network "nextcloud_proxy_network"
}

teardown_nextcloud() {
	stack_down "$REPO_ROOT/nextcloud/docker-compose.yaml" "$STUB_DIR/nextcloud.env"
	remove_network "nextcloud_proxy_network"
	rm -f "$REPO_ROOT/nextcloud/secrets/postgres_password" \
		"$REPO_ROOT/nextcloud/secrets/admin_password" \
		"$REPO_ROOT/nextcloud/secrets/redis_password"
	docker_rmdir "${_NC_VOL}"
}

@test "nextcloud: all core containers reach healthy status" {
	setup_nextcloud

	# start_period for nextcloud_app is 600s; allow up to 15 minutes.
	docker compose -f "$REPO_ROOT/nextcloud/docker-compose.yaml" \
		--env-file "$STUB_DIR/nextcloud.env" up -d

	wait_healthy "nextcloud_postgres" 120
	wait_healthy "nextcloud_redis" 120
	wait_healthy "nextcloud_app" 900

	run curl -sf http://localhost:8888/status.php
	assert_success
	assert_output --partial '"installed":true'

	teardown_nextcloud
}

# -- Gitea ---------------------------------------------------------------------

_GITEA_VOL=/tmp/tier2-gitea

setup_gitea() {
	make_stub_env "$REPO_ROOT/gitea/example.env" "$STUB_DIR/gitea.env"
	{
		echo "HOST_LAN_IP=127.0.0.1"
		echo "GITEA_DATA_VOLUME=${_GITEA_VOL}/gitea"
		echo "GITEA_DB_VOLUME=${_GITEA_VOL}/gitea_db"
	} >>"$STUB_DIR/gitea.env"

	mkdir -p "${_GITEA_VOL}"/{gitea,gitea_db}

	mkdir -p "$REPO_ROOT/gitea/secrets"
	echo "test-gitea-pg-pass" >"$REPO_ROOT/gitea/secrets/postgres_password"

	ensure_network "gitea_proxy_network"
}

teardown_gitea() {
	stack_down "$REPO_ROOT/gitea/docker-compose.yaml" "$STUB_DIR/gitea.env"
	remove_network "gitea_proxy_network"
	rm -f "$REPO_ROOT/gitea/secrets/postgres_password"
	docker_rmdir "${_GITEA_VOL}"
}

@test "gitea: container starts and serves HTTP" {
	setup_gitea
	# gitea_app has no Docker healthcheck; wait for postgres then poll HTTP.
	docker compose -f "$REPO_ROOT/gitea/docker-compose.yaml" \
		--env-file "$STUB_DIR/gitea.env" up -d
	wait_healthy "gitea_postgres" 120

	wait_http "http://127.0.0.1:3000/api/healthz" 120

	run curl -sf http://127.0.0.1:3000/api/healthz
	assert_success

	teardown_gitea
}

# -- Vaultwarden ---------------------------------------------------------------

_VW_VOL=/tmp/tier2-vaultwarden

@test "vaultwarden: container reaches healthy status" {
	make_stub_env "$REPO_ROOT/vaultwarden/example.env" "$STUB_DIR/vaultwarden.env"
	echo "VAULTWARDEN_DATA_VOLUME=${_VW_VOL}/data" >>"$STUB_DIR/vaultwarden.env"
	mkdir -p "${_VW_VOL}/data"

	mkdir -p "$REPO_ROOT/vaultwarden/secrets"
	echo "test-vw-token" >"$REPO_ROOT/vaultwarden/secrets/admin_token"

	ensure_network "vaultwarden_proxy_network"

	# Vaultwarden has no host port mapping; verify via Docker healthcheck.
	stack_up "$REPO_ROOT/vaultwarden/docker-compose.yaml" \
		"$STUB_DIR/vaultwarden.env" \
		vaultwarden

	stack_down "$REPO_ROOT/vaultwarden/docker-compose.yaml" "$STUB_DIR/vaultwarden.env"
	remove_network "vaultwarden_proxy_network"
	rm -f "$REPO_ROOT/vaultwarden/secrets/admin_token"
	docker_rmdir "${_VW_VOL}"
}

# -- Uptime Kuma ---------------------------------------------------------------

_KUMA_VOL=/tmp/tier2-uptime-kuma

@test "uptime-kuma: container starts without error" {
	make_stub_env "$REPO_ROOT/uptime-kuma/example.env" "$STUB_DIR/uptime-kuma.env"
	echo "UPTIME_KUMA_DATA_VOLUME=${_KUMA_VOL}/data" >>"$STUB_DIR/uptime-kuma.env"
	mkdir -p "${_KUMA_VOL}/data"

	ensure_network "uptime_kuma_proxy_network"

	# Uptime Kuma has no healthcheck and no host port mapping; just verify
	# compose up exits 0 and the container is running.
	run docker compose -f "$REPO_ROOT/uptime-kuma/docker-compose.yaml" \
		--env-file "$STUB_DIR/uptime-kuma.env" up -d
	assert_success

	run docker inspect --format='{{.State.Status}}' uptime_kuma
	assert_output "running"

	docker compose -f "$REPO_ROOT/uptime-kuma/docker-compose.yaml" \
		--env-file "$STUB_DIR/uptime-kuma.env" down -v --remove-orphans 2>/dev/null || true
	remove_network "uptime_kuma_proxy_network"
	docker_rmdir "${_KUMA_VOL}"
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
	ensure_network "gitea_proxy_network"
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
	remove_network "gitea_proxy_network"
	remove_network "vaultwarden_proxy_network"
	remove_network "uptime_kuma_proxy_network"
	docker_rmdir "${_NPM_VOL}"
}

# -- Backup --------------------------------------------------------------------

@test "backup: borgmatic container starts without error" {
	make_stub_env "$REPO_ROOT/backup/example.env" "$STUB_DIR/backup.env"
	mkdir -p "$REPO_ROOT/backup/secrets"
	echo "test-borg-pass" >"$REPO_ROOT/backup/secrets/borg_passphrase"

	ensure_network "nextcloud_network"
	ensure_network "gitea_network"

	# borgmatic has no healthcheck; just verify it starts.
	run docker compose -f "$REPO_ROOT/backup/docker-compose.yaml" \
		--env-file "$STUB_DIR/backup.env" up -d
	assert_success

	stack_down "$REPO_ROOT/backup/docker-compose.yaml" "$STUB_DIR/backup.env"
	remove_network "nextcloud_network"
	remove_network "gitea_network"
	rm -f "$REPO_ROOT/backup/secrets/borg_passphrase"
}
