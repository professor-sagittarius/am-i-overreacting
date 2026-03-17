# am-i-overreacting

Docker Compose setup for Nextcloud, Forgejo, Vaultwarden, and Uptime Kuma via Nginx Proxy Manager and Cloudflare Tunnel.

## Architecture

### Traffic Flow

```
Internet -> Cloudflare (WAF/DDoS) -> cloudflared
                                          |  tunnel_network
                                    nginx-proxy-manager --> nextcloud_app     (nextcloud_proxy_network)
                                                        --> forgejo_app       (forgejo_proxy_network)
                                                        --> vaultwarden       (vaultwarden_proxy_network)
                                                        --> uptime_kuma       (uptime_kuma_proxy_network)

LAN direct (no Cloudflare):
  HOST_LAN_IP:8888 -> nextcloud_app
  HOST_LAN_IP:8780 -> nextcloud_harp (ExApps proxy)
  HOST_LAN_IP:3000 -> forgejo_app
  HOST_LAN_IP:2222 -> forgejo_app (SSH)
  HOST_LAN_IP:81   -> nginx-proxy-manager (admin)
```

### Networks

Each externally-facing stack has its own isolated proxy network. NPM joins all of them. A compromised service cannot reach other services via the proxy layer.

| Network | Purpose | Services |
|---------|---------|---------|
| `tunnel_network` | cloudflared ↔ NPM only | cloudflared, nginx-proxy-manager |
| `nextcloud_proxy_network` | NPM ↔ Nextcloud | nginx-proxy-manager, nextcloud_app, nextcloud_notify_push, nextcloud_whiteboard* |
| `nextcloud_network` | Nextcloud internal | nextcloud_app, nextcloud_postgres, nextcloud_redis, nextcloud_notify_push, nextcloud_imaginary*, nextcloud_whiteboard*, nextcloud_elasticsearch*, nextcloud_clamav*, nextcloud_harp* |
| `exapps_network` | HaRP ↔ ExApp containers | nextcloud_harp*, HaRP-managed ExApp containers |
| `forgejo_proxy_network` | NPM ↔ Forgejo | nginx-proxy-manager, forgejo_app |
| `forgejo_network` | Forgejo internal | forgejo_app, forgejo_postgres |
| `vaultwarden_proxy_network` | NPM ↔ Vaultwarden | nginx-proxy-manager, vaultwarden |
| `uptime_kuma_proxy_network` | NPM ↔ Uptime Kuma | nginx-proxy-manager, uptime_kuma |

\* Profile-conditional services (enabled via `COMPOSE_PROFILES` in `nextcloud/.env`)

## Services

### reverse-proxy/docker-compose.yaml
- **nginx-proxy-manager** - Reverse proxy with Let's Encrypt SSL
- **cloudflared** - Cloudflare Tunnel for external access

### nextcloud/docker-compose.yaml
- **nextcloud_app** - Main Nextcloud instance
- **nextcloud_postgres** - PostgreSQL database
- **nextcloud_redis** - Redis cache
- **nextcloud_notify_push** - Push notifications (High Performance Backend for files)
- **nextcloud_imaginary** *(profile: imaginary)* - Server-side image preview generation
- **nextcloud_whiteboard** *(profile: whiteboard)* - Collaborative whiteboard WebSocket server
- **nextcloud_elasticsearch** *(profile: fulltextsearch)* - Elasticsearch for full text search
- **nextcloud_clamav** *(profile: clamav)* - ClamAV antivirus scanner
- **nextcloud_harp** *(profile: harp)* - HaRP reverse proxy for ExApps (AppAPI)

### forgejo/docker-compose.yaml
- **forgejo_app** - Forgejo git server
- **forgejo_postgres** - PostgreSQL database

### vaultwarden/docker-compose.yaml
- **vaultwarden** - Bitwarden-compatible password manager

### uptime-kuma/docker-compose.yaml
- **uptime_kuma** - Uptime monitoring dashboard

### backup/docker-compose.yaml
- **borgmatic** - Encrypted backups to Borgbase via borgbackup (run as a one-shot container by `backup/backup.sh`)

## Prerequisites

Before starting, ensure the following are installed and available:
- **Docker Engine 24+**
- **Docker Compose V2.20+**
- **sqlite3** - Required for Vaultwarden backup hooks in borgmatic
- **openssl** - Required by `generate-passwords.sh`

