#!/usr/bin/env bash
# import.sh - Run on the NEW HOST to import Nextcloud data
# Usage: bash nextcloud/migrate/import.sh [--dry-run] [-v|--verbose]
# Must be run from the repository root directory.
set -euo pipefail

# ── Colors ────────────────────────────────────────────────────────────────────
RED='\033[0;31m'
YELLOW='\033[1;33m'
GREEN='\033[0;32m'
BOLD='\033[1m'
NC='\033[0m'

# ── Output helpers ────────────────────────────────────────────────────────────
info() { echo -e "${BOLD}[INFO]${NC}  $*"; }
success() { echo -e "${GREEN}[OK]${NC}    $*"; }
warn() { echo -e "${YELLOW}[WARN]${NC}  $*"; }
error() { echo -e "${RED}[ERROR]${NC} $*" >&2; }
step() { echo -e "\n${BOLD}━━━ $* ━━━${NC}"; }
verbose() { if [[ "$VERBOSE" == true ]]; then echo -e "  [verbose] $*"; fi; }

# ── Flags ─────────────────────────────────────────────────────────────────────
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DRY_RUN=false
VERBOSE=false
NON_INTERACTIVE=false
EXPORT_DIR=""
REMOVED_APPS=()
ENV_FILE="nextcloud/.env"
SECRETS_DIR="nextcloud/secrets"
COMPOSE_FILE="nextcloud/docker-compose.yaml"

# ── Argument parsing ──────────────────────────────────────────────────────────
usage() {
	cat <<EOF
Usage: bash nextcloud/migrate/import.sh [OPTIONS]

Run on the NEW HOST from the repository root directory.

Options:
  --dry-run           Preview actions without executing
  -v, --verbose       Show detailed output
  --export-dir DIR    Location of export bundle (default: most recent bundle in nextcloud/migrate/bundles/)
  --non-interactive   Skip interactive prompts (answers 'n' to all)
  --env-file FILE     Path to the stack .env file (default: nextcloud/.env)
  --secrets-dir DIR   Directory containing postgres_password and admin_password (default: nextcloud/secrets)
  --compose-file FILE Path to the stack docker-compose.yaml (default: nextcloud/docker-compose.yaml)
  -h, --help          Show this help

EOF
}

while [[ $# -gt 0 ]]; do
	case $1 in
	--dry-run) DRY_RUN=true ;;
	-v | --verbose) VERBOSE=true ;;
	--non-interactive) NON_INTERACTIVE=true ;;
	--export-dir)
		EXPORT_DIR="$2"
		shift
		;;
	--env-file)
		ENV_FILE="$2"
		shift
		;;
	--secrets-dir)
		SECRETS_DIR="$2"
		shift
		;;
	--compose-file)
		COMPOSE_FILE="$2"
		shift
		;;
	-h | --help)
		usage
		exit 0
		;;
	*)
		error "Unknown option: $1"
		usage
		exit 1
		;;
	esac
	shift
done

# ── Dry-run wrapper ───────────────────────────────────────────────────────────
runcmd() {
	if [[ "$DRY_RUN" == true ]]; then
		echo -e "  ${YELLOW}[dry-run]${NC} $*"
	else
		"$@"
	fi
}

# ── .env parser ───────────────────────────────────────────────────────────────
get_env_var() {
	local key="$1" file="${2:-$ENV_FILE}"
	grep -E "^${key}=" "$file" 2>/dev/null | head -1 | cut -d= -f2- | tr -d '"' || true
}

# ── Manifest ──────────────────────────────────────────────────────────────────
MANIFEST=""
M_INSTANCE_ID=""
M_PASSWORD_SALT=""
M_SECRET=""
M_DATA_FINGERPRINT=""
M_DB_TYPE=""
M_VERSION=""
M_DB_HOST=""
M_DB_NAME=""
M_DB_USER=""
M_DATA_DIRECTORY=""

read_manifest() {
	MANIFEST="$EXPORT_DIR/manifest.json"
	if [[ ! -f "$MANIFEST" ]]; then
		error "Export manifest not found: $MANIFEST"
		error "Run export.sh on the OLD HOST first, then transfer the export bundle here."
		exit 1
	fi

	M_INSTANCE_ID=$(jq -r '.instanceid' "$MANIFEST")
	M_PASSWORD_SALT=$(jq -r '.passwordsalt' "$MANIFEST")
	M_SECRET=$(jq -r '.secret' "$MANIFEST")
	M_DATA_FINGERPRINT=$(jq -r '.data_fingerprint // ""' "$MANIFEST")
	M_DB_TYPE=$(jq -r '.dbtype' "$MANIFEST")
	M_VERSION=$(jq -r '.version' "$MANIFEST")
	M_DB_HOST=$(jq -r '.dbhost // ""' "$MANIFEST")
	M_DB_NAME=$(jq -r '.dbname // ""' "$MANIFEST")
	M_DB_USER=$(jq -r '.dbuser // ""' "$MANIFEST")
	M_DATA_DIRECTORY=$(jq -r '.datadirectory // ""' "$MANIFEST")

	verbose "Manifest loaded: $MANIFEST"
	verbose "  instanceid:    $M_INSTANCE_ID"
	verbose "  version:       $M_VERSION"
	verbose "  dbtype:        $M_DB_TYPE"
	verbose "  datadirectory: $M_DATA_DIRECTORY"
}

