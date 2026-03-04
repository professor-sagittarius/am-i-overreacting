#!/usr/bin/env bats
# Tier 1: Static analysis tests. No Docker required. Runs in CI.

setup() {
	load 'lib/bats-support/load'
	load 'lib/bats-assert/load'
	load 'helpers/common.bash'
}

# -- shellcheck ----------------------------------------------------------------

@test "shellcheck: all shell scripts pass at warning severity" {
	run find "$REPO_ROOT" -name "*.sh" \
		-not -path "*/.git/*" \
		-not -path "*/tests/lib/*"

	local scripts=("${lines[@]}")
	[[ ${#scripts[@]} -gt 0 ]] || fail "No shell scripts found"

	run shellcheck -S warning "${scripts[@]}"
	assert_success
}

# -- shfmt ---------------------------------------------------------------------

@test "shfmt: no formatting drift in shell scripts" {
	local unformatted
	unformatted=$(find "$REPO_ROOT" -name "*.sh" \
		-not -path "*/.git/*" \
		-not -path "*/tests/lib/*" \
		| xargs shfmt -l)

	if [[ -n "$unformatted" ]]; then
		echo "Files with formatting drift (run 'shfmt -w' to fix):"
		echo "$unformatted"
		return 1
	fi
}

# -- docker compose config -----------------------------------------------------

# Helper: create a stub .env from example.env and run 'docker compose config'
_validate_compose() {
	local stack_dir="$1"
	local stub_env
	stub_env="$REPO_ROOT/tests/fixtures/stubs/${stack_dir//\//_}.env"
	mkdir -p "$(dirname "$stub_env")"
	make_stub_env "$REPO_ROOT/$stack_dir/example.env" "$stub_env"

	run docker compose \
		-f "$REPO_ROOT/$stack_dir/docker-compose.yaml" \
		--env-file "$stub_env" \
		config --quiet
	assert_success
}

@test "compose config: nextcloud" {
	_validate_compose "nextcloud"
}

@test "compose config: gitea" {
	_validate_compose "gitea"
}

@test "compose config: vaultwarden" {
	_validate_compose "vaultwarden"
}

@test "compose config: uptime-kuma" {
	_validate_compose "uptime-kuma"
}

@test "compose config: reverse-proxy" {
	_validate_compose "reverse-proxy"
}

@test "compose config: backup" {
	_validate_compose "backup"
}

@test "compose config: renovate" {
	_validate_compose "renovate"
}

# -- preflight-check.sh -------------------------------------------------------

@test "preflight-check: passes when no changeme values present" {
	local tmpdir
	tmpdir=$(mktemp -d)
	for stack in nextcloud gitea vaultwarden backup reverse-proxy; do
		mkdir -p "$tmpdir/$stack"
		echo "SOME_VAR=real-value" >"$tmpdir/$stack/.env"
	done

	run bash -c "cd '$tmpdir' && bash '$REPO_ROOT/preflight-check.sh'"
	assert_success
	assert_output --partial "Preflight OK"

	rm -rf "$tmpdir"
}

@test "preflight-check: exits non-zero when changeme placeholder present" {
	local tmpdir
	tmpdir=$(mktemp -d)
	for stack in nextcloud gitea vaultwarden backup reverse-proxy; do
		mkdir -p "$tmpdir/$stack"
		echo "SOME_VAR=real-value" >"$tmpdir/$stack/.env"
	done
	echo "SECRET=changeme" >>"$tmpdir/nextcloud/.env"

	run bash -c "cd '$tmpdir' && bash '$REPO_ROOT/preflight-check.sh'"
	assert_failure
	assert_output --partial "ERROR"

	rm -rf "$tmpdir"
}

# -- generate-passwords.sh ----------------------------------------------------

@test "generate-passwords: creates expected secret files" {
	local tmpdir
	tmpdir=$(mktemp -d)

	for stack in nextcloud gitea vaultwarden backup renovate; do
		mkdir -p "$tmpdir/$stack"
		cp "$REPO_ROOT/$stack/example.env" "$tmpdir/$stack/.env" 2>/dev/null ||
			echo "" >"$tmpdir/$stack/.env"
	done
	for stack in nextcloud gitea vaultwarden backup renovate; do
		sed -i 's/=changeme\b/=already-set/g' "$tmpdir/$stack/.env" 2>/dev/null || true
	done

	run bash -c "cd '$tmpdir' && bash '$REPO_ROOT/generate-passwords.sh'"
	assert_success

	local expected_secrets=(
		"nextcloud/secrets/postgres_password"
		"nextcloud/secrets/admin_password"
		"nextcloud/secrets/redis_password"
		"gitea/secrets/postgres_password"
		"backup/secrets/borg_passphrase"
		"vaultwarden/secrets/admin_token"
	)
	for secret in "${expected_secrets[@]}"; do
		assert [ -f "$tmpdir/$secret" ]
		assert [ -s "$tmpdir/$secret" ]
	done

	rm -rf "$tmpdir"
}

@test "generate-passwords: second run does not crash" {
	local tmpdir
	tmpdir=$(mktemp -d)
	for stack in nextcloud gitea vaultwarden backup renovate; do
		mkdir -p "$tmpdir/$stack"
		cp "$REPO_ROOT/$stack/example.env" "$tmpdir/$stack/.env" 2>/dev/null ||
			echo "" >"$tmpdir/$stack/.env"
	done

	run bash -c "cd '$tmpdir' && bash '$REPO_ROOT/generate-passwords.sh'"
	assert_success
	run bash -c "cd '$tmpdir' && bash '$REPO_ROOT/generate-passwords.sh'"
	assert_success

	rm -rf "$tmpdir"
}
