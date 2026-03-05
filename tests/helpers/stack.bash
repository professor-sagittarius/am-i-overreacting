# Helpers for bringing up and tearing down Docker Compose stacks in tests.
# Load with: load 'helpers/stack.bash'

# Bring up a stack using a test .env file, waiting for all specified containers.
# Usage: stack_up <compose_file> <env_file> <container1> [container2 ...]
stack_up() {
	local compose_file="$1" env_file="$2"
	shift 2
	local containers=("$@")

	docker compose -f "$compose_file" --env-file "$env_file" up -d

	for container in "${containers[@]}"; do
		wait_healthy "$container" 120
	done
}

# Tear down a stack and remove volumes.
# Usage: stack_down <compose_file> <env_file>
stack_down() {
	local compose_file="$1" env_file="$2"
	docker compose -f "$compose_file" --env-file "$env_file" down -v --remove-orphans 2>/dev/null || true
}

# Create a Docker network if it does not exist.
ensure_network() {
	local name="$1"
	docker network inspect "$name" &>/dev/null || docker network create "$name"
}

# Remove a Docker network, ignoring errors.
remove_network() {
	local name="$1"
	docker network rm "$name" 2>/dev/null || true
}

# Wait for an HTTP endpoint to return success.
# Usage: wait_http <url> [timeout_seconds]
wait_http() {
	local url="$1"
	local timeout="${2:-120}"
	local elapsed=0

	while [[ $elapsed -lt $timeout ]]; do
		if curl -sf "$url" &>/dev/null; then
			return 0
		fi
		sleep 5
		elapsed=$((elapsed + 5))
	done

	echo "Timed out waiting for $url" >&2
	return 1
}

# Set ownership of a host directory using a temporary Docker container.
# Avoids requiring sudo on the host.
# Usage: docker_chown <path> <uid:gid>
docker_chown() {
	local path="$1"
	local owner="$2"
	docker run --rm -v "${path}:/target" alpine chown -R "$owner" /target
}

# Remove a directory and its contents using a Docker container.
# Use this when container processes have created files owned by a different uid.
# Usage: docker_rmdir <absolute_path>
docker_rmdir() {
	local path="$1"
	docker run --rm \
		-v "$(dirname "$path"):/parent" \
		alpine \
		rm -rf "/parent/$(basename "$path")"
}