# ── Prerequisites ─────────────────────────────────────────────────────────────
check_prerequisites() {
	step "Checking prerequisites (NEW HOST)"

	if [[ ! -f "$COMPOSE_FILE" ]]; then
		error "This script must be run from the repository root directory."
		error "Example: bash nextcloud/migrate/import.sh"
		exit 1
	fi

	local missing=()
	command -v jq &>/dev/null || missing+=("jq")
	command -v docker &>/dev/null || missing+=("docker")

	if [[ "${#missing[@]}" -gt 0 ]]; then
		error "Missing required tools: ${missing[*]}"
		error "Install with: apt-get install ${missing[*]}"
		exit 1
	fi

	if ! docker compose -f "$COMPOSE_FILE" --env-file "$ENV_FILE" ps --quiet nextcloud_postgres 2>/dev/null | grep -q .; then
		error "nextcloud_postgres is not running. Start the stack first:"
		error "  docker compose -f $COMPOSE_FILE up -d"
		error "Verify the fresh install works (log in with the generated admin password),"
		error "then re-run this script."
		exit 1
	fi

	if [[ ! -f "$SECRETS_DIR/postgres_password" ]]; then
		error "$SECRETS_DIR/postgres_password not found."
		error "Run generate-passwords.sh and complete the initial stack setup first."
		exit 1
	fi

	if [[ ! -f "$SECRETS_DIR/admin_password" ]]; then
		error "$SECRETS_DIR/admin_password not found."
		error "Run generate-passwords.sh and complete the initial stack setup first."
		exit 1
	fi

	success "All prerequisites met"
}

# ── Version check ─────────────────────────────────────────────────────────────
check_version() {
	step "Checking Nextcloud version compatibility (NEW HOST)"

	local new_version
	new_version=$(docker exec nextcloud_app php occ status --output=json 2>/dev/null |
		jq -r '.versionstring' || true)

	if [[ -z "$new_version" ]]; then
		error "Could not read version from nextcloud_app."
		error "Ensure nextcloud_app is running and healthy before importing:"
		error "  docker compose -f $COMPOSE_FILE logs nextcloud_app"
		exit 1
	fi

	verbose "Old version: $M_VERSION"
	verbose "New version: $new_version"

	# Compare only x.y.z - Nextcloud uses x.y.z.p internally but the Docker
	# image tag and upgrade path only care about the first three components.
	local old_xyz new_xyz
	old_xyz=$(echo "$M_VERSION" | cut -d. -f1-3)
	new_xyz=$(echo "$new_version" | cut -d. -f1-3)

	if [[ "$old_xyz" != "$new_xyz" ]]; then
		echo ""
		error "╔══════════════════════════════════════════════════════════════════╗"
		error "║              VERSION MISMATCH - CANNOT PROCEED                  ║"
		error "╚══════════════════════════════════════════════════════════════════╝"
		error "Old instance version: $M_VERSION"
		error "New stack version:    $new_version"
		error ""
		error "Nextcloud will refuse to start if versions do not match exactly."
		error ""
		error "Options:"
		error "  A) On the OLD HOST: upgrade Nextcloud to version $new_version,"
		error "     re-run export.sh, re-transfer, then retry this script."
		error ""
		error "  B) In nextcloud/docker-compose.yaml: change the image tag to"
		error "     nextcloud:$M_VERSION, restart the stack to match the old version,"
		error "     complete the migration, then upgrade afterwards."
		exit 1
	fi

	success "Version match confirmed: $new_version"
}

# ── New stack credentials ─────────────────────────────────────────────────────
NEW_PG_USER=""
NEW_PG_DB=""
NEW_PG_PASS=""
NEW_DATA_VOLUME=""
NEW_DATA_DIR=""

read_new_credentials() {
	step "Reading new stack configuration (NEW HOST)"

	NEW_PG_USER=$(get_env_var "POSTGRES_USER")
	NEW_PG_DB=$(get_env_var "POSTGRES_DB")
	NEW_PG_PASS=$(cat "$SECRETS_DIR/postgres_password")
	NEW_DATA_DIR=$(get_env_var "NEXTCLOUD_DATA_DIR")

	local volume_dir
	volume_dir=$(get_env_var "DOCKER_VOLUME_DIR")
	if [[ -z "$volume_dir" ]]; then
		volume_dir="/var/lib/nextcloud"
	fi
	NEW_DATA_VOLUME="${volume_dir}/data"

	if [[ -z "$NEW_PG_USER" || -z "$NEW_PG_DB" ]]; then
		error "Could not read POSTGRES_USER or POSTGRES_DB from nextcloud/.env"
		exit 1
	fi

	verbose "PostgreSQL user:  $NEW_PG_USER"
	verbose "PostgreSQL db:    $NEW_PG_DB"
	verbose "Data volume path: $NEW_DATA_VOLUME"
	verbose "NEXTCLOUD_DATA_DIR: ${NEW_DATA_DIR:-<not set>}"

	success "New stack credentials loaded"
}

