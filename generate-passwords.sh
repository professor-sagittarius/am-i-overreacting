#!/bin/bash
# Replaces all 'changeme' default passwords in .env files with secure random passwords.
# Also copies cross-stack values into backup/.env.

command -v openssl >/dev/null 2>&1 || { echo "Error: openssl is required but not installed."; exit 1; }

# Update this list when adding a new stack
ENV_FILES="nextcloud/.env gitea/.env vaultwarden/.env backup/.env renovate/.env"
REPLACED=0

# Create secrets directories and generate secret files (only if they don't already exist)
# Use umask 077 subshells so files are created with mode 600 from the start,
# not created insecure and then chmod'd
install -d -m 700 nextcloud/secrets gitea/secrets backup/secrets vaultwarden/secrets renovate/secrets

SECRETS=(
  "nextcloud/secrets/postgres_password"
  "nextcloud/secrets/admin_password"
  "nextcloud/secrets/redis_password"
  "gitea/secrets/postgres_password"
  "backup/secrets/borg_passphrase"
  "vaultwarden/secrets/admin_token"
)
for secret in "${SECRETS[@]}"; do
  if [ ! -f "${secret}" ]; then
    (umask 077; openssl rand -base64 64 | tr -d '/+=\n' | head -c 64 > "${secret}")
    echo "Generated secret: ${secret}"
    REPLACED=$((REPLACED + 1))
  fi
done

# redis_password must be readable by www-data (GID 33) inside containers - both
# nextcloud_app (via PHP at runtime) and nextcloud_notify_push read it directly.
# Applied unconditionally so existing files are also fixed on re-run.
chown :33 nextcloud/secrets/redis_password
chmod 640 nextcloud/secrets/redis_password

for env_file in ${ENV_FILES}; do
  if [ ! -f "${env_file}" ]; then
    echo "Skipping ${env_file} (not found)"
    continue
  fi
  # Read via cat to avoid read/write conflict when sed -i modifies the same file
  while IFS= read -r line; do
    if echo "${line}" | grep -qE '^[A-Za-z_]+=changeme( |#|$)'; then
      key=$(echo "${line}" | cut -d'=' -f1)
      password=$(openssl rand -base64 64 | tr -d '/+=\n' | head -c 64)
      sed -i "s|^${key}=changeme|${key}=${password}|" "${env_file}"
      echo "Generated password for ${key} in ${env_file}"
      REPLACED=$((REPLACED + 1))
    fi
  done < <(cat "${env_file}")
done

if [ "${REPLACED}" -gt 0 ]; then
  echo ""
  echo "Replaced ${REPLACED} default password(s). Review your .env files before starting the stacks."
else
  echo "No default passwords found."
fi

# Copy cross-stack values into backup/.env
if [ ! -f "backup/.env" ]; then
  exit 0
fi

COPIED=0

copy_to_backup() {
  local src_file="$1" src_var="$2" dest_var="$3"
  local value
  value=$(grep -m1 "^${src_var}=" "${src_file}" 2>/dev/null | cut -d'=' -f2- || true)
  if [ -n "${value}" ]; then
    if grep -q "^${dest_var}=" backup/.env; then
      sed -i "s|^${dest_var}=.*|${dest_var}=${value}|" backup/.env
      COPIED=$((COPIED + 1))
    else
      echo "Warning: ${dest_var} key not found in backup/.env - skipping"
    fi
  else
    echo "Warning: ${src_var} not set in ${src_file} - ${dest_var} in backup/.env left empty"
  fi
}

if [ -f "nextcloud/.env" ]; then
  copy_to_backup nextcloud/.env POSTGRES_DB           NEXTCLOUD_DB
  copy_to_backup nextcloud/.env POSTGRES_USER         NEXTCLOUD_DB_USER
  copy_to_backup nextcloud/.env NEXTCLOUD_APP_VOLUME  NEXTCLOUD_APP_VOLUME
  copy_to_backup nextcloud/.env NEXTCLOUD_DATA_VOLUME NEXTCLOUD_DATA_VOLUME
fi

if [ -f "gitea/.env" ]; then
  copy_to_backup gitea/.env POSTGRES_DB       GITEA_DB
  copy_to_backup gitea/.env POSTGRES_USER     GITEA_DB_USER
  copy_to_backup gitea/.env GITEA_DATA_VOLUME GITEA_DATA_VOLUME
fi

if [ -f "vaultwarden/.env" ]; then
  copy_to_backup vaultwarden/.env VAULTWARDEN_DATA_VOLUME VAULTWARDEN_DATA_VOLUME