Verify your versions:
```bash
docker --version
docker compose version
sqlite3 --version
openssl version
```

## Setup

Complete the **Prerequisites** section first - it is required for all stacks. After that, follow only the sections for the services you want to deploy. Most stacks are independent: you can run only Nextcloud and the reverse proxy, then add Forgejo or Vaultwarden later without redeploying anything.

### Prerequisites (required for all stacks)

#### 1. System Preparation

##### vm.max_map_count for Elasticsearch

If using the `fulltextsearch` profile (Elasticsearch), increase the kernel parameter:

```bash
# Set for current session
sudo sysctl -w vm.max_map_count=262144

# Make persistent across reboots
echo 'vm.max_map_count=262144' | sudo tee -a /etc/sysctl.conf
```

#### 2. Configure Docker log rotation

Set default log rotation for all containers by copying the included `daemon.json` to your Docker daemon configuration:

```bash
if [ ! -f /etc/docker/daemon.json ]; then
    sudo cp daemon.json /etc/docker/daemon.json && sudo systemctl restart docker
else
    echo "File already exists - merge log-driver and log-opts keys from daemon.json manually, then: sudo systemctl restart docker"
fi
```

If the file already exists, nothing is overwritten. Merge the `log-driver` and `log-opts` keys from `daemon.json` into your existing file manually, then restart Docker.

This limits every container to 10MB x 3 log files (30MB max per container). This is especially important because HaRP-spawned ExApp containers are not managed by docker-compose and would otherwise have no log limits.

#### 3. Create a Cloudflare Tunnel

