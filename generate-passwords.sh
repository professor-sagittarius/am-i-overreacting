#!/bin/bash
# Replaces all 'changeme' default passwords in .env files with secure random passwords.
# Also copies cross-stack values into backup/.env.

# Update this list when adding a new stack
ENV_FILES="nextcloud/.env gitea/.env vaultwarden/.env backup/.env"
REPLACED=0

for env_file in ${ENV_FILES}; do
  if [ ! -f "${env_file}" ]; then
    echo "Skipping ${env_file} (not found)"
    continue
  fi
  # Read via cat to avoid read/write conflict when sed -i modifies the same file
  while IFS= read -r line; do
    if echo "${line}" | grep -qE '^[A-Za-z_]+=changeme( |#|$)'; then
      key=$(echo "${line}" | cut -d'=' -f1)
      password=$(openssl rand -base64 64 | tr -d '/+=' | head -c 64)
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
  value=$(bash -c "set -a; source '${src_file}'; echo \"\${${src_var}}\"" 2>/dev/null)
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
  copy_to_backup nextcloud/.env POSTGRES_PASSWORD     NEXTCLOUD_DB_PASSWORD
  copy_to_backup nextcloud/.env NEXTCLOUD_APP_VOLUME  NEXTCLOUD_APP_VOLUME
  copy_to_backup nextcloud/.env NEXTCLOUD_DATA_VOLUME NEXTCLOUD_DATA_VOLUME
fi

if [ -f "gitea/.env" ]; then
  copy_to_backup gitea/.env POSTGRES_DB       GITEA_DB
  copy_to_backup gitea/.env POSTGRES_USER     GITEA_DB_USER
  copy_to_backup gitea/.env POSTGRES_PASSWORD GITEA_DB_PASSWORD
  copy_to_backup gitea/.env GITEA_DATA_VOLUME GITEA_DATA_VOLUME
fi

if [ -f "vaultwarden/.env" ]; then
  copy_to_backup vaultwarden/.env VAULTWARDEN_DATA_VOLUME VAULTWARDEN_DATA_VOLUME
fi

if [ "${COPIED}" -gt 0 ]; then
  echo ""
  echo "Copied ${COPIED} cross-stack value(s) into backup/.env."
fi
