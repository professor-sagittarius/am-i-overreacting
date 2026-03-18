#!/usr/bin/env bash
# export.sh - Run on the OLD HOST to export Nextcloud data for migration
# Usage: bash export.sh [--dry-run] [-v|--verbose] [--container <name>]
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
DRY_RUN=false
VERBOSE=false
CONTAINER=""
EXPORT_DIR="nc-migration-export-$(date +%Y%m%d-%H%M%S)"

# ── Argument parsing ──────────────────────────────────────────────────────────
usage() {
	cat <<EOF
Usage: bash export.sh [OPTIONS]

Run on the OLD HOST to export Nextcloud data for migration.

Options:
  --dry-run           Preview actions without executing
  -v, --verbose       Show detailed output
  --container NAME    Specify the Nextcloud Docker container name
  --output-dir DIR    Directory to write export files (default: nc-migration-export)
  -h, --help          Show this help

EOF
}

while [[ $# -gt 0 ]]; do
	case $1 in
	--dry-run) DRY_RUN=true ;;
	-v | --verbose) VERBOSE=true ;;
	--container)
		CONTAINER="$2"
		shift
		;;
	--output-dir)
		EXPORT_DIR="$2"
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

# ── Dry-run wrapper (skip write/state-changing commands) ──────────────────────
# Use for simple commands. For complex operations with pipes/redirections,
# handle DRY_RUN inline in the calling code.
runcmd() {
	if [[ "$DRY_RUN" == true ]]; then
		echo -e "  ${YELLOW}[dry-run]${NC} $*"
	else
		"$@"
	fi
}

# ── Prerequisites ─────────────────────────────────────────────────────────────
check_prerequisites() {
	step "Checking prerequisites (OLD HOST)"
	local missing=()
	command -v jq &>/dev/null || missing+=("jq")
	if [[ "${#missing[@]}" -gt 0 ]]; then
		error "Missing required tools: ${missing[*]}"
		error "Install with: apt-get install ${missing[*]}   or   yum install ${missing[*]}"
		exit 1
	fi
	success "All prerequisites present"
}

# ── Environment detection ─────────────────────────────────────────────────────
DOCKER_MODE=false
NEXTCLOUD_ROOT=""

detect_environment() {
	step "Detecting Nextcloud installation (OLD HOST)"

	if command -v docker &>/dev/null; then
		if [[ -n "$CONTAINER" ]]; then
			if docker ps --format '{{.Names}}' | grep -q "^${CONTAINER}$"; then
				DOCKER_MODE=true
				success "Using specified container: $CONTAINER"
				return
			else
				error "Container '$CONTAINER' is not running. Check with: docker ps"
				exit 1
			fi
		fi

		# Try well-known names in order
		local candidates=(
			"nextcloud-aio-nextcloud"
			"nextcloud_app"
			"nextcloud-app"
			"nextcloud"
			"nextcloud-web"
		)
		for name in "${candidates[@]}"; do
			if docker ps --format '{{.Names}}' | grep -qx "$name"; then
				CONTAINER="$name"
				DOCKER_MODE=true
				success "Found Nextcloud container: $CONTAINER"
				return
			fi
		done

		# Nextcloud AIO with custom stack name: matches *-nextcloud
		local aio_matches
		aio_matches=$(docker ps --format '{{.Names}}' | grep -E '\-nextcloud$' || true)
		local aio_count
		aio_count=$(echo "$aio_matches" | grep -c '\S' || true)
		if [[ "$aio_count" -eq 1 ]]; then
			CONTAINER=$(echo "$aio_matches" | head -1)
			DOCKER_MODE=true
			success "Found Nextcloud AIO container: $CONTAINER"
			return
		elif [[ "$aio_count" -gt 1 ]]; then
			error "Multiple *-nextcloud containers found:"
			# shellcheck disable=SC2001
			echo "$aio_matches" | sed 's/^/  /'
			error "Specify which to use with: --container <name>"
			exit 1
		fi
	fi

	# Bare-metal fallback
	local nc_paths=(
		"/var/www/html"
		"/var/www/nextcloud"
		"/var/www/nextcloud-server"
		"/opt/nextcloud"
	)
	for path in "${nc_paths[@]}"; do
		if [[ -f "$path/occ" ]]; then
			NEXTCLOUD_ROOT="$path"
			success "Found bare-metal Nextcloud at: $NEXTCLOUD_ROOT"
			return
		fi
	done

	error "Could not find a running Nextcloud installation."
	error "If using Docker, make sure the container is running (docker ps)."
	error "If using bare-metal, ensure Nextcloud is installed in a standard location."
	error "You can also specify the container manually with --container <name>."
	exit 1
}