# ── Data directory path check ─────────────────────────────────────────────────
# Nextcloud documentation: "Changing the location of the data directory might
# cause a corruption of relations in the database and is not supported."
# Fail fast before any database operations if the paths differ.
check_data_directory() {
	step "Checking data directory path compatibility (NEW HOST)"

	if [[ -z "$M_DATA_DIRECTORY" ]]; then
		warn "No datadirectory in export manifest; skipping path check."
		warn "Verify manually that NEXTCLOUD_DATA_DIR in nextcloud/.env matches"
		warn "the old instance's datadirectory before proceeding."
		return
	fi

	if [[ -z "$NEW_DATA_DIR" ]]; then
		warn "NEXTCLOUD_DATA_DIR not set in nextcloud/.env; skipping path check."
		warn "Ensure NEXTCLOUD_DATA_DIR is set to match the old instance:"
		warn "  Old instance datadirectory: $M_DATA_DIRECTORY"
		return
	fi

	verbose "Old datadirectory:  $M_DATA_DIRECTORY"
	verbose "New NEXTCLOUD_DATA_DIR: $NEW_DATA_DIR"

	if [[ "$M_DATA_DIRECTORY" == "$NEW_DATA_DIR" ]]; then
		success "Data directory path matches: $NEW_DATA_DIR"
		return
	fi

	echo ""
	error "DATA DIRECTORY PATH MISMATCH - CANNOT PROCEED"
	error ""
	error "  Old instance datadirectory: $M_DATA_DIRECTORY"
	error "  New NEXTCLOUD_DATA_DIR:     $NEW_DATA_DIR"
	error ""
	error "Nextcloud documentation states: \"Changing the location of the data"
	error "directory might cause a corruption of relations in the database"
	error "and is not supported.\""
	error ""
	error "Set NEXTCLOUD_DATA_DIR in nextcloud/.env to match the old path:"
	error ""
	error "  NEXTCLOUD_DATA_DIR=$M_DATA_DIRECTORY"
	error ""
	error "The volume mount in docker-compose.yaml is already parameterized as"
	error "  \${NEXTCLOUD_DATA_VOLUME}:\${NEXTCLOUD_DATA_DIR}"
	error "so only the .env change is needed. Then recreate the app container:"
	error ""
	error "  docker compose -f nextcloud/docker-compose.yaml up -d --force-recreate nextcloud_app"
	error ""
	error "Re-run this script after recreating the stack."
	exit 1
}

# ── Database import ───────────────────────────────────────────────────────────

# psql restore via stdin - matches Nextcloud official restore documentation
_pg_restore() {
	local dump_file="$1" user="$2" db="$3" pass="$4"
	docker exec -i \
		-e PGPASSWORD="$pass" \
		nextcloud_postgres \
		psql -U "$user" -d "$db" \
		<"$dump_file"
}

_psql() {
	local user="$1" pass="$2" db="$3" sql="$4"
	docker exec \
		-e PGPASSWORD="$pass" \
		nextcloud_postgres \
		psql -U "$user" -d "$db" -c "$sql"
}

get_nextcloud_db_credentials() {
	local dbuser dbpass
	dbuser=$(docker exec -u www-data nextcloud_app php occ config:system:get dbuser 2>/dev/null)
	dbpass=$(docker exec -u www-data nextcloud_app php occ config:system:get dbpassword 2>/dev/null)
	if [[ -n "$dbuser" && -n "$dbpass" ]]; then
		echo "$dbuser:$dbpass"
		return 0
	else
		return 1
	fi
}

