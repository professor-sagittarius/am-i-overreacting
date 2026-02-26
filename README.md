# am-i-overreacting

Docker Compose setup for Nextcloud, Gitea, Vaultwarden, and Uptime Kuma via Nginx Proxy Manager and Cloudflare Tunnel.

## Architecture

```
Internet → Cloudflare Tunnel → NPM → Nextcloud
                                   → HaRP → ExApps
                                   → Gitea
                                   → Vaultwarden
                                   → Uptime Kuma
LAN → :8888 → Nextcloud
    → :8780 → HaRP/ExApps
    → :3000 → Gitea
    → :2222 → Gitea SSH
```

### Networks

Each externally-facing stack has its own isolated proxy network. NPM joins all of them. A compromised service cannot reach other services via the proxy layer.

| Network | Purpose |
|---------|---------|
| `tunnel_network` | cloudflared ↔ NPM only |
| `nextcloud_proxy_network` | NPM ↔ Nextcloud services |
| `gitea_proxy_network` | NPM ↔ Gitea |
| `vaultwarden_proxy_network` | NPM ↔ Vaultwarden |
| `uptime_kuma_proxy_network` | NPM ↔ Uptime Kuma |
| `nextcloud_network` | Nextcloud internal services (postgres, redis, etc.) |
| `exapps_network` | HaRP and managed ExApp containers |
| `gitea_network` | Gitea internal services (postgres) |

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

### gitea/docker-compose.yaml
- **gitea_app** - Gitea git server
- **gitea_postgres** - PostgreSQL database

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

### 1. System Preparation

#### vm.max_map_count for Elasticsearch

If using the `fulltextsearch` profile (Elasticsearch), increase the kernel parameter:

```bash
# Set for current session
sysctl -w vm.max_map_count=262144

# Make persistent across reboots
echo 'vm.max_map_count=262144' | sudo tee -a /etc/sysctl.conf
```

### 2. Configure Docker log rotation

Set default log rotation for all containers by copying the included `daemon.json` to your Docker daemon configuration:

```bash
sudo cp -n daemon.json /etc/docker/daemon.json && sudo systemctl restart docker
```

If the file already exists (`cp` prints an error and nothing is overwritten), merge the `log-driver` and `log-opts` keys from `daemon.json` into your existing file manually, then restart Docker.

This limits every container to 10MB x 3 log files (30MB max per container). This is especially important because HaRP-spawned ExApp containers are not managed by docker-compose and would otherwise have no log limits.

### 3. Create a Cloudflare Tunnel

