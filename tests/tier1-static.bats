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