import_database() {
	step "Importing database (NEW HOST)"

	case "$M_DB_TYPE" in
	pgsql)
		local dump_file="$EXPORT_DIR/db-dump.sql"
		if [[ ! -f "$dump_file" ]]; then
			error "PostgreSQL dump not found: $dump_file"
			exit 1
		fi

		# Get the database credentials Nextcloud is configured to use BEFORE stopping the app
		info "Reading Nextcloud database configuration..."
		local nc_dbuser nc_dbpass nc_dbcreds
		nc_dbcreds=$(get_nextcloud_db_credentials)
		if [[ -z "$nc_dbcreds" ]]; then
			error "Could not read database credentials from Nextcloud config"
			error "Ensure nextcloud_app is running and configured"
			exit 1
		fi

		IFS=':' read -r nc_dbuser nc_dbpass <<<"$nc_dbcreds"
		verbose "Nextcloud configured to use database user: $nc_dbuser"

		info "Stopping all services except nextcloud_postgres..."
		runcmd docker compose -f "$COMPOSE_FILE" --env-file "$ENV_FILE" stop \
			$(docker compose -f "$COMPOSE_FILE" --env-file "$ENV_FILE" ps --services 2>/dev/null | grep -v '^nextcloud_postgres$' | tr '\n' ' ')

		info "Dropping and recreating database '$NEW_PG_DB'..."
		if [[ "$DRY_RUN" == true ]]; then
			echo -e "  ${YELLOW}[dry-run]${NC} Would drop and recreate database: $NEW_PG_DB"
		else
			_psql "$NEW_PG_USER" "$NEW_PG_PASS" "postgres" \
				"DROP DATABASE IF EXISTS \"${NEW_PG_DB}\";"
			_psql "$NEW_PG_USER" "$NEW_PG_PASS" "postgres" \
				"CREATE DATABASE \"${NEW_PG_DB}\" OWNER \"$nc_dbuser\";"
		fi

		info "Restoring database dump as '$nc_dbuser' (this may take a while)..."
		if [[ "$DRY_RUN" == true ]]; then
			echo -e "  ${YELLOW}[dry-run]${NC} Would restore: $dump_file -> $NEW_PG_DB (as user $nc_dbuser)"
		else
			_pg_restore "$dump_file" "$nc_dbuser" "$NEW_PG_DB" "$nc_dbpass"

			# Verify the restore succeeded by checking if the Nextcloud user can access tables
			if docker exec nextcloud_postgres psql -U "$nc_dbuser" -d "$NEW_PG_DB" \
				-c "SELECT COUNT(*) FROM oc_appconfig;" >/dev/null 2>&1; then
				success "Database restored and verified (tables owned by '$nc_dbuser')"
			else
				error "Database restore verification failed"
				# Check if this is a permissions issue or a missing table issue
				if docker exec nextcloud_postgres psql -U "$nc_dbuser" -d "$NEW_PG_DB" \
					-c "\dt oc_appconfig" 2>&1 | grep -q "oc_appconfig"; then
					error "Table oc_appconfig exists but user '$nc_dbuser' lacks SELECT permission"
					error "This suggests ownership was not reassigned correctly"
				else
					error "Table oc_appconfig not found - database restore may have failed"
					error "Check if the dump file is empty or corrupted:"
					error "  wc -l $dump_file"
				fi
				error ""
				error "Debug information:"
				_psql "$NEW_PG_USER" "$NEW_PG_PASS" "$NEW_PG_DB" \
					"SELECT tablename, tableowner FROM pg_tables WHERE schemaname = 'public' ORDER BY tablename LIMIT 10;" 2>&1 || true
				exit 1
			fi
		fi

		success "PostgreSQL database restored"
		;;

	mysql)
		local dump_file="$EXPORT_DIR/db-dump.sql"
		if [[ ! -f "$dump_file" ]]; then
			error "MySQL dump not found: $dump_file"
			exit 1
		fi

		echo ""
		warn "MySQL/MariaDB -> PostgreSQL migration requires pgloader."
		warn "This is a multi-step process that cannot be fully automated here"
		warn "because it requires a live connection to the OLD MySQL host."
		echo ""
		info "Steps to complete the MySQL -> PostgreSQL migration:"
		echo ""
		echo "  1. Install pgloader on this host:"
		echo "       apt-get install pgloader"
		echo ""
		echo "  2. Expose the new PostgreSQL port temporarily (or run pgloader"
		echo "     from inside the nextcloud_postgres container)."
		echo ""
		echo "  3. Create a pgloader config file:"

		local old_host="${M_DB_HOST%%:*}"
		local old_name="${M_DB_NAME:-<dbname>}"
		local old_user="${M_DB_USER:-<dbuser>}"

		cat <<PGEOF

       File: /tmp/nc-migration-pgloader.load
       ----------------------------------------
       LOAD DATABASE
           FROM mysql://${old_user}:<password>@${old_host}/${old_name}
           INTO postgresql://${NEW_PG_USER}:<password>@127.0.0.1/${NEW_PG_DB}
       WITH include no drop, truncate, create tables, create indexes,
            reset sequences, foreign keys, downcase identifiers
       ;
       ----------------------------------------