# ── occ runner ────────────────────────────────────────────────────────────────
run_occ() {
	if [[ "$DOCKER_MODE" == true ]]; then
		docker exec -u www-data "$CONTAINER" php occ "$@"
	else
		sudo -u www-data php "$NEXTCLOUD_ROOT/occ" "$@"
	fi
}

# Get a single config:system value; returns empty string if not set
get_config() {
	run_occ config:system:get "$1" 2>/dev/null || true
}

# ── Maintenance mode ──────────────────────────────────────────────────────────
MAINTENANCE_ENABLED=false
EXPORT_COMPLETED=false

enable_maintenance() {
	step "Enabling maintenance mode (OLD HOST)"
	if [[ "$DRY_RUN" == true ]]; then
		echo -e "  ${YELLOW}[dry-run]${NC} Would run: occ maintenance:mode --on"
		info "Maintenance mode would be enabled here"
	else
		run_occ maintenance:mode --on
		MAINTENANCE_ENABLED=true
		success "Maintenance mode enabled - Nextcloud is now offline"
	fi
	warn "Do NOT disable maintenance mode until the new server is verified and DNS is switched."
}

on_exit() {
	if [[ "$MAINTENANCE_ENABLED" == true && "$EXPORT_COMPLETED" != true ]]; then
		echo ""
		warn "Script exited early. Nextcloud is still in maintenance mode on the OLD HOST."
		warn "Once migration is complete (or to abort), disable it with:"
		if [[ "$DOCKER_MODE" == true ]]; then
			warn "  docker exec -u www-data $CONTAINER php occ maintenance:mode --off"
		else
			warn "  sudo -u www-data php $NEXTCLOUD_ROOT/occ maintenance:mode --off"
		fi
	fi
}
trap on_exit EXIT

# ── Safety checks ─────────────────────────────────────────────────────────────
check_encryption() {
	local enc
	enc=$(run_occ config:app:get core encryption-enabled 2>/dev/null || echo "false")
	if [[ "$enc" == "true" || "$enc" == "1" ]]; then
		echo ""
		error "╔══════════════════════════════════════════════════════════════╗"
		error "║          SERVER-SIDE ENCRYPTION IS ENABLED                  ║"
		error "╚══════════════════════════════════════════════════════════════╝"
		error "This migration script does NOT handle encryption key migration."
		error "Proceeding without migrating encryption keys will result in"
		error "all encrypted files becoming permanently inaccessible."
		error ""
		error "Please follow the Nextcloud encryption migration guide first:"
		error "  https://docs.nextcloud.com/server/latest/admin_manual/configuration_files/encryption_configuration.html"
		exit 1
	fi
	success "Server-side encryption: not enabled"
}

check_totp() {
	local totp
	totp=$(run_occ app:list 2>/dev/null | grep -i totp || true)
	if [[ -n "$totp" ]]; then
		echo ""
		warn "Two-factor authentication (TOTP) is active on this instance."
		warn "After migration, the admin user will still require their TOTP authenticator app."
		warn "Make sure you have access to it before attempting to log in post-migration."
		echo ""
	fi
}

# ── Database detection helpers ────────────────────────────────────────────────
find_db_container() {
	# $1 = "postgres" or "mysql"
	local candidates=()
	if [[ "$1" == "postgres" ]]; then
		candidates=("nextcloud-aio-database" "nextcloud_postgres" "nextcloud-db" "postgres" "postgresql")
	else
		candidates=("nextcloud-aio-mariadb" "nextcloud_mariadb" "nextcloud-db" "mariadb" "mysql")
	fi
	for name in "${candidates[@]}"; do
		if docker ps --format '{{.Names}}' | grep -qx "$name" 2>/dev/null; then
			echo "$name"
			return
		fi
	done
	echo ""
}

