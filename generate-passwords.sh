#!/bin/bash
# Replaces all 'changeme' default passwords in .env files with secure random passwords

ENV_FILES="nextcloud/.env gitea/.env"
REPLACED=0

for env_file in ${ENV_FILES}; do
  if [ ! -f "${env_file}" ]; then
    echo "Skipping ${env_file} (not found)"
    continue
  fi
  while IFS= read -r line; do
    if echo "${line}" | grep -q '=changeme'; then
      key=$(echo "${line}" | cut -d'=' -f1)
      password=$(openssl rand -base64 32 | tr -d '/+=' | head -c 32)
      sed -i "s|^${key}=changeme|${key}=${password}|" "${env_file}"
      echo "Generated password for ${key} in ${env_file}"
      REPLACED=$((REPLACED + 1))
    fi
  done < "${env_file}"
done

if [ "${REPLACED}" -gt 0 ]; then
  echo ""
  echo "Replaced ${REPLACED} default password(s). Review your .env files before starting the stacks."
else
  echo "No default passwords found."
fi