PGEOF
		echo "  4. Run: pgloader /tmp/nc-migration-pgloader.load"
		echo ""
		echo "  5. Then re-run this import script - it will skip the DB step"
		echo "     and continue with the remaining steps."
		echo ""
		echo "Alternatively: if you can restore the MySQL dump into a temporary"
		echo "MySQL Docker container, run pgloader against localhost instead."
		echo ""
		error "Stopping here. Complete the pgloader step above, then re-run."
		exit 1
		;;

	sqlite3)
		echo ""
		error "SQLite -> PostgreSQL migration is not directly supported by this script."
		error ""
		error "Recommended path:"
		error "  1. On the OLD HOST, convert SQLite to MySQL with occ:"
		error "     sudo -u www-data php occ db:convert-type --all-apps mysql <user> <host> <db>"
		error "  2. Re-run export.sh on the OLD HOST (it will now export MySQL)."
		error "  3. Re-transfer the export bundle to this host."
		error "  4. Re-run this script."
		exit 1
		;;

	*)
		error "Unknown database type in manifest: $M_DB_TYPE"
		exit 1
		;;
	esac
}

# ── Data ownership fix ────────────────────────────────────────────────────────
fix_data_ownership() {
	step "Fixing data directory ownership (NEW HOST)"

	info "Setting ownership to www-data (UID 33:GID 33) on: $NEW_DATA_VOLUME"
	runcmd docker run --rm \
		-v "${NEW_DATA_VOLUME}:/data" \
		alpine \
		chown -R 33:33 /data

	# Verify the directory has content. Docker auto-creates missing host paths as
	# empty directories, so an empty result means the data rsync was likely skipped.
	if [[ "$DRY_RUN" != true ]]; then
		local file_count
		file_count=$(docker run --rm -v "${NEW_DATA_VOLUME}:/data:ro" alpine sh -c 'ls /data 2>/dev/null | wc -l')
		if [[ "$file_count" -eq 0 ]]; then
			error "Data directory is empty: $NEW_DATA_VOLUME"
			error "Rsync user files to the new host first, then re-run this script:"
			error "  rsync -avz --progress -t user@OLD_HOST:<HOST_DATA_DIR>/ $NEW_DATA_VOLUME/"
			exit 1
		else
			success "Data directory ownership fixed ($file_count item(s) at root level)"
		fi
	else
		success "Data directory ownership fixed"
	fi
}

# ── Start app and wait for health ─────────────────────────────────────────────
start_app_and_wait() {
	step "Starting nextcloud_app (NEW HOST)"

	runcmd docker compose -f "$COMPOSE_FILE" --env-file "$ENV_FILE" start nextcloud_app

	if [[ "$DRY_RUN" == true ]]; then
		info "[dry-run] Would wait for nextcloud_app to become ready..."
		return
	fi

	# Poll occ status directly rather than the Docker healthcheck.
	# The healthcheck has a start_period of 600 s (it probes Apache), but occ
	# becomes usable as soon as the entrypoint hooks finish - well before that.
	info "Waiting for nextcloud_app to become ready (up to 600s)..."
	local waited=0
	while [[ $waited -lt 600 ]]; do
		if docker exec -u www-data nextcloud_app php occ status &>/dev/null; then
			echo ""
			success "nextcloud_app is ready"
			return
		fi
		sleep 10
		waited=$((waited + 10))
		echo -n "."
	done
	echo ""
	warn "nextcloud_app did not become ready within 600s."
	warn "Check logs with: docker compose -f nextcloud/docker-compose.yaml logs nextcloud_app"
	warn "Attempting to continue - subsequent occ commands may fail."
}

# ── occ runner (new host) ─────────────────────────────────────────────────────
new_occ() {
	docker exec -u www-data nextcloud_app php occ "$@"
}

# ── Apply config values from old instance ─────────────────────────────────────
apply_config_values() {
	step "Applying configuration values from old instance (NEW HOST)"

	info "Setting instanceid..."
	runcmd new_occ config:system:set instanceid --value="$M_INSTANCE_ID"

	info "Setting passwordsalt..."
	runcmd new_occ config:system:set passwordsalt --value="$M_PASSWORD_SALT"

	info "Setting secret..."
	runcmd new_occ config:system:set secret --value="$M_SECRET"

	if [[ -n "$M_DATA_FINGERPRINT" ]]; then
		info "Setting data-fingerprint..."
		runcmd new_occ config:system:set data-fingerprint --value="$M_DATA_FINGERPRINT"
	else
		verbose "No data-fingerprint in manifest; will be generated by maintenance:data-fingerprint"
	fi

	success "Configuration values applied"
}