1. Go to [Cloudflare Zero Trust](https://one.dash.cloudflare.com/) → **Networks → Connectors**
2. Create a new tunnel and copy the tunnel token
3. Save the tunnel token securely - you'll need it for `reverse-proxy/.env` in step 4

#### 4. Configure environment files

Copy the example environment files and edit the `.env` files with your values:

```bash
cp reverse-proxy/example.env reverse-proxy/.env
cp nextcloud/example.env nextcloud/.env
cp forgejo/example.env forgejo/.env
cp vaultwarden/example.env vaultwarden/.env
cp uptime-kuma/example.env uptime-kuma/.env
cp backup/example.env backup/.env
chmod 600 reverse-proxy/.env nextcloud/.env forgejo/.env vaultwarden/.env uptime-kuma/.env backup/.env
bash generate-passwords.sh
```

The `generate-passwords.sh` script creates `nextcloud/secrets/`, `forgejo/secrets/`, and `backup/secrets/` directories with generated credentials (mode 600), and replaces remaining `=changeme` placeholder values in `.env` files with secure random values.

> **backup/.env**: `generate-passwords.sh` automatically copies volume paths and database config (names and usernames) from the other stacks into `backup/.env` - no manual copying needed. The Borg passphrase is generated in `backup/secrets/borg_passphrase` - store this securely in Vaultwarden once it is set up (step 13), or in another secure location in the meantime. Loss means backups are irrecoverable.

**reverse-proxy/.env**
- `CLOUDFLARE_TUNNEL_TOKEN` - Tunnel token from the previous step
- `DOCKER_VOLUME_DIR` - Base path for NPM data

**nextcloud/.env**
- `NEXTCLOUD_TRUSTED_DOMAINS` - Space-separated list of domains (e.g., `cloud.example.com nextcloud_app`). Re-applied on every startup via `before-startup.sh` — updating this in `.env` and restarting is sufficient to add or remove trusted domains.
- `NEXTCLOUD_PRIMARY_DOMAIN` - Primary domain used for `overwrite.cli.url` (must also be in `NEXTCLOUD_TRUSTED_DOMAINS`). Re-applied on every startup via `before-startup.sh` — updating it in `.env` and restarting is sufficient to change the primary domain.
- `NEXTCLOUD_ADMIN_USER` - Admin username (password is in `nextcloud/secrets/admin_password`)
- `NEXTCLOUD_PROXY_NETWORK_SUBNET` - Subnet for the nextcloud_proxy_network (default: 172.28.0.0/24)
- `NEXTCLOUD_INTERNAL_NETWORK_SUBNET` - Subnet for nextcloud_network internal bridge (default: 172.29.0.0/24)
- `COMPOSE_PROFILES` - Comma-separated list of optional service profiles (`harp,imaginary,whiteboard,clamav,fulltextsearch`); `HP_SHARED_KEY` is only needed when the `harp` profile is enabled
- `WHITEBOARD_PUBLIC_URL` - Path on the Nextcloud domain for the whiteboard WebSocket server, e.g. `https://cloud.example.com/whiteboard` (needed if `whiteboard` profile is enabled)
- `HP_SHARED_KEY` - HaRP shared key (set by `generate-passwords.sh`; only needed when the `harp` profile is enabled)
- `DOCKER_VOLUME_DIR` - Base path for Nextcloud persistent files

**vaultwarden/.env**
- `VAULTWARDEN_DOMAIN` - Public URL for Vaultwarden (e.g., `https://vault.example.com`)
- `VAULTWARDEN_ADMIN_TOKEN` - Admin panel token (set by `generate-passwords.sh`; stored in `vaultwarden/secrets/admin_token`; disable after setup by emptying the secret file)

**backup/.env**
- `BORGBASE_REPO` - Borgbase SSH repository URL (e.g., `ssh://user@xxx.repo.borgbase.com/./repo`)
- Borg passphrase - Generated in `backup/secrets/borg_passphrase` by `generate-passwords.sh`; store in Vaultwarden or another secure location separately from the backup destination - loss means backups are irrecoverable
- `SSH_KEY_PATH` - Path to the Borgbase SSH private key on the host (default: `/root/.ssh/borgbase_ed25519`)
- Nextcloud, Forgejo, and Vaultwarden volume paths and DB credentials - populated automatically by `generate-passwords.sh`

#### 5. Create Docker networks

```bash
source nextcloud/.env
docker network create --subnet=${NEXTCLOUD_PROXY_NETWORK_SUBNET} nextcloud_proxy_network
docker network create forgejo_proxy_network
docker network create vaultwarden_proxy_network
docker network create uptime_kuma_proxy_network
```

The Nextcloud proxy network uses a fixed subnet so `TRUSTED_PROXIES` can be scoped to only NPM. The subnet is `NEXTCLOUD_PROXY_NETWORK_SUBNET` in `nextcloud/.env`.

The `tunnel_network` (used between cloudflared and NPM) is managed by the reverse-proxy stack and created automatically.

#### 6. Start the reverse-proxy stack

```bash
docker compose -f reverse-proxy/docker-compose.yaml up -d
```

#### 7. Configure NPM and Cloudflare

**Verification checkpoint:** After starting the reverse-proxy stack, verify NPM loads at `http://<HOST_LAN_IP>:81`

1. Access the NPM admin panel at `http://<server-ip>:81`
2. Generate an [Origin Certificate](https://dash.cloudflare.com/?to=/:account/:zone/ssl-tls/origin) under **SSL/TLS → Origin Server → Create Certificate** and install it in NPM as a custom SSL certificate for your domain
3. Add proxy hosts in NPM pointing to each service:
   - Nextcloud domain → `nextcloud_app:80`
   - Forgejo domain → `forgejo_app:3000`
   - Vaultwarden domain → `vaultwarden:80`
   - Uptime Kuma domain → `uptime_kuma:3001`
4. Paste the contents of `reverse-proxy/nginx.config` into the **Advanced** tab of the Nextcloud proxy host - this configures security headers, large file uploads, and WebSocket proxies for notify_push and whiteboard (at `/push/` and `/whiteboard/` respectively)
5. In the Cloudflare Tunnel config, add public hostnames pointing to `https://nginx-proxy-manager:443` for each domain

---

### Nextcloud Stack

#### 8. Prepare Nextcloud volumes

Create the data directory with correct ownership for `www-data` (UID 33). `before-startup.sh` runs on every container startup (including the first, immediately after installation) and is bind-mounted directly from the repo - no copying needed. `chgrp 33` sets the group to `www-data` so the container can execute the script; git tracks it as executable (`755`), which with a `0027` umask produces `750` on checkout, giving the group read and execute access:

```bash
source nextcloud/.env
sudo mkdir -p ${NEXTCLOUD_DATA_VOLUME}
sudo chown 33:33 ${NEXTCLOUD_DATA_VOLUME}
sudo mkdir -p ${NEXTCLOUD_REDIS_VOLUME}
sudo mkdir -p ${ELASTICSEARCH_DATA_VOLUME}
sudo chown 1000:1000 ${ELASTICSEARCH_DATA_VOLUME}
sudo chgrp -R 33 nextcloud/hooks/
```

#### 9. Set up cron

Add a crontab entry on the host to run Nextcloud's background jobs every 5 minutes:

```bash
(sudo crontab -l 2>/dev/null; echo "*/5 * * * * docker exec -u www-data nextcloud_app php -f /var/www/html/cron.php") | sudo crontab -
```

This is done before starting the container by design - it ensures cron is active the moment Nextcloud comes up, with no manual follow-up required. The `docker exec` command will fail silently until `nextcloud_app` is running, which is expected and harmless; cron retries every 5 minutes.

#### 10. Start the Nextcloud stack

```bash
docker compose -f nextcloud/docker-compose.yaml up -d
```

> **HaRP** *(if harp profile is enabled)*: The HaRP container mounts `/var/run/docker.sock` to manage ExApp containers, giving it full Docker daemon access. Treat it as a high-trust component and ensure the host is otherwise secured.

> **ClamAV** *(if clamav profile is enabled)*: On first start, `nextcloud_clamav` downloads ~300MB of virus definitions. `docker ps` will show `(healthy)` once definitions are downloaded and clamd is ready - wait for this before uploading files.

**Verification checkpoints:**
- Nextcloud initialization: Check `docker logs nextcloud_app` for `Nextcloud is now configured`
- Verify login works at your configured Nextcloud domain

#### 11. Configure notify_push

The notify_push app is installed automatically by `before-startup.sh` on first startup (if included in `NEXTCLOUD_APPS`). Run the setup command to complete the configuration:

```bash
docker exec -u www-data nextcloud_app php occ notify_push:setup https://cloud.yourdomain.com/push
```

**Verification checkpoint:** notify_push is running on TCP port 7867 (check with `docker ps`)

#### 12. Configure full text search indexing

If the `fulltextsearch` profile is enabled, trigger the initial index after all containers are healthy:

```bash
docker exec -u www-data nextcloud_app php occ fulltextsearch:index
```

This may take some time depending on the number of files.

#### 13. Verify HaRP/AppAPI *(skip if harp profile is not enabled)*

The AppAPI deploy daemon is registered automatically by `before-startup.sh` on first startup using `HP_SHARED_KEY`. Verify it in **Administration Settings → AppAPI** - you should see a "Harp Proxy (Docker)" daemon registered.

---

### Adding or Removing Optional Services After Initial Setup

To enable a profile that was not active on first install (e.g., adding `clamav` later):

1. Update `COMPOSE_PROFILES` in `nextcloud/.env`
2. Restart the stack:
   ```bash
   docker compose -f nextcloud/docker-compose.yaml up -d
   ```

`before-startup.sh` will install and configure newly enabled profiles, and disable apps for removed profiles, on the next startup.

---

### Migrating an Existing Nextcloud Instance

To migrate an existing Nextcloud instance (including Nextcloud AIO) to this stack, use the
migration toolkit in `nextcloud/migrate/`. See `nextcloud/migrate/README.md` for the full guide.

The migration preserves all user accounts, files, shares, and app data. Two requirements
must be met before running the migration:

- **Matching versions** - the Nextcloud version on the old instance must exactly match the
  image tag in `nextcloud/docker-compose.yaml`
- **Matching data directory path** - `NEXTCLOUD_DATA_DIR` in `nextcloud/.env` must match
  the old instance's `datadirectory`. The default (`/mnt/ncdata`) matches Nextcloud AIO.
  The import script checks this before making any changes.

---

### Forgejo Stack

```bash
docker compose -f forgejo/docker-compose.yaml up -d
```

**Verification checkpoint:** Verify Forgejo at `http://<HOST_LAN_IP>:3000`

> **Forgejo SSH:** Git over SSH is available on port 2222. Clone with `git clone ssh://git@<server-ip>:2222/<user>/<repo>.git`. This port does not go through Cloudflare Tunnel - ensure it is reachable directly from your clients (configure router port forwarding if access from outside the LAN is needed).

---

### Forgejo-Nextcloud OAuth2

Lets users sign into Forgejo using their Nextcloud credentials. Both stacks must be running and healthy before completing this.

**1. Register the OAuth2 client in Nextcloud**

Go to **Nextcloud Settings → Security → OAuth 2.0 clients** and click **Add client**:

| Field | Value |
|-------|-------|
| Name | `Forgejo` |
| Redirect URI | `https://<your-forgejo-domain>/user/oauth2/nextcloud/callback` |

Copy the generated **client ID** and **client secret** - they are only shown once.

**2. Add the authentication source in Forgejo**

Go to **Forgejo Site Administration → Authentication Sources** and click **Add Authentication Source**:

| Field | Value |
|-------|-------|
| Authentication Type | OAuth2 |
| Authentication Name | `nextcloud` (must match the slug in the redirect URI above) |
| OAuth2 Provider | Nextcloud |
| Client ID | from step 1 |
| Client Secret | from step 1 |
| Nextcloud URL | `https://<your-nextcloud-domain>` |

Save, then verify by signing out of Forgejo and clicking **Sign in with Nextcloud** on the login page.

---

### Renovate (Dependency Updates)

Renovate opens pull requests on Forgejo when Docker image versions are outdated. It runs weekly via cron.

1. Create a dedicated bot account on your Forgejo instance (e.g. `renovate-bot`)
2. Generate a Forgejo personal access token for that account with **Contents: Read and Write** permissions under the repository scope
3. Populate the token file:
   ```bash
   echo -n "<token>" > renovate/secrets/forgejo_token
   chmod 600 renovate/secrets/forgejo_token
   ```
4. Configure `renovate/.env` from `renovate/example.env`:
   ```bash
   cp renovate/example.env renovate/.env
   chmod 600 renovate/.env
   ```
   Set `FORGEJO_URL` to your Forgejo instance API URL (e.g. `http://192.168.1.100:3000/api/v1`) and `RENOVATE_REPOSITORIES` to your repo (e.g. `renovate-bot/am-i-overreacting`).
5. Add a weekly cron entry (as root):
   ```bash
   (sudo crontab -l 2>/dev/null; echo "0 3 * * 0 docker compose -f $(realpath renovate/docker-compose.yaml) --env-file $(realpath renovate/.env) run --rm renovate 2>&1 | logger -t renovate") | sudo crontab -
   ```

**Verification:** Run Renovate in dry-run mode to confirm it can reach Forgejo without opening any PRs:
```bash
docker compose -f renovate/docker-compose.yaml --env-file renovate/.env run --rm -e RENOVATE_DRY_RUN=lookup renovate
```
Expected: Renovate logs showing repository discovery, no PRs created.

---

### Vaultwarden Stack

```bash
docker compose -f vaultwarden/docker-compose.yaml up -d
```

After initial Vaultwarden setup, disable the admin panel by removing or emptying `vaultwarden/secrets/admin_token` and restarting:

```bash
docker compose -f vaultwarden/docker-compose.yaml up -d --force-recreate
```

**Verification checkpoint:** Verify Vaultwarden at your configured domain/alive

---

### Uptime Kuma Stack

```bash
docker compose -f uptime-kuma/docker-compose.yaml up -d
```

Access Uptime Kuma at its domain to create the admin account on first login.

Run `./preflight-check.sh` before moving to backups.

---

### Backups

```bash
# Generate SSH key for Borgbase (as root, since borgmatic runs as root)
source backup/.env && sudo ssh-keygen -t ed25519 -f ${SSH_KEY_PATH} -N ""

# Add the contents of ${SSH_KEY_PATH}.pub to your Borgbase repository's authorized keys

# Initialize the Borg repository (required before first backup)
# Note: the first 'borgmatic' is the Docker Compose service name; the second is the binary inside the container
docker compose -f backup/docker-compose.yaml run --rm borgmatic borgmatic init --encryption repokey-blake2

# Schedule the backup script in cron
(sudo crontab -l 2>/dev/null; echo "0 2 * * * $(realpath backup/backup.sh) 2>&1 | logger -t borgmatic") | sudo crontab -
```

Backups run daily at 2am, retaining 7 daily, 4 weekly, and 3 monthly snapshots. `backup/backup.sh` automatically enables Nextcloud maintenance mode before each backup and disables it after - even on failure. View backup logs with `journalctl -t borgmatic`.

#### Backup Verification

List all archives and verify backup integrity:

```bash
# List all archives
docker compose -f backup/docker-compose.yaml run --rm borgmatic borgmatic list

# Verify backup integrity
docker compose -f backup/docker-compose.yaml run --rm borgmatic borgmatic check
```

## Restore Procedure

If you need to restore from backups:

1. **List available archives:**
   ```bash
   docker compose -f backup/docker-compose.yaml run --rm borgmatic borgmatic list
   ```

2. **Extract files to a temporary directory:**
   ```bash
   docker compose -f backup/docker-compose.yaml run --rm borgmatic borgmatic extract --archive latest --destination /tmp/restore
   ```

3. **Restore PostgreSQL dumps** (for Nextcloud and Forgejo databases):
   - Locate the dump files in `/tmp/restore/` (typically in `var/backups/`)
   - Stop the affected containers: `docker compose -f nextcloud/docker-compose.yaml down` and/or `docker compose -f forgejo/docker-compose.yaml down`
   - Restore using `pg_restore` or `psql` with the appropriate credentials from your `.env` files

4. **Restore volumes** by stopping containers and copying data back from `/tmp/restore/`:
   - Copy Nextcloud data back to the path in `NEXTCLOUD_DATA_VOLUME`
   - Copy Vaultwarden data back to the vaultwarden volume path
   - Ensure correct ownership: `sudo chown 33:33` for Nextcloud, `sudo chown 100:101` for Vaultwarden

5. **Restore secrets** - copy secret files from your secure external backup (Vaultwarden or other secure storage) into the correct locations:
   - `nextcloud/secrets/` - postgres_password, admin_password, redis_password
   - `forgejo/secrets/` - postgres_password
   - `backup/secrets/` - borg_passphrase
   - `vaultwarden/secrets/` - admin_token

   **Do NOT run `generate-passwords.sh`** - this generates new credentials that will not match the restored database contents, causing containers to fail to connect.

   If a secret file was lost, the Nextcloud database password can be recovered from `config/config.php` in the restored app volume at `NEXTCLOUD_APP_VOLUME/config/config.php`.

6. **Start stacks in order:**
   ```bash
   docker compose -f reverse-proxy/docker-compose.yaml up -d
   docker compose -f vaultwarden/docker-compose.yaml up -d
   docker compose -f nextcloud/docker-compose.yaml up -d
   docker compose -f forgejo/docker-compose.yaml up -d
   ```

7. **Post-restore verification:**
   - Check all health endpoints are responding
   - Verify login on Nextcloud and Forgejo
   - Run `./preflight-check.sh` to verify no placeholders remain

### Restoring a single stack

To restore only one service (e.g., Nextcloud but not Forgejo):
1. Stop only the affected stack: `docker compose -f nextcloud/docker-compose.yaml down`
2. Extract only the relevant archive paths (use `--path` flag with borgmatic extract)
3. Restore secrets for that stack only
4. Restart the stack - the other stacks continue running normally

## Monitoring with Uptime Kuma

Run the provisioning script to create all monitors automatically:

```bash
cd uptime-kuma
pip install -r requirements.txt
python provision_monitors.py
```

The script connects to Uptime Kuma, creates monitors for all services below, and prints push URLs to paste into your Ansible playbooks and `backup/.env`.

| Service | Monitor Type | Endpoint |
|---------|--------------|----------|
| **Nextcloud** | HTTP(S) | `/status.php` |
| **Forgejo** | HTTP(S) | `/api/v1/version` |
| **Vaultwarden** | HTTP(S) | `/alive` |
| **notify_push** | TCP | Port 7867 |
| **Borgmatic** | Push | Paste `HEALTHCHECK_PING_URL` into `backup/.env` |
| **Main server** | Ping + SSH TCP | Host LAN IP |
| **Unattended upgrades** | Push | Installed via `uptime-kuma-hooks-playbook.yml` |
| **Reboot required** | Push | Installed via `uptime-kuma-hooks-playbook.yml` |
| **Disk space** | Push | Installed via `uptime-kuma-hooks-playbook.yml` |

After pasting the push URLs from the script output into `ansible-webserver-hardening/uptime-kuma-hooks-playbook.yml`, run:

```bash
cd ../ansible-webserver-hardening
ansible-playbook -i your-inventory uptime-kuma-hooks-playbook.yml
```

For half-price-books monitors, select that option when prompted by the script, then paste the HPB block into `uptime-kuma-hooks-hpb-playbook.yml` and run it against the HPB server.

## Disk Space & Performance

### Expected Growth

- **PostgreSQL WAL (write-ahead log)** can grow over time; tune `max_wal_size` in postgres config if backups lag
- Monitor disk space: `df -h`
- Set up disk space alerts in Uptime Kuma for early warning

### Tuning

- Monitor disk usage regularly: `docker exec nextcloud_postgres du -sh /var/lib/postgresql/data`
- Archive old Nextcloud versions to reduce database size (in Nextcloud admin settings)
- Monitor Redis memory: `docker exec nextcloud_redis redis-cli info memory`

**Memory limits:** When a container exceeds its memory limit, Docker's OOM killer terminates it and `restart: unless-stopped` restarts it. For stateless services (imaginary, notify_push) this is harmless. For stateful services (postgres, redis), repeated OOM kills add restart latency; Redis AOF persistence (already enabled) prevents data loss. Monitor actual usage with `docker stats` after the stack has been running a few days and tune limits in your `.env` files accordingly.

## Secret Rotation

### Rotating Database Passwords

> **Important:** PostgreSQL only reads `POSTGRES_PASSWORD_FILE` during initial database creation. Updating the secret file and recreating the container alone will **not** change the password inside the database - you must update the password inside the running database first, or the container will fail to connect after restart.

**Nextcloud:**

1. Generate a new password:
   ```bash
   NEW_PASS=$(openssl rand -base64 32 | tr -d '/+=')
   ```

2. Apply the new password inside the running database:
   ```bash
   source nextcloud/.env
   docker exec -i nextcloud_postgres psql -U ${POSTGRES_USER} \
     -c "ALTER USER ${POSTGRES_USER} PASSWORD '${NEW_PASS}';"
   ```

3. Update the secret file:
   ```bash
   echo -n "${NEW_PASS}" | sudo tee nextcloud/secrets/postgres_password > /dev/null
   sudo chmod 600 nextcloud/secrets/postgres_password
   ```

4. Recreate the affected containers to pick up the new secret:
   ```bash
   docker compose -f nextcloud/docker-compose.yaml up -d --force-recreate nextcloud_postgres nextcloud_app
   ```

5. Run `./preflight-check.sh` and verify Nextcloud logs show no authentication errors.

**Forgejo:** Follow the same process - alter the user inside `forgejo_postgres` first (`docker exec -i forgejo_postgres psql -U $POSTGRES_USER -c "ALTER USER ..."`), then update `forgejo/secrets/postgres_password` and recreate both `forgejo_postgres` and `forgejo_app`.

### Rotating Redis Password

1. Update `nextcloud/secrets/redis_password`
2. Restart containers:
   ```bash
   docker compose -f nextcloud/docker-compose.yaml up -d --force-recreate nextcloud_redis nextcloud_app
   ```

> **Note on persistence:** Redis AOF persistence stores data but not authentication credentials. When the container restarts with a new password, it loads the existing data from the AOF file and immediately accepts connections with the new password. Nextcloud sessions survive the restart intact.

### Rotating Borg Passphrase

Only do this if you have access to the existing repository:

```bash
docker compose -f backup/docker-compose.yaml run --rm borgmatic borgmatic key change-passphrase
```

Update `backup/secrets/borg_passphrase` with the new passphrase afterward.

### Rotating Vaultwarden Admin Token

1. Replace the contents of `vaultwarden/secrets/admin_token` with a new secure token
2. Restart Vaultwarden:
   ```bash
   docker compose -f vaultwarden/docker-compose.yaml up -d --force-recreate
   ```

### Post-Rotation Verification

After rotating any secrets, always run:

```bash
./preflight-check.sh
```

Then verify service connectivity: check Nextcloud logs for database errors, verify login works, and confirm any rotated service is responding normally.

## Ports

| Port | Service | Access |
|------|---------|--------|
| 81 | NPM Admin | LAN only |
| 8888 | Nextcloud | LAN direct access |
| 8780 | HaRP ExApps | LAN direct access |
| 8782 | HaRP FRP | External Docker engines |
| 3000 | Forgejo | LAN direct access |
| 2222 | Forgejo SSH | Git over SSH |

External traffic flows through Cloudflare Tunnel, so NPM doesn't need ports 80/443 exposed.

## Testing

The test suite uses [bats-core](https://github.com/bats-core/bats-core) and is split into three tiers:

| Tier | What it tests | Requires Docker | Time |
|------|--------------|-----------------|------|
| Tier 1 | shellcheck, shfmt, compose config validation, script flags, example.env completeness | No | ~5s |
| Tier 2 | Each stack starts and passes its healthcheck | Yes | ~20 min |
| Tier 3 | Full AIO-to-new-stack migration end-to-end | Yes | ~15 min |

Forgejo Actions runs tier 1 automatically on every push. Tier 2 and 3 are local only.

### Running tests

Initialize submodules first (bats-core, bats-support, bats-assert):
```bash
git submodule update --init --recursive
```

Run a specific tier:
```bash
bash tests/run-tests.sh tier1   # static analysis - no Docker required
bash tests/run-tests.sh tier2   # stack health - requires Docker
bash tests/run-tests.sh tier3   # migration e2e - requires Docker, ~15 min
bash tests/run-tests.sh all     # all three tiers
```

Tier 3 keeps all test credentials in `tests/tmp/` (created and removed by the test). It does not write to `nextcloud/.env` or `nextcloud/secrets/`.

**Tier 2 and 3 must not be run on a production machine.** They start containers using the same names as the production stacks (`nextcloud_app`, `forgejo_app`, etc.), tear down stacks with `docker compose down -v` (which deletes volumes), and bind the same ports. `run-tests.sh` prompts for confirmation before running either tier.

### Testing Limitations

The test suite does not currently cover:

- **Large database migrations**: Performance testing with multi-gigabyte databases
- **Encryption-enabled migrations**: The export script blocks migration when server-side encryption is enabled (you must follow Nextcloud's encryption migration guide first)
- **Concurrent access**: Behavior when users attempt to connect during migration
- **Partial migration recovery**: What happens if import fails mid-way through

For these scenarios, test manually in a staging environment before production migration.

## Notes

- **Switching Nextcloud domains** (e.g., between staging and production): `NEXTCLOUD_PRIMARY_DOMAIN` and `NEXTCLOUD_TRUSTED_DOMAINS` are both re-applied on every startup via `before-startup.sh`, so updating them in `nextcloud/.env` and restarting the stack handles `overwrite.cli.url` and trusted domains automatically. Also:
  1. Re-run notify_push setup with the new domain (cannot be automated — requires the push service to already be running):
     ```bash
     docker exec -u www-data nextcloud_app php occ notify_push:setup https://newdomain.example.com/push
     ```
  2. *(If whiteboard profile is enabled)* Update `WHITEBOARD_PUBLIC_URL` in `nextcloud/.env` to use the new domain - `before-startup.sh` re-applies `collabBackendUrl` automatically on restart.
  3. Update the NPM proxy host and Cloudflare Tunnel public hostname to point to the new domain.

- **`overwriteprotocol`** is set to `https` so Nextcloud generates HTTPS links through NPM. To temporarily switch to HTTP for LAN troubleshooting:
  ```bash
  docker exec -u www-data nextcloud_app php occ config:system:set overwriteprotocol --value="http"
  ```
  Set it back to `https` when done.

- **Security notes**:
  - Disable the Vaultwarden admin panel after initial setup (empty `vaultwarden/secrets/admin_token` and restart)
  - Database credentials and the Nextcloud admin password are loaded from secret files at container startup and do not appear in `docker inspect` output. Secret files are in `nextcloud/secrets/`, `forgejo/secrets/`, and `backup/secrets/` (mode 600, gitignored)
  - Elasticsearch has no authentication - it is on the internal `nextcloud_network` only and not reachable from outside
  - The Borg passphrase in `backup/secrets/borg_passphrase` should be stored in Vaultwarden or another secure location separately from the backup destination - if lost, encrypted backups cannot be recovered
