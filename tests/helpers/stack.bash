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