# ── Admin password handling ───────────────────────────────────────────────────
handle_admin_password() {
	step "Admin password (NEW HOST)"

	echo ""
	warn "The admin user's password is now the OLD system's admin password."
	warn "The new stack's generated admin_password secret is NOT active for login."
	echo ""

	local response="n"
	if [[ "$NON_INTERACTIVE" != true ]]; then
		read -r -p "Reset admin password to this stack's generated password? [y/N] " response
		echo ""
	else
		info "[non-interactive] Skipping admin password reset."
	fi

	if [[ "${response,,}" == "y" || "${response,,}" == "yes" ]]; then
		local new_pass
		new_pass=$(cat "$SECRETS_DIR/admin_password")
		info "Resetting admin password..."
		if [[ "$DRY_RUN" == true ]]; then
			echo -e "  ${YELLOW}[dry-run]${NC} Would reset admin password via occ user:resetpassword"
		else
			# Temporarily disable password_policy so the generated password is accepted
			# regardless of the old instance's password rules.
			local policy_was_enabled=false
			if new_occ app:list --output=json 2>/dev/null | jq -e '.enabled | has("password_policy")' &>/dev/null; then
				policy_was_enabled=true
				verbose "Disabling password_policy app for password reset..."
				new_occ app:disable password_policy &>/dev/null || true
			fi

			docker exec \
				-e OC_PASS="$new_pass" \
				-u www-data nextcloud_app \
				php occ user:resetpassword --password-from-env admin

			if [[ "$policy_was_enabled" == true ]]; then
				verbose "Re-enabling password_policy app..."
				new_occ app:enable password_policy &>/dev/null || true
			fi
		fi
		success "Admin password reset to the value in nextcloud/secrets/admin_password"
	else
		info "Admin password left unchanged. Use the OLD system's admin password to log in."
	fi
}