1. Go to [Cloudflare Zero Trust](https://one.dash.cloudflare.com/) → **Networks → Connectors**
2. Create a new tunnel and copy the tunnel token
3. Save the tunnel token securely - you'll need it for `reverse-proxy/.env` in step 4

### 4. Configure environment files

Copy the example environment files and edit the `.env` files with your values:

```bash
cp reverse-proxy/example.env reverse-proxy/.env
cp nextcloud/example.env nextcloud/.env
cp gitea/example.env gitea/.env
cp vaultwarden/example.env vaultwarden/.env
cp uptime-kuma/example.env uptime-kuma/.env
cp backup/example.env backup/.env
chmod 600 reverse-proxy/.env nextcloud/.env gitea/.env vaultwarden/.env uptime-kuma/.env backup/.env
bash generate-passwords.sh
```

The `generate-passwords.sh` script creates `nextcloud/secrets/`, `gitea/secrets/`, and `backup/secrets/` directories with generated credentials (mode 600), and replaces remaining `=changeme` placeholder values in `.env` files with secure random values.

> **backup/.env**: `generate-passwords.sh` automatically copies volume paths and database config (names and usernames) from the other stacks into `backup/.env` - no manual copying needed. The Borg passphrase is generated in `backup/secrets/borg_passphrase` - store this securely in Vaultwarden once it is set up (step 13), or in another secure location in the meantime. Loss means backups are irrecoverable.

**reverse-proxy/.env**
- `CLOUDFLARE_TUNNEL_TOKEN` - Tunnel token from the previous step
- `DOCKER_VOLUME_DIR` - Base path for NPM data

**nextcloud/.env**
- `NEXTCLOUD_TRUSTED_DOMAINS` - Space-separated list of domains (e.g., `cloud.example.com nextcloud_app`)
- `NEXTCLOUD_PRIMARY_DOMAIN` - Primary domain used for `overwrite.cli.url` (must also be in `NEXTCLOUD_TRUSTED_DOMAINS`)
- `NEXTCLOUD_ADMIN_USER` - Admin username (password is in `nextcloud/secrets/admin_password`)
- `NEXTCLOUD_PROXY_NETWORK_SUBNET` - Subnet for the nextcloud_proxy_network (default: 172.28.0.0/24)
- `NEXTCLOUD_INTERNAL_NETWORK_SUBNET` - Subnet for nextcloud_network internal bridge (default: 172.29.0.0/24)
- `COMPOSE_PROFILES` - Comma-separated list of optional service profiles (`harp,imaginary,whiteboard,clamav,fulltextsearch`); `HP_SHARED_KEY` is only needed when the `harp` profile is enabled
- `WHITEBOARD_PUBLIC_URL` - Public URL for the whiteboard WebSocket server (needed if `whiteboard` profile is enabled)
- `HP_SHARED_KEY` - HaRP shared key (set by `generate-passwords.sh`; only needed when the `harp` profile is enabled)
- `DOCKER_VOLUME_DIR` - Base path for Nextcloud persistent files

**vaultwarden/.env**
- `VAULTWARDEN_DOMAIN` - Public URL for Vaultwarden (e.g., `https://vault.example.com`)
- `VAULTWARDEN_ADMIN_TOKEN` - Admin panel token (set by `generate-passwords.sh`; stored in `vaultwarden/secrets/admin_token`; disable after setup by emptying the secret file)

**backup/.env**
- `BORGBASE_REPO` - Borgbase SSH repository URL (e.g., `ssh://user@xxx.repo.borgbase.com/./repo`)
- Borg passphrase - Generated in `backup/secrets/borg_passphrase` by `generate-passwords.sh`; store in Vaultwarden or another secure location separately from the backup destination - loss means backups are irrecoverable
- `SSH_KEY_PATH` - Path to the Borgbase SSH private key on the host (default: `/root/.ssh/borgbase_ed25519`)
- Nextcloud, Gitea, and Vaultwarden volume paths and DB credentials - populated automatically by `generate-passwords.sh`

### 5. Create Docker networks

```bash
source nextcloud/.env
docker network create --subnet=${NEXTCLOUD_PROXY_NETWORK_SUBNET} nextcloud_proxy_network
docker network create gitea_proxy_network
docker network create vaultwarden_proxy_network
docker network create uptime_kuma_proxy_network
```

The Nextcloud proxy network uses a fixed subnet so `TRUSTED_PROXIES` can be scoped to only NPM. The subnet is `NEXTCLOUD_PROXY_NETWORK_SUBNET` in `nextcloud/.env`.

The `tunnel_network` (used between cloudflared and NPM) is managed by the reverse-proxy stack and created automatically.

### 6. Start the reverse-proxy stack

```bash
docker compose -f reverse-proxy/docker-compose.yaml up -d
```

### 7. Configure NPM and Cloudflare

**Verification checkpoint:** After starting the reverse-proxy stack, verify NPM loads at `http://<HOST_LAN_IP>:81`

1. Access the NPM admin panel at `http://<server-ip>:81`
2. Generate an [Origin Certificate](https://dash.cloudflare.com/?to=/:account/:zone/ssl-tls/origin) under **SSL/TLS → Origin Server → Create Certificate** and install it in NPM as a custom SSL certificate for your domain
3. Add proxy hosts in NPM pointing to each service:
   - Nextcloud domain → `nextcloud_app:80`
   - Gitea domain → `gitea_app:3000`
   - Vaultwarden domain → `vaultwarden:80`
   - Uptime Kuma domain → `uptime_kuma:3001`
   - Whiteboard domain → `nextcloud_whiteboard:3002` *(if whiteboard profile enabled; enable **WebSockets Support** in the NPM proxy host settings)*
4. Paste the contents of `reverse-proxy/nginx.config` into the **Advanced** tab of the Nextcloud proxy host - this configures security headers, large file uploads, and the notify_push WebSocket proxy
5. In the Cloudflare Tunnel config, add public hostnames pointing to `https://nginx-proxy-manager:443` for each domain

### 8. Prepare Nextcloud volumes

Create the data directory with correct ownership for `www-data` (UID 33), and copy the post-installation hook which runs automatically during Nextcloud's first startup:

```bash
source nextcloud/.env && [ -n "${NEXTCLOUD_HOOKS_VOLUME}" ] || { echo "NEXTCLOUD_HOOKS_VOLUME is not set"; exit 1; }
sudo mkdir -p ${NEXTCLOUD_DATA_VOLUME}
sudo chown 33:33 ${NEXTCLOUD_DATA_VOLUME}
sudo mkdir -p ${NEXTCLOUD_REDIS_VOLUME}
sudo mkdir -p -m 755 ${NEXTCLOUD_HOOKS_VOLUME}/post-installation
sudo mkdir -p ${ELASTICSEARCH_DATA_VOLUME}
sudo chown 1000:1000 ${ELASTICSEARCH_DATA_VOLUME}
sudo cp nextcloud/hooks/post-installation.sh ${NEXTCLOUD_HOOKS_VOLUME}/post-installation/
sudo chmod 755 ${NEXTCLOUD_HOOKS_VOLUME}/post-installation/post-installation.sh
```

### 9. Set up cron

Add a crontab entry on the host to run Nextcloud's background jobs every 5 minutes:

```bash
(crontab -l 2>/dev/null; echo "*/5 * * * * docker exec -u www-data nextcloud_app php -f /var/www/html/cron.php") | crontab -
```

The crontab entry is added now, before the container starts. The `docker exec` command will fail silently until `nextcloud_app` is running — once it starts, cron takes effect immediately.

### 10. Start the Nextcloud and Gitea stacks

> *(if harp profile is enabled)* **Note:** The HaRP container mounts `/var/run/docker.sock` to manage ExApp containers, giving it full Docker daemon access. Treat it as a high-trust component and ensure the host is otherwise secured.

```bash
docker compose -f nextcloud/docker-compose.yaml up -d
docker compose -f gitea/docker-compose.yaml up -d
```

> **ClamAV**: On first start, `nextcloud_clamav` downloads ~300MB of virus definitions. Wait for it to report healthy before uploading files.

**Verification checkpoints:**
- Nextcloud initialization: Check `docker logs nextcloud_app` for `Nextcloud is now configured`
- Verify login works at your configured Nextcloud domain

### 11. Configure notify_push

The notify_push app is installed automatically by the post-installation hook (if included in `NEXTCLOUD_APPS`). Run the setup command to complete the configuration:

```bash
docker exec -u www-data nextcloud_app php occ notify_push:setup https://cloud.yourdomain.com/push
```

**Verification checkpoint:** notify_push is running on TCP port 7867 (check with `docker ps`)

### 12. Configure full text search indexing

If the `fulltextsearch` profile is enabled, trigger the initial index after all containers are healthy:

```bash
docker exec -u www-data nextcloud_app php occ fulltextsearch:index
```

This may take some time depending on the number of files.

### 13. Verify HaRP/AppAPI *(skip if harp profile is not enabled)*

The AppAPI deploy daemon is registered automatically by the post-installation hook using `HP_SHARED_KEY`. Verify it in **Administration Settings → AppAPI** - you should see a "Harp Proxy (Docker)" daemon registered.

### 14. Start Vaultwarden and Uptime Kuma

```bash
docker compose -f vaultwarden/docker-compose.yaml up -d
docker compose -f uptime-kuma/docker-compose.yaml up -d
```

Access Uptime Kuma at its domain to create the admin account on first login.

After initial Vaultwarden setup, disable the admin panel by removing or emptying `vaultwarden/secrets/admin_token` and restarting: `docker compose -f vaultwarden/docker-compose.yaml up -d --force-recreate`

**Verification checkpoints:**
- Verify Gitea at `http://<HOST_LAN_IP>:3000`
- Verify Vaultwarden at your configured domain/alive
- Run `./preflight-check.sh` before moving to backups

### 15. Set up backups

```bash
# Generate SSH key for Borgbase (as root, since borgmatic runs as root)
source backup/.env && sudo ssh-keygen -t ed25519 -f ${SSH_KEY_PATH} -N ""

# Add the contents of ${SSH_KEY_PATH}.pub to your Borgbase repository's authorized keys

# Initialize the Borg repository (required before first backup)
# Note: the first 'borgmatic' is the Docker Compose service name; the second is the binary inside the container
docker compose -f backup/docker-compose.yaml run --rm borgmatic borgmatic init --encryption repokey-blake2

# Schedule the backup script in cron
(crontab -l 2>/dev/null; echo "0 2 * * * $(realpath backup/backup.sh) 2>&1 | logger -t borgmatic") | crontab -
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

3. **Restore PostgreSQL dumps** (for Nextcloud and Gitea databases):
   - Locate the dump files in `/tmp/restore/` (typically in `var/backups/`)
   - Stop the affected containers: `docker compose -f nextcloud/docker-compose.yaml down` and/or `docker compose -f gitea/docker-compose.yaml down`
   - Restore using `pg_restore` or `psql` with the appropriate credentials from your `.env` files

4. **Restore volumes** by stopping containers and copying data back from `/tmp/restore/`:
   - Copy Nextcloud data back to the path in `NEXTCLOUD_DATA_VOLUME`
   - Copy Vaultwarden data back to the vaultwarden volume path
   - Ensure correct ownership: `sudo chown 33:33` for Nextcloud, `sudo chown 100:101` for Vaultwarden

5. **Restore secrets** — copy secret files from your secure external backup (Vaultwarden or other secure storage) into the correct locations:
   - `nextcloud/secrets/` — postgres_password, admin_password, redis_password
   - `gitea/secrets/` — postgres_password
   - `backup/secrets/` — borg_passphrase
   - `vaultwarden/secrets/` — admin_token

   **Do NOT run `generate-passwords.sh`** — this generates new credentials that will not match the restored database contents, causing containers to fail to connect.

   If a secret file was lost, the Nextcloud database password can be recovered from `config/config.php` in the restored app volume at `NEXTCLOUD_APP_VOLUME/config/config.php`.

6. **Start stacks in order:**
   ```bash
   docker compose -f reverse-proxy/docker-compose.yaml up -d
   docker compose -f vaultwarden/docker-compose.yaml up -d
   docker compose -f nextcloud/docker-compose.yaml up -d
   docker compose -f gitea/docker-compose.yaml up -d
   ```

7. **Post-restore verification:**
   - Check all health endpoints are responding
   - Verify login on Nextcloud and Gitea
   - Run `./preflight-check.sh` to verify no placeholders remain

### Restoring a single stack

To restore only one service (e.g., Nextcloud but not Gitea):
1. Stop only the affected stack: `docker compose -f nextcloud/docker-compose.yaml down`
2. Extract only the relevant archive paths (use `--path` flag with borgmatic extract)
3. Restore secrets for that stack only
4. Restart the stack — the other stacks continue running normally

## Monitoring with Uptime Kuma

Recommended HTTP(S) and TCP monitors in Uptime Kuma:

| Service | Monitor Type | Endpoint |
|---------|--------------|----------|
| **Nextcloud** | HTTP(S) | `https://your-nextcloud-domain/status.php` |
| **Gitea** | HTTP(S) | `http://HOST_LAN_IP:3000/api/v1/version` |
| **Vaultwarden** | HTTP(S) | `https://your-vaultwarden-domain/alive` |
| **notify_push** | TCP | Port 7867 on `HOST_LAN_IP` |
| **Borgmatic** | Push (optional) | Use `HEALTHCHECK_PING_URL` in `backup/.env` and uncomment the `on_error` hook in `backup/borgmatic.yaml` |

## Disk Space & Performance

### Expected Growth

- **PostgreSQL WAL (write-ahead log)** can grow over time; tune `max_wal_size` in postgres config if backups lag
- **Nextcloud storage**: ~5-10 GB/user/year for typical usage
- Monitor disk space: `df -h`
- Set up disk space alerts in Uptime Kuma for early warning

### Tuning

- Monitor disk usage regularly: `docker exec nextcloud_postgres du -sh /var/lib/postgresql/data`
- Archive old Nextcloud versions to reduce database size (in Nextcloud admin settings)
- Monitor Redis memory: `docker exec nextcloud_redis redis-cli info memory`

**Memory limits:** When a container exceeds its memory limit, Docker's OOM killer terminates it and `restart: unless-stopped` restarts it. For stateless services (imaginary, notify_push) this is harmless. For stateful services (postgres, redis), repeated OOM kills add restart latency; Redis AOF persistence (already enabled) prevents data loss. Monitor actual usage with `docker stats` after the stack has been running a few days and tune limits in your `.env` files accordingly.

## Secret Rotation

### Rotating Database Passwords

1. Generate new password: `openssl rand -base64 32`
2. Update the secret file (e.g., `nextcloud/secrets/db_password`)
3. Update the corresponding `.env` file
4. Recreate the affected container:
   ```bash
   docker compose -f nextcloud/docker-compose.yaml up -d --force-recreate nextcloud_postgres
   ```
5. Run `./preflight-check.sh` to verify

### Rotating Redis Password

1. Update `nextcloud/secrets/redis_password`
2. Update `REDIS_PASSWORD` in `nextcloud/.env`
3. Restart containers:
   ```bash
   docker compose -f nextcloud/docker-compose.yaml up -d --force-recreate nextcloud_redis nextcloud_app
   ```

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

This ensures no placeholder values remain and all secrets are properly set.

## Ports

| Port | Service | Access |
|------|---------|--------|
| 81 | NPM Admin | LAN only |
| 8888 | Nextcloud | LAN direct access |
| 8780 | HaRP ExApps | LAN direct access |
| 8782 | HaRP FRP | External Docker engines |
| 3000 | Gitea | LAN direct access |
| 2222 | Gitea SSH | Git over SSH |

External traffic flows through Cloudflare Tunnel, so NPM doesn't need ports 80/443 exposed.

> **Gitea SSH:** Git over SSH is available on port 2222. Clone with `git clone ssh://git@<server-ip>:2222/<user>/<repo>.git`. This port does not go through Cloudflare Tunnel - ensure it is reachable directly from your clients.

## Notes

- **Switching Nextcloud domains** (e.g., between staging and production): Update the following:
  1. Update `overwrite.cli.url` to the new primary domain:
     ```bash
     docker exec -u www-data nextcloud_app php occ config:system:set overwrite.cli.url --value="https://newdomain.example.com"
     ```
  2. Update `NEXTCLOUD_PRIMARY_DOMAIN` in `nextcloud/.env` to the new primary domain and restart: `docker compose -f nextcloud/docker-compose.yaml up -d nextcloud_app`
  3. Re-run notify_push setup with the new domain:
     ```bash
     docker exec -u www-data nextcloud_app php occ notify_push:setup https://newdomain.example.com/push
     ```
  4. If the new domain wasn't included in `NEXTCLOUD_TRUSTED_DOMAINS` during initial setup, add it. Note that each command overwrites a single index, so list all domains you want to keep:
     ```bash
     docker exec -u www-data nextcloud_app php occ config:system:set trusted_domains 0 --value="newdomain.example.com"
     docker exec -u www-data nextcloud_app php occ config:system:set trusted_domains 1 --value="192.168.1.100:8888"
     ```
  5. Update the NPM proxy host and Cloudflare Tunnel public hostname to point to the new domain.

- **`overwriteprotocol`** is set to `https` so Nextcloud generates HTTPS links through NPM. To temporarily switch to HTTP for LAN troubleshooting:
  ```bash
  docker exec -u www-data nextcloud_app php occ config:system:set overwriteprotocol --value="http"
  ```
  Set it back to `https` when done.

- **Security notes**:
  - Disable the Vaultwarden admin panel after initial setup (empty `vaultwarden/secrets/admin_token` and restart)
  - Database credentials and the Nextcloud admin password are loaded from secret files at container startup and do not appear in `docker inspect` output. Secret files are in `nextcloud/secrets/`, `gitea/secrets/`, and `backup/secrets/` (mode 600, gitignored)
  - Elasticsearch has no authentication - it is on the internal `nextcloud_network` only and not reachable from outside
  - The Borg passphrase in `backup/secrets/borg_passphrase` should be stored in Vaultwarden or another secure location separately from the backup destination - if lost, encrypted backups cannot be recovered