fi

# Generate ~/.pgpass for borgmatic from postgres secret files
if [ -f "backup/.env" ] && [ -f "nextcloud/secrets/postgres_password" ] && [ -f "gitea/secrets/postgres_password" ]; then
  (umask 077; printf "nextcloud_postgres:5432:*:*:%s\n" "$(cat nextcloud/secrets/postgres_password)" > backup/secrets/pgpass \
    && printf "gitea_postgres:5432:*:*:%s\n" "$(cat gitea/secrets/postgres_password)" >> backup/secrets/pgpass)
  echo "Generated backup/secrets/pgpass"
  COPIED=$((COPIED + 1))
fi

if [ "${COPIED}" -gt 0 ]; then
  echo ""
  echo "Copied ${COPIED} cross-stack value(s) into backup/.env."
fi

# Auto-calculate proportional resource limits from host RAM (only if not already set)
if command -v free >/dev/null 2>&1; then
  TOTAL_MB=$(free -m | awk '/^Mem:/{print $2}')

  # Returns the larger of (TOTAL_MB * numerator / denominator) and floor_mb, formatted as Xg or Xm
  calc_mem() {
    local num="$1" den="$2" floor_mb="$3"
    local val=$(( TOTAL_MB * num / den ))
    [ "$val" -lt "$floor_mb" ] && val="$floor_mb"
    if [ $(( val % 1024 )) -eq 0 ] && [ "$val" -ge 1024 ]; then
      echo "$((val / 1024))g"
    else
      echo "${val}m"
    fi
  }

  # Write limit to .env file only if key is absent or empty
  set_if_absent() {
    local env_file="$1" key="$2" value="$3"
    [ -f "$env_file" ] || return
    if ! grep -q "^${key}=" "$env_file"; then
      [ -n "$(tail -c1 "$env_file")" ] && printf '\n' >> "$env_file"
      echo "${key}=${value}" >> "$env_file"
    fi
  }

  # nextcloud limits
  set_if_absent nextcloud/.env NEXTCLOUD_APP_MEMORY_LIMIT          "$(calc_mem 1 4  2048)"
  set_if_absent nextcloud/.env NEXTCLOUD_POSTGRES_MEMORY_LIMIT     "$(calc_mem 3 25 1024)"
  set_if_absent nextcloud/.env NEXTCLOUD_REDIS_MEMORY_LIMIT        "$(calc_mem 3 100 256)"
  set_if_absent nextcloud/.env NEXTCLOUD_ELASTICSEARCH_MEMORY_LIMIT "$(calc_mem 3 25 1024)"
  set_if_absent nextcloud/.env NEXTCLOUD_CLAMAV_MEMORY_LIMIT       "$(calc_mem 1 5  3072)"
  set_if_absent nextcloud/.env NEXTCLOUD_IMAGINARY_MEMORY_LIMIT    "$(calc_mem 3 50  512)"
  set_if_absent nextcloud/.env NEXTCLOUD_WHITEBOARD_MEMORY_LIMIT   "$(calc_mem 3 100 256)"
  set_if_absent nextcloud/.env NEXTCLOUD_HARP_MEMORY_LIMIT         "$(calc_mem 3 50  512)"
  set_if_absent nextcloud/.env NEXTCLOUD_NOTIFY_PUSH_MEMORY_LIMIT  "$(calc_mem 1 50  256)"

  # gitea limits
  set_if_absent gitea/.env GITEA_APP_MEMORY_LIMIT      "$(calc_mem 3 50  512)"
  set_if_absent gitea/.env GITEA_POSTGRES_MEMORY_LIMIT "$(calc_mem 3 25 1024)"

  # vaultwarden limits
  set_if_absent vaultwarden/.env VAULTWARDEN_MEMORY_LIMIT "$(calc_mem 3 100 256)"

  # backup limits
  set_if_absent backup/.env BORGMATIC_MEMORY_LIMIT "$(calc_mem 3 50 512)"

  # renovate limits
  set_if_absent renovate/.env RENOVATE_MEMORY_LIMIT "$(calc_mem 3 50 512)"

  # reverse-proxy limits
  set_if_absent reverse-proxy/.env NPM_MEMORY_LIMIT         "$(calc_mem 3 100 256)"
  set_if_absent reverse-proxy/.env CLOUDFLARED_MEMORY_LIMIT "$(calc_mem 1 100 128)"

  echo "Resource limits written based on ${TOTAL_MB}MB total host RAM."
fi
