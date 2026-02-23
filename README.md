# am-i-overreacting

Docker Compose setup for Nextcloud, Gitea, Vaultwarden, and Uptime Kuma via Nginx Proxy Manager and Cloudflare Tunnel.

## Architecture

```
Internet → Cloudflare Tunnel → NPM → Nextcloud
                                   → HaRP → ExApps
                                   → Gitea
                                   → Vaultwarden
                                   → Uptime Kuma
LAN → :8888 → Nextcloud (direct)
    → :8780 → HaRP/ExApps (direct)
    → :3000 → Gitea (direct)
    → :2222 → Gitea SSH (direct)
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
- **nextcloud_harp** - HaRP reverse proxy for ExApps (AppAPI)

### gitea/docker-compose.yaml
- **gitea_app** - Gitea git server
- **gitea_postgres** - PostgreSQL database

### vaultwarden/docker-compose.yaml
- **vaultwarden** - Bitwarden-compatible password manager

### uptime-kuma/docker-compose.yaml
- **uptime_kuma** - Uptime monitoring dashboard

### backup/docker-compose.yaml
- **borgmatic** - Scheduled encrypted backups to Borgbase via borgbackup

## Setup

### 1. Configure Docker log rotation

Set default log rotation for all containers by copying the included `daemon.json` to your Docker daemon configuration:

```bash
sudo cp -n daemon.json /etc/docker/daemon.json && sudo systemctl restart docker
```

If the file already exists (`cp` prints an error and nothing is overwritten), merge the `log-driver` and `log-opts` keys from `daemon.json` into your existing file manually, then restart Docker.

This limits every container to 10MB x 3 log files (30MB max per container). This is especially important because HaRP-spawned ExApp containers are not managed by docker-compose and would otherwise have no log limits.

### 2. Create Docker networks

```bash
docker network create nextcloud_proxy_network
docker network create gitea_proxy_network
docker network create vaultwarden_proxy_network
docker network create uptime_kuma_proxy_network
```

The `tunnel_network` (used between cloudflared and NPM) is managed by the reverse-proxy stack and created automatically.

### 3. Create a Cloudflare Tunnel

1. Go to [Cloudflare Zero Trust](https://one.dash.cloudflare.com/) → **Networks → Connectors**
2. Create a new tunnel and copy the tunnel token

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

The `generate-passwords.sh` script replaces all `=changeme` default passwords with secure random values. Copy these somewhere safe - store them in Vaultwarden once it is set up (step 13), or in another secure location in the meantime.

> **backup/.env**: `generate-passwords.sh` sets `BORG_PASSPHRASE` and automatically copies DB credentials and volume paths from the other stacks into `backup/.env` - no manual copying needed. Store `BORG_PASSPHRASE` in Vaultwarden or another secure location - loss means backups are irrecoverable.

**reverse-proxy/.env**
- `CLOUDFLARE_TUNNEL_TOKEN` - Tunnel token from the previous step
- `DOCKER_VOLUME_DIR` - Base path for NPM data

**nextcloud/.env**
- `NEXTCLOUD_TRUSTED_DOMAINS` - Space-separated list of domains (e.g., `cloud.example.com nextcloud_app`)
- `NEXTCLOUD_ADMIN_USER` / `NEXTCLOUD_ADMIN_PASSWORD` - Admin credentials
- `COMPOSE_PROFILES` - Comma-separated list of optional service profiles (`imaginary,whiteboard,clamav,fulltextsearch`)
- `WHITEBOARD_PUBLIC_URL` - Public URL for the whiteboard WebSocket server (needed if `whiteboard` profile is enabled)
- `HP_SHARED_KEY` - HaRP shared key (set by `generate-passwords.sh`, also needed in Step 12)
- `DOCKER_VOLUME_DIR` - Base path for Nextcloud persistent files

**vaultwarden/.env**
- `VAULTWARDEN_DOMAIN` - Public URL for Vaultwarden (e.g., `https://vault.example.com`)
- `VAULTWARDEN_ADMIN_TOKEN` - Admin panel token (set by `generate-passwords.sh`; disable after setup)

**backup/.env**
- `BORGBASE_REPO` - Borgbase SSH repository URL (e.g., `ssh://user@xxx.repo.borgbase.com/./repo`)
- `BORG_PASSPHRASE` - Encryption passphrase (set by `generate-passwords.sh`); store in Vaultwarden or another secure location separately from the backup destination - loss means backups are irrecoverable
- `SSH_KEY_PATH` - Path to the Borgbase SSH private key on the host (default: `/root/.ssh/borgbase_ed25519`)
- Nextcloud, Gitea, and Vaultwarden volume paths and DB credentials - populated automatically by `generate-passwords.sh`

### 5. Start the reverse-proxy stack

```bash
docker compose -f reverse-proxy/docker-compose.yaml up -d
```

### 6. Configure NPM and Cloudflare

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

### 7. Prepare Nextcloud volumes

Create the data directory with correct ownership for `www-data` (UID 33), and copy the post-installation hook which runs automatically during Nextcloud's first startup:

```bash
source nextcloud/.env && [ -n "${NEXTCLOUD_HOOKS_VOLUME}" ] || { echo "NEXTCLOUD_HOOKS_VOLUME is not set"; exit 1; }
sudo mkdir -p ${NEXTCLOUD_DATA_VOLUME}
sudo chown 33:33 ${NEXTCLOUD_DATA_VOLUME}
sudo mkdir -p -m 755 ${NEXTCLOUD_HOOKS_VOLUME}/post-installation
sudo mkdir -p ${ELASTICSEARCH_DATA_VOLUME}
sudo chown 1000:1000 ${ELASTICSEARCH_DATA_VOLUME}
sudo cp nextcloud/hooks/post-installation.sh ${NEXTCLOUD_HOOKS_VOLUME}/post-installation/
sudo chmod 755 ${NEXTCLOUD_HOOKS_VOLUME}/post-installation/post-installation.sh
```

> **ClamAV**: On first start, `nextcloud_clamav` downloads ~300MB of virus definitions. Wait for it to report healthy before uploading files.

### 8. Start the Nextcloud and Gitea stacks

```bash
docker compose -f nextcloud/docker-compose.yaml up -d
docker compose -f gitea/docker-compose.yaml up -d
```

### 9. Set up cron

Add a crontab entry on the host to run Nextcloud's background jobs every 5 minutes:

```bash
(crontab -l 2>/dev/null; echo "*/5 * * * * docker exec -u www-data nextcloud_app php -f /var/www/html/cron.php") | crontab -
```

### 10. Configure notify_push

The notify_push app is installed automatically by the post-installation hook (if included in `NEXTCLOUD_APPS`). Run the setup command to complete the configuration:

```bash
docker exec -u www-data nextcloud_app php occ notify_push:setup https://cloud.yourdomain.com/push
```

### 11. Configure full text search indexing

If the `fulltextsearch` profile is enabled, trigger the initial index after all containers are healthy:

```bash
docker exec -u www-data nextcloud_app php occ fulltextsearch:index
```

This may take some time depending on the number of files.

### 12. Verify HaRP/AppAPI

The AppAPI deploy daemon is registered automatically by the post-installation hook using `HP_SHARED_KEY`. Verify it in **Administration Settings → AppAPI** - you should see a "Harp Proxy (Docker)" daemon registered.

### 13. Start Vaultwarden and Uptime Kuma

```bash
docker compose -f vaultwarden/docker-compose.yaml up -d
docker compose -f uptime-kuma/docker-compose.yaml up -d
```

Access Uptime Kuma at its domain to create the admin account on first login.

After initial Vaultwarden setup, disable the admin panel by setting `VAULTWARDEN_ADMIN_TOKEN=` (empty) in `vaultwarden/.env` and restarting the container.

### 14. Set up backups

```bash
# Generate SSH key for Borgbase (as root, since borgmatic runs as root)
source backup/.env && sudo ssh-keygen -t ed25519 -f ${SSH_KEY_PATH} -N ""

# Add the contents of ${SSH_KEY_PATH}.pub to your Borgbase repository's authorized keys

# Initialize the Borg repository (required before first backup)
docker compose -f backup/docker-compose.yaml run --rm borgmatic init --encryption repokey-blake2

# Start the backup stack
docker compose -f backup/docker-compose.yaml up -d
```

Backups run daily at 2am, retaining 7 daily, 4 weekly, and 3 monthly snapshots.

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

## Notes

- **Switching domains** (e.g., between staging and production): Update the following:
  1. Update `overwrite.cli.url` to the new primary domain:
     ```bash
     docker exec -u www-data nextcloud_app php occ config:system:set overwrite.cli.url --value="https://newdomain.example.com"
     ```
  2. Re-run notify_push setup with the new domain:
     ```bash
     docker exec -u www-data nextcloud_app php occ notify_push:setup https://newdomain.example.com/push
     ```
  3. If the new domain wasn't included in `NEXTCLOUD_TRUSTED_DOMAINS` during initial setup, add it. Note that each command overwrites a single index, so list all domains you want to keep:
     ```bash
     docker exec -u www-data nextcloud_app php occ config:system:set trusted_domains 0 --value="newdomain.example.com"
     docker exec -u www-data nextcloud_app php occ config:system:set trusted_domains 1 --value="192.168.1.100:8888"
     ```
  4. Update the NPM proxy host and Cloudflare Tunnel public hostname to point to the new domain.

- **`overwriteprotocol`** is set to `https` so Nextcloud generates HTTPS links through NPM. To temporarily switch to HTTP for LAN troubleshooting:
  ```bash
  docker exec -u www-data nextcloud_app php occ config:system:set overwriteprotocol --value="http"
  ```
  Set it back to `https` when done.

- **Security notes**:
  - Disable the Vaultwarden admin panel after initial setup (`VAULTWARDEN_ADMIN_TOKEN=`)
  - Redis and Elasticsearch have no authentication - they are on the internal `nextcloud_network` only and not reachable from outside
  - The `BORG_PASSPHRASE` should be stored in Vaultwarden or another secure location separately from the backup destination - if lost, encrypted backups cannot be recovered
