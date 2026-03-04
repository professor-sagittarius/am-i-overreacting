# Shared helpers for all test tiers.
# Load with: load 'helpers/common.bash'

REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"

# Wait for a container to reach 'healthy' status.
# Usage: wait_healthy <container_name> [timeout_seconds]
wait_healthy() {
	local container="$1"
	local timeout="${2:-120}"
	local elapsed=0

	while [[ $elapsed -lt $timeout ]]; do
		local status
		status=$(docker inspect --format='{{.State.Health.Status}}' "$container" 2>/dev/null || echo "missing")
		if [[ "$status" == "healthy" ]]; then
			return 0
		fi
		sleep 5
		elapsed=$((elapsed + 5))
	done

	echo "Timed out waiting for $container (status: $status)" >&2
	return 1
}

# Read a value from a .env file.
# Usage: get_env_var KEY path/to/.env
get_env_var() {
	local key="$1" file="$2"
	grep -E "^${key}=" "$file" 2>/dev/null | head -1 | cut -d= -f2- | tr -d '"' || true
}

# Generate a stub .env from an example.env: replaces 'changeme' with 'test-stub-value'
# and fills in empty _VOLUME variables with a stub path (empty volume paths are invalid
# in Docker Compose volume mount specs).
# Does NOT expand variable references - compose handles that itself.
# Usage: make_stub_env src.env dest.env
make_stub_env() {
	local src="$1" dest="$2"
	sed \
		-e 's/=changeme\b/=test-stub-value/g' \
		-e 's/\(_VOLUME\)=$/\1=\/tmp\/test-stub/g' \
		"$src" >"$dest"
}
