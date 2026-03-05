#!/usr/bin/env bats
# Tier 3: End-to-end migration test. Local only. Takes ~15 minutes.
# Tests the full AIO -> new stack migration path.
#
# Does NOT write to nextcloud/.env or nextcloud/secrets/. All credentials
# are kept in a temporary directory that is removed by teardown.

setup() {
	load 'lib/bats-support/load'
	load 'lib/bats-assert/load'
	load 'helpers/common.bash'
	load 'helpers/stack.bash'

	TMPDIR="$REPO_ROOT/tests/tmp"
	EXPORT_BUNDLE="$TMPDIR/export-bundle"
	SECRETS_DIR="$TMPDIR/secrets"
	ENV_FILE="$REPO_ROOT/tests/fixtures/nextcloud-test.env"

	MOCK_AIO_COMPOSE="$REPO_ROOT/tests/fixtures/mock-aio/docker-compose.yaml"
	NEW_STACK_COMPOSE="$REPO_ROOT/nextcloud/docker-compose.yaml"
}

teardown() {
	docker compose -f "$MOCK_AIO_COMPOSE" down -v --remove-orphans 2>/dev/null || true
	docker compose -f "$NEW_STACK_COMPOSE" --env-file "$ENV_FILE" \
		down -v --remove-orphans 2>/dev/null || true
	remove_network "nextcloud_proxy_network"

	# Volume directories may be owned by container users
	docker_rmdir "/tmp/nc-test-volumes" 2>/dev/null || true

	# Temp directory holds export bundle and test secrets - safe to remove
	rm -rf "$TMPDIR"
}

@test "migration: AIO to new stack - full end-to-end" {
	# ── Step 1: Start mock AIO ────────────────────────────────────────────────
	docker compose -f "$MOCK_AIO_COMPOSE" up -d
	# Healthcheck requires installed:true; allow up to 20 minutes.
	wait_healthy "nextcloud-aio-nextcloud" 1200

	# ── Step 2: Seed test user ────────────────────────────────────────────────
	docker exec \
		-e OC_PASS="migration-user-pass" \
		-u www-data nextcloud-aio-nextcloud \
		php occ user:add --password-from-env testmigration

	docker exec -u www-data nextcloud-aio-nextcloud \
		php occ files:scan testmigration 2>/dev/null || true

	# ── Step 3: Export ────────────────────────────────────────────────────────
	mkdir -p "$TMPDIR"
	run bash "$REPO_ROOT/nextcloud/migrate/export.sh" \
		--output-dir "$EXPORT_BUNDLE" \
		--container nextcloud-aio-nextcloud
	assert_success

	assert [ -f "$EXPORT_BUNDLE/manifest.json" ]
	assert [ -f "$EXPORT_BUNDLE/db-dump.pgdump" ]

	run jq -r '.instanceid' "$EXPORT_BUNDLE/manifest.json"
	assert_success
	assert [ -n "$output" ]

	# ── Step 4: Set up new stack ──────────────────────────────────────────────
	# Credentials go in a temp dir - never touches nextcloud/secrets/ or nextcloud/.env
	mkdir -p "$SECRETS_DIR"
	echo "new-pg-pass-test" >"$SECRETS_DIR/postgres_password"
	echo "new-admin-pass-test" >"$SECRETS_DIR/admin_password"
	echo "new-redis-pass-test" >"$SECRETS_DIR/redis_password"

	ensure_network "nextcloud_proxy_network"

	mkdir -p /tmp/nc-test-volumes/{app,data,db,redis,harp_certs,clamav_db,elasticsearch}
	docker_chown "/tmp/nc-test-volumes/app" "33:33"
	docker_chown "/tmp/nc-test-volumes/data" "33:33"

	# ── Step 5: Start new stack and wait for it to initialize ─────────────────
	# start_period for nextcloud_app is 600s; allow up to 15 minutes.
	docker compose -f "$NEW_STACK_COMPOSE" --env-file "$ENV_FILE" up -d
	wait_healthy "nextcloud_postgres" 120
	wait_healthy "nextcloud_redis" 120
	wait_healthy "nextcloud_app" 900

	# ── Step 6: Run import ────────────────────────────────────────────────────
	run bash -c "cd '$REPO_ROOT' && bash nextcloud/migrate/import.sh \
		--export-dir '$EXPORT_BUNDLE' \
		--env-file '$ENV_FILE' \
		--secrets-dir '$SECRETS_DIR' \
		--non-interactive"
	assert_success

	# ── Step 7: Verify ────────────────────────────────────────────────────────

	# Wait for app to be responsive after restart by import
	local waited=0
	while [[ $waited -lt 120 ]]; do
		if docker exec -u www-data nextcloud_app php occ status &>/dev/null; then
			break
		fi
		sleep 5
		waited=$((waited + 5))
	done

	# Migrated user exists
	run docker exec -u www-data nextcloud_app \
		php occ user:info testmigration
	assert_success
	assert_output --partial "testmigration"

	# Nextcloud is installed and not in maintenance mode
	run docker exec -u www-data nextcloud_app \
		php occ status --output=json
	assert_success
	assert_output --partial '"installed":true'
	refute_output --partial '"maintenance":true'
}
