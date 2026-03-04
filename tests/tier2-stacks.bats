#!/usr/bin/env bats
# Tier 2: Stack health integration tests. Requires Docker. Local only.
# Each test brings up one stack, verifies health, then tears it down.
# Stub .env files are generated from example.env.

setup() {
	load 'lib/bats-support/load'
	load 'lib/bats-assert/load'
	load 'helpers/common.bash'
	load 'helpers/stack.bash'

	STUB_DIR="$REPO_ROOT/tests/fixtures/stubs"
	mkdir -p "$STUB_DIR"
}

# -- Nextcloud -----------------------------------------------------------------

setup_nextcloud() {
	make_stub_env "$REPO_ROOT/nextcloud/example.env" "$STUB_DIR/nextcloud.env"

	local tmpvol
	tmpvol=$(mktemp -d)
	{
		echo "HOST_LAN_IP=127.0.0.1"
		echo "DOCKER_VOLUME_DIR=$tmpvol"
		echo "NEXTCLOUD_APP_VOLUME=$tmpvol/app"
		echo "NEXTCLOUD_DATA_VOLUME=$tmpvol/data"
		echo "NEXTCLOUD_DB_VOLUME=$tmpvol/db"
		echo "NEXTCLOUD_REDIS_VOLUME=$tmpvol/redis"
		echo "COMPOSE_PROFILES="
	} >>"$STUB_DIR/nextcloud.env"

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
}

@test "nextcloud: all core containers reach healthy status" {
	setup_nextcloud

	stack_up "$REPO_ROOT/nextcloud/docker-compose.yaml" \
		"$STUB_DIR/nextcloud.env" \
		nextcloud_postgres nextcloud_redis nextcloud_app

	run curl -sf http://localhost:8888/status.php
	assert_success
	assert_output --partial '"installed":true'

	teardown_nextcloud
}

# -- Gitea ---------------------------------------------------------------------

setup_gitea() {
	make_stub_env "$REPO_ROOT/gitea/example.env" "$STUB_DIR/gitea.env"
	local tmpvol
	tmpvol=$(mktemp -d)
	{
		echo "HOST_LAN_IP=127.0.0.1"
		echo "GITEA_DATA_VOLUME=$tmpvol/gitea"
		echo "GITEA_DB_VOLUME=$tmpvol/gitea_db"
	} >>"$STUB_DIR/gitea.env"

	mkdir -p "$REPO_ROOT/gitea/secrets"
	echo "test-gitea-pg-pass" >"$REPO_ROOT/gitea/secrets/postgres_password"

	ensure_network "gitea_proxy_network"
}

teardown_gitea() {
	stack_down "$REPO_ROOT/gitea/docker-compose.yaml" "$STUB_DIR/gitea.env"
	remove_network "gitea_proxy_network"
	rm -f "$REPO_ROOT/gitea/secrets/postgres_password"
}

@test "gitea: container reaches healthy status" {
	setup_gitea
	stack_up "$REPO_ROOT/gitea/docker-compose.yaml" \
		"$STUB_DIR/gitea.env" \
		gitea_postgres gitea_app

	run curl -sf http://127.0.0.1:3000/api/healthz
	assert_success

	teardown_gitea
}

# -- Vaultwarden ---------------------------------------------------------------

@test "vaultwarden: container reaches healthy status" {
	make_stub_env "$REPO_ROOT/vaultwarden/example.env" "$STUB_DIR/vaultwarden.env"
	local tmpvol
	tmpvol=$(mktemp -d)
	echo "VAULTWARDEN_DATA_VOLUME=$tmpvol/vw" >>"$STUB_DIR/vaultwarden.env"
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
}

# -- Uptime Kuma ---------------------------------------------------------------

@test "uptime-kuma: container starts without error" {
	make_stub_env "$REPO_ROOT/uptime-kuma/example.env" "$STUB_DIR/uptime-kuma.env"
	local tmpvol
	tmpvol=$(mktemp -d)
	echo "UPTIME_KUMA_DATA_VOLUME=$tmpvol/kuma" >>"$STUB_DIR/uptime-kuma.env"

	ensure_network "uptime_kuma_proxy_network"

	# Uptime Kuma has no healthcheck and no host port mapping; just verify it
	# starts without error (exit code 0 from compose up).
	run docker compose -f "$REPO_ROOT/uptime-kuma/docker-compose.yaml" \
		--env-file "$STUB_DIR/uptime-kuma.env" up -d
	assert_success

	run docker inspect --format='{{.State.Status}}' uptime_kuma
	assert_output "running"

	docker compose -f "$REPO_ROOT/uptime-kuma/docker-compose.yaml" \
		--env-file "$STUB_DIR/uptime-kuma.env" down -v --remove-orphans 2>/dev/null || true
	remove_network "uptime_kuma_proxy_network"
}

# -- Reverse proxy -------------------------------------------------------------

@test "reverse-proxy: nginx-proxy-manager reaches healthy status" {
	make_stub_env "$REPO_ROOT/reverse-proxy/example.env" "$STUB_DIR/reverse-proxy.env"
	local tmpvol
	tmpvol=$(mktemp -d)
	{
		echo "HOST_LAN_IP=127.0.0.1"
		echo "NPM_DATA_VOLUME=$tmpvol/npm"
		echo "NPM_LETSENCRYPT_VOLUME=$tmpvol/letsencrypt"
	} >>"$STUB_DIR/reverse-proxy.env"

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