# ── Database dump functions ───────────────────────────────────────────────────
# Each function accepts: user db pass outfile (plus container or host as first arg).
# Defined as named functions so runcmd can reference them cleanly without
# embedding secrets in quoted strings.

_pg_dump_container() {
	local container="$1" user="$2" db="$3" pass="$4" outfile="$5"
	docker exec -e PGPASSWORD="$pass" "$container" pg_dump -U "$user" --no-owner --no-acl "$db" >"$outfile"
}

_pg_dump_bare() {
	local host="$1" user="$2" db="$3" pass="$4" outfile="$5"
	PGPASSWORD="$pass" pg_dump -h "$host" -U "$user" --no-owner --no-acl "$db" >"$outfile"
}

_mysql_dump_container() {
	local container="$1" user="$2" db="$3" pass="$4" outfile="$5"
	# MYSQL_PWD avoids -p quoting issues with special characters
	docker exec -e MYSQL_PWD="$pass" "$container" \
		mysqldump --single-transaction --routines --triggers -u "$user" "$db" >"$outfile"
}

_mysql_dump_bare() {
	local host="$1" user="$2" db="$3" pass="$4" outfile="$5"
	MYSQL_PWD="$pass" mysqldump --single-transaction --routines --triggers \
		-h "$host" -u "$user" "$db" >"$outfile"
}

# ── Export database ───────────────────────────────────────────────────────────
export_database() {
	local db_type="$1" db_host="$2" db_name="$3" db_user="$4" db_pass="$5"

	case "$db_type" in
	pgsql)
		local dump_file="$EXPORT_DIR/db-dump.sql"
		info "Exporting PostgreSQL database '$db_name'..."
		if [[ "$DRY_RUN" == true ]]; then
			echo -e "  ${YELLOW}[dry-run]${NC} Would dump PostgreSQL '$db_name' to: $dump_file"
		elif [[ "$DOCKER_MODE" == true ]]; then
			local pg_container
			pg_container=$(find_db_container "postgres")
			if [[ -n "$pg_container" ]]; then
				verbose "Using PostgreSQL container: $pg_container"
				_pg_dump_container "$pg_container" "$db_user" "$db_name" "$db_pass" "$dump_file"
			else
				warn "No PostgreSQL container found; attempting pg_dump from host"
				_pg_dump_bare "${db_host%%:*}" "$db_user" "$db_name" "$db_pass" "$dump_file"
			fi
		else
			_pg_dump_bare "${db_host%%:*}" "$db_user" "$db_name" "$db_pass" "$dump_file"
		fi
		success "PostgreSQL dump written to: $dump_file"
		;;

	mysql)
		local dump_file="$EXPORT_DIR/db-dump.sql"
		info "Exporting MySQL/MariaDB database '$db_name'..."
		if [[ "$DRY_RUN" == true ]]; then
			echo -e "  ${YELLOW}[dry-run]${NC} Would dump MySQL '$db_name' to: $dump_file"
		elif [[ "$DOCKER_MODE" == true ]]; then
			local mysql_container
			mysql_container=$(find_db_container "mysql")
			if [[ -n "$mysql_container" ]]; then
				verbose "Using MySQL/MariaDB container: $mysql_container"
				_mysql_dump_container "$mysql_container" "$db_user" "$db_name" "$db_pass" "$dump_file"
			else
				warn "No MySQL/MariaDB container found; attempting mysqldump from host"
				_mysql_dump_bare "${db_host%%:*}" "$db_user" "$db_name" "$db_pass" "$dump_file"
			fi
		else
			_mysql_dump_bare "${db_host%%:*}" "$db_user" "$db_name" "$db_pass" "$dump_file"
		fi
		success "MySQL/MariaDB dump written to: $dump_file"
		;;

	sqlite3)
		local dump_file="$EXPORT_DIR/db-dump.sqlite3"
		local data_dir
		data_dir=$(get_config datadirectory)
		local sqlite_src=""
		for candidate in "$data_dir/nextcloud.db" "$data_dir/owncloud.db"; do
			if [[ -f "$candidate" ]]; then
				sqlite_src="$candidate"
				break
			fi
		done
		if [[ -z "$sqlite_src" ]]; then
			error "Could not find SQLite database file in $data_dir"
			exit 1
		fi
		info "Copying SQLite database from: $sqlite_src"
		runcmd cp "$sqlite_src" "$dump_file"
		success "SQLite database copied to: $dump_file"
		;;

	*)
		error "Unknown database type: $db_type"
		exit 1
		;;
	esac
}