# ── Post-import occ commands ──────────────────────────────────────────────────
run_post_import_occ() {
	step "Running post-import maintenance commands (NEW HOST)"

	info "Running database upgrade..."
	if [[ "$DRY_RUN" == true ]]; then
		echo -e "  ${YELLOW}[dry-run]${NC} new_occ upgrade"
	else
		# Snapshot enabled apps before the upgrade. occ upgrade may disable some
		# as incompatible; capturing them here includes them in the summary even
		# though occ already handled the database cleanup for those.
		local pre_upgrade_enabled=()
		while IFS= read -r app; do
			[[ -n "$app" ]] && pre_upgrade_enabled+=("$app")
		done < <(new_occ config:list --output=json 2>/dev/null \
			| jq -r '.apps | to_entries[] | select(.value.enabled == "yes") | .key' \
			2>/dev/null || true)

		new_occ upgrade

		# Find apps that occ upgrade disabled that have no installation directory
		# on this host (i.e. they were from the old instance but are not part of
		# this stack). Apps disabled because their installed version is outdated
		# are excluded; those still have a directory and can be updated from
		# Settings > Apps.
		if [[ "${#pre_upgrade_enabled[@]}" -gt 0 ]]; then
			local post_upgrade_enabled
			post_upgrade_enabled=$(new_occ config:list --output=json 2>/dev/null \
				| jq -r '.apps | to_entries[] | select(.value.enabled == "yes") | .key' \
				2>/dev/null || true)
			for app in "${pre_upgrade_enabled[@]}"; do
				if ! echo "$post_upgrade_enabled" | grep -qx "$app" &&
					! docker exec nextcloud_app test -d "/var/www/html/apps/$app" 2>/dev/null &&
					! docker exec nextcloud_app test -d "/var/www/html/custom_apps/$app" 2>/dev/null; then
					REMOVED_APPS+=("$app")
				fi
			done
			if [[ "${#REMOVED_APPS[@]}" -gt 0 ]]; then
				info "occ upgrade disabled ${#REMOVED_APPS[@]} app(s) not installed on this host (listed at end of output)"
			fi
		fi
	fi

	# Remove deploy daemons from the old instance. The restored database carries
	# over any app_api daemon registrations (e.g. docker_aio from Nextcloud AIO),
	# which appear alongside the new stack's daemon registered by before-startup.sh.
	# Unregister all daemons here; before-startup.sh re-registers the correct one
	# on every startup so nothing is lost.
	if [[ "$DRY_RUN" == true ]]; then
		echo -e "  ${YELLOW}[dry-run]${NC} Would unregister app_api deploy daemons from old instance"
	else
		local old_daemons
		old_daemons=$(new_occ app_api:daemon:list --output=json 2>/dev/null | jq -r '.[].name' 2>/dev/null || true)
		if [[ -n "$old_daemons" ]]; then
			info "Removing app_api deploy daemons from old instance..."
			while IFS= read -r daemon; do
				verbose "Unregistering: $daemon"
				new_occ app_api:daemon:unregister "$daemon" &>/dev/null || true
			done <<<"$old_daemons"
		fi
	fi

	# Disable apps that are marked as enabled in the database but have no
	# corresponding directory on the new installation. These are apps from the
	# old instance that are not part of this stack (e.g. aio-nextcloud, or apps
	# removed from the App Store). Without this step they cause repeated
	# AppPathNotFoundException errors in the logs on every request.
	# config:list is used instead of app:list because app:list silently skips
	# apps whose directories are missing, which is the condition being detected.
	if [[ "$DRY_RUN" == true ]]; then
		echo -e "  ${YELLOW}[dry-run]${NC} Would disable apps enabled in database but missing from filesystem"
	else
		info "Checking for apps enabled in database but missing from filesystem..."
		local missing_apps=()
		while IFS= read -r app; do
			[[ -z "$app" ]] && continue
			if ! docker exec nextcloud_app test -d "/var/www/html/apps/$app" 2>/dev/null &&
				! docker exec nextcloud_app test -d "/var/www/html/custom_apps/$app" 2>/dev/null; then
				missing_apps+=("$app")
			elif docker exec nextcloud_app test -d "/var/www/html/custom_apps/$app" 2>/dev/null &&
				! docker exec nextcloud_app test -f "/var/www/html/custom_apps/$app/appinfo/info.xml" 2>/dev/null; then
				# Directory exists but appinfo/info.xml is missing: the App Store
				# update downloaded an incomplete archive and left the directory in
				# a broken state. Nextcloud cannot load the app and will refuse to
				# start. Disable it so the instance remains functional; reinstall
				# from Settings > Apps to restore it.
				warn "App '$app' has a broken installation in custom_apps/ (incomplete update); disabling."
				missing_apps+=("$app")
			fi
		done < <(new_occ config:list --output=json 2>/dev/null \
			| jq -r '.apps | to_entries[] | select(.value.enabled == "yes") | .key' \
			2>/dev/null || true)
		if [[ "${#missing_apps[@]}" -gt 0 ]]; then
			for app in "${missing_apps[@]}"; do
				REMOVED_APPS+=("$app")
				# config:app:delete removes the enabled entry so the App Store shows
				# the app as available to install rather than disabled. This is a core
				# command that works even when the app directory does not exist.
				new_occ config:app:delete "$app" enabled &>/dev/null || true
			done
			info "Removed ${#missing_apps[@]} app(s) not installed on this host (listed at end of output)"
		else
			info "All enabled apps have a corresponding installation directory"
		fi

		# Remove stale background jobs whose class files no longer exist.
		# Covers apps disabled by occ upgrade and apps cleaned up above.
		# OCA\ class names follow PSR-4: OCA\{Ns}\{Sub}\{Class} maps to
		# {app_dir}/lib/{Sub}/{Class}.php - so checking for the file is precise.
		# OC\ and OCP\ are core classes; only OCA\ (third-party) jobs are checked.
		info "Cleaning up stale background jobs for uninstalled apps..."
		local stale_count=0
		local job_id job_class rel_path
		while IFS=$'\t' read -r job_id job_class; do
			[[ -z "$job_id" || -z "$job_class" ]] && continue
			[[ "$job_class" != OCA\\* ]] && continue
			# Strip OCA\ and the app namespace segment to get the lib-relative path:
			# OCA\UserRetention\BackgroundJob\ExpireUsers -> BackgroundJob/ExpireUsers
			rel_path=$(echo "$job_class" | cut -d'\' -f3- | tr '\\' '/')
			[[ -z "$rel_path" ]] && continue
			if ! docker exec nextcloud_app find /var/www/html/apps /var/www/html/custom_apps \
				-path "*/lib/${rel_path}.php" 2>/dev/null | grep -q .; then
				verbose "  [job cleanup] REMOVING id=$job_id class=$job_class (file not found: */lib/${rel_path}.php)"
				new_occ background-job:delete "$job_id" &>/dev/null || true
				stale_count=$((stale_count + 1))
			else
				verbose "  [job cleanup] keeping  id=$job_id class=$job_class"
			fi
		done < <(new_occ background-job:list --output=json 2>/dev/null \
			| jq -r '.[] | [(.id | tostring), .class] | @tsv' \
			2>/dev/null || true)
		if [[ "$stale_count" -gt 0 ]]; then
			info "Removed $stale_count stale background job(s) for uninstalled apps"
		fi
	fi

	# before-startup.sh also runs these on every startup, so if they fail here
	# they will complete on the next container restart.
	info "Adding missing database indices..."
	runcmd new_occ db:add-missing-indices

	info "Adding missing database columns..."
	runcmd new_occ db:add-missing-columns

	info "Running maintenance:repair --include-expensive (this may take a while)..."
	runcmd new_occ maintenance:repair --include-expensive

	info "Updating data-fingerprint (sync clients will re-sync cleanly)..."
	runcmd new_occ maintenance:data-fingerprint

	success "Post-import maintenance complete"
}

# ── Post-migration checklist ──────────────────────────────────────────────────
print_checklist() {
	step "Post-migration checklist"

	echo ""
	echo -e "${BOLD}Complete these steps manually:${NC}"
	echo ""
	echo "  1. OLD HOST - Disable maintenance mode so users get a clear error"
	echo "     if they hit the old server address (not a confusing maintenance page):"
	echo "       docker exec -u www-data nextcloud_app php occ maintenance:mode --off"
	echo ""
	echo "  2. DNS - Update your Nextcloud domain's DNS record to point to"
	echo "     the Cloudflare tunnel of the NEW host."
	echo "     Find the tunnel connector hostname in the Cloudflare dashboard"
	echo "     under Zero Trust > Networks > Tunnels."
	echo ""
	echo "  3. NEW HOST - Monitor logs after DNS cutover:"
	echo "       docker compose -f nextcloud/docker-compose.yaml logs -f nextcloud_app"
	echo ""
	echo "  4. Cloudflare - Revoke the old host's tunnel token in the Cloudflare"
	echo "     dashboard once you are satisfied the new host is working."
	echo ""
	echo "  5. External storage - If the old instance had external storage configured,"
	echo "     reconfigure those connections on the new instance:"
	echo "     Settings > Administration > External Storages"
	echo ""
	echo "  6. OLD HOST - Decommission (power off / delete the VM) once satisfied."
	echo ""
	echo -e "  ${YELLOW}Optional:${NC} If files appear missing after login, run a file scan:"
	echo "       docker exec -u www-data nextcloud_app php occ files:scan --all"
	echo "     (This is slow on large instances - only run if needed.)"
	echo ""
}

# ── Cleanup ───────────────────────────────────────────────────────────────────
cleanup_prompt() {
	step "Cleanup (NEW HOST)"

	if [[ "$DRY_RUN" == true ]]; then
		info "[dry-run] Skipping export bundle removal prompt."
		return
	fi

	echo ""
	warn "Please verify the migration before cleaning up:"
	warn "  - Log in to Nextcloud with the admin account"
	warn "  - Confirm user files are visible"
	warn "  - Check Settings > Administration > Overview for any warnings"
	echo ""

	local response="n"
	if [[ "$NON_INTERACTIVE" != true ]]; then
		read -r -p "Migration looks correct? Remove the export bundle? [y/N] " response
		echo ""
	else
		info "[non-interactive] Keeping export bundle (non-interactive mode)."
	fi

	if [[ "${response,,}" == "y" || "${response,,}" == "yes" ]]; then
		if [[ -d "$EXPORT_DIR" ]]; then
			runcmd rm -rf "$EXPORT_DIR"
			success "Removed: $EXPORT_DIR"
		fi
		success "Cleanup complete"
	else
		info "Export bundle kept at: $EXPORT_DIR"
		info "Remove it manually when you are satisfied with the migration."
	fi
}

# ── Main ──────────────────────────────────────────────────────────────────────
main() {
	# Resolve export bundle directory. If --export-dir was not given, pick the
	# most recently modified bundle in nextcloud/migrate/bundles/.
	if [[ -z "$EXPORT_DIR" ]]; then
		EXPORT_DIR=$(ls -td "$SCRIPT_DIR/bundles/nc-migration-export-"* 2>/dev/null | head -1 || true)
		if [[ -z "$EXPORT_DIR" ]]; then
			EXPORT_DIR="$SCRIPT_DIR/bundles/nc-migration-export"
		fi
	fi

	# Set up logging before any output so the full run is captured.
	# Log goes in the export bundle dir so it stays with the migration artifacts.
	# Falls back to the current directory if the bundle dir does not yet exist.
	local log_file
	if [[ -d "$EXPORT_DIR" ]]; then
		log_file="$EXPORT_DIR/import-$(date +%Y%m%d-%H%M%S).log"
	else
		log_file="nc-migration-import-$(date +%Y%m%d-%H%M%S).log"
	fi
	exec > >(tee -a "$log_file") 2>&1
	trap 'echo ""; echo "Run ended:   $(date)"' EXIT

	echo ""
	echo -e "${BOLD}Nextcloud Migration - Import Script${NC}"
	echo -e "${BOLD}Run on the NEW HOST from the repository root${NC}"
	if [[ "$DRY_RUN" == true ]]; then
		echo -e "${YELLOW}DRY-RUN MODE: No changes will be made${NC}"
	fi
	echo "Run started: $(date)"
	info "Logging to: $log_file"
	echo ""

	check_prerequisites
	read_manifest
	read_new_credentials
	check_version
	check_data_directory
	import_database
	fix_data_ownership
	start_app_and_wait
	apply_config_values
	run_post_import_occ

	step "Starting remaining services (NEW HOST)"
	runcmd docker compose -f "$COMPOSE_FILE" --env-file "$ENV_FILE" up -d
	success "All services started"

	handle_admin_password
	print_checklist
	cleanup_prompt

	if [[ "${#REMOVED_APPS[@]}" -gt 0 ]]; then
		echo ""
		echo -e "${YELLOW}━━━ Apps not installed on this host (${#REMOVED_APPS[@]}) ━━━${NC}"
		echo -e "${YELLOW}These apps were enabled on the old instance but are not installed here.${NC}"
		echo -e "${YELLOW}They have been removed from the database to prevent log flooding.${NC}"
		echo -e "${YELLOW}Reinstall from Settings > Apps if needed:${NC}"
		for app in "${REMOVED_APPS[@]}"; do
			echo -e "${YELLOW}  - $app${NC}"
		done
		echo ""
	fi

	success "Migration complete."
}

main