# ── Write manifest ────────────────────────────────────────────────────────────
# Separate function so variable values are passed as jq --arg (safe for any content)
# rather than embedded in a quoted string.
_write_manifest() {
	local outfile="$1"
	# Note: dbpassword is intentionally excluded from the manifest for security.
	# The import script will prompt for it if needed (MySQL cross-DB path only).
	jq -n \
		--arg instanceid "$instance_id" \
		--arg passwordsalt "$password_salt" \
		--arg secret "$secret" \
		--arg data_fingerprint "$data_fingerprint" \
		--arg dbtype "$db_type" \
		--arg version "$version" \
		--arg datadirectory "$data_dir" \
		--arg dbhost "$db_host" \
		--arg dbname "$db_name" \
		--arg dbuser "$db_user" \
		--arg export_timestamp "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
		'{
            instanceid:       $instanceid,
            passwordsalt:     $passwordsalt,
            secret:           $secret,
            data_fingerprint: (if $data_fingerprint == "" then null else $data_fingerprint end),
            dbtype:           $dbtype,
            version:          $version,
            datadirectory:    $datadirectory,
            dbhost:           $dbhost,
            dbname:           $dbname,
            dbuser:           $dbuser,
            export_timestamp: $export_timestamp
        }' >"$outfile"
}

# ── Resolve host path from Docker volume mounts ───────────────────────────────
# Given the container-internal data directory path, finds the corresponding
# host-side path using longest-prefix matching on the container's volume mounts.
# Handles both direct data-dir mounts and parent-directory mounts.
resolve_host_data_path() {
	local container_path="${1%/}" # strip trailing slash before matching

	if [[ "$DOCKER_MODE" != true ]]; then
		echo "$container_path"
		return
	fi

	local mounts_json
	mounts_json=$(docker inspect --format='{{json .Mounts}}' "$CONTAINER" 2>/dev/null) || {
		echo ""
		return
	}

	# Prefer mounts with a non-empty Source (bind mounts, or named volumes that
	# already have Source populated by the daemon).
	local host_path
	host_path=$(echo "$mounts_json" | jq -r --arg cpath "$container_path" '
        map(
            .Destination as $dest | (.Source // "") as $src |
            select(
                ($src | length) > 0 and
                ($cpath == $dest or ($cpath | startswith($dest + "/")))
            )
        )
        | sort_by(.Destination | length) | reverse | first
        | if . then (.Source + ($cpath[(.Destination | length):]))
          else empty end
    ' 2>/dev/null) || true

	if [[ -n "$host_path" ]]; then
		echo "$host_path"
		return
	fi

	# Fallback for named volumes where Source is empty: ask Docker directly.
	local vol_name vol_dest vol_mountpoint
	vol_name=$(echo "$mounts_json" | jq -r --arg cpath "$container_path" '
        map(
            .Destination as $dest |
            select(
                .Type == "volume" and
                ($cpath == $dest or ($cpath | startswith($dest + "/")))
            )
        )
        | sort_by(.Destination | length) | reverse | first
        | .Name // empty
    ' 2>/dev/null) || true

	if [[ -n "$vol_name" ]]; then
		vol_mountpoint=$(docker volume inspect "$vol_name" --format '{{.Mountpoint}}' 2>/dev/null) || true
		vol_dest=$(echo "$mounts_json" | jq -r --arg name "$vol_name" '
            map(select(.Name == $name)) | first | .Destination // empty
        ' 2>/dev/null) || true
		if [[ -n "$vol_mountpoint" && -n "$vol_dest" ]]; then
			echo "${vol_mountpoint}${container_path#"$vol_dest"}"
			return
		fi
	fi

	echo ""
}

# ── Main ──────────────────────────────────────────────────────────────────────
# Declare config variables at script scope so on_exit trap can reference them
instance_id=""
password_salt=""
secret=""
data_fingerprint=""
db_type=""
version=""
data_dir=""
db_host=""
db_name=""
db_user=""
db_pass=""

main() {
	echo ""
	echo -e "${BOLD}Nextcloud Migration - Export Script${NC}"
	echo -e "${BOLD}Run on the OLD HOST${NC}"
	if [[ "$DRY_RUN" == true ]]; then
		echo -e "${YELLOW}DRY-RUN MODE: No changes will be made${NC}"
	fi
	echo ""

	warn "Before proceeding, ensure you have a full backup or VM snapshot of this host."
	warn "Data loss during migration is possible. A snapshot is your safety net."
	echo ""

	check_prerequisites
	runcmd mkdir -p "$EXPORT_DIR"
	detect_environment

	step "Safety checks (OLD HOST)"
	check_encryption
	check_totp

	enable_maintenance

	step "Extracting configuration values (OLD HOST)"

	instance_id=$(get_config instanceid)
	password_salt=$(get_config passwordsalt)
	secret=$(get_config secret)
	data_fingerprint=$(get_config data-fingerprint)
	db_type=$(get_config dbtype)
	version=$(get_config version)
	data_dir=$(get_config datadirectory)
	db_host=$(get_config dbhost)
	db_name=$(get_config dbname)
	db_user=$(get_config dbuser)
	db_pass=$(get_config dbpassword)

	local host_data_dir
	host_data_dir=$(resolve_host_data_path "$data_dir")

	verbose "instanceid:    $instance_id"
	verbose "version:       $version"
	verbose "dbtype:        $db_type"
	verbose "datadirectory: $data_dir"
	verbose "host data dir: ${host_data_dir:-<unresolved>}"

	local manifest="$EXPORT_DIR/manifest.json"
	if [[ "$DRY_RUN" == true ]]; then
		echo -e "  ${YELLOW}[dry-run]${NC} Would write manifest to: $manifest"
	else
		_write_manifest "$manifest"
	fi
	success "Manifest written to: $manifest"

	step "Exporting database (OLD HOST)"
	export_database "$db_type" "$db_host" "$db_name" "$db_user" "$db_pass"

	step "Export complete"
	success "Export bundle ready in: ./$EXPORT_DIR/"
	echo ""
	echo -e "${BOLD}Next steps - run these on the NEW HOST:${NC}"
	echo ""
	echo "  1. Transfer the export bundle:"
	echo "     rsync -avz --progress ./$EXPORT_DIR/ NEW_HOST:~/nc-migration-export/"
	echo ""
	echo "  2. Transfer user files directly to the new data volume location."
	echo "     Check NEXTCLOUD_DATA_VOLUME in nextcloud/.env on the new host for the destination path."
	echo "     Rsync directly to the final destination to avoid storing two copies:"
	echo ""
	if [[ -n "$host_data_dir" ]]; then
		echo "     rsync -avz --progress -t ${host_data_dir}/ NEW_HOST:<NEXTCLOUD_DATA_VOLUME>/"
	else
		warn "Could not resolve host-side path for data directory (container path: $data_dir)."
		warn "Find the host path with: docker inspect $CONTAINER"
		echo "     rsync -avz --progress -t <HOST_DATA_DIR>/ NEW_HOST:<NEXTCLOUD_DATA_VOLUME>/"
	fi
	echo ""
	echo "  3. Once both transfers complete, run on the NEW HOST:"
	echo "     bash nextcloud/migrate/import.sh"
	echo ""
	warn "Keep Nextcloud in maintenance mode until the new server is verified and DNS is switched."
	EXPORT_COMPLETED=true
}

main
