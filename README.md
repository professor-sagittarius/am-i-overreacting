# am-i-overreacting

Docker Compose setup for Nextcloud and Gitea with Nginx Proxy Manager and Cloudflare Tunnel.

## Architecture

```
Internet → Cloudflare Tunnel → NPM → Nextcloud
                                   → HaRP → ExApps
                                   → Gitea
LAN → :8888 → Nextcloud (direct)
    → :8780 → HaRP/ExApps (direct)
    → :3000 → Gitea (direct)
```

### Networks

| Network | Purpose |
|---------|---------|
| `proxy_network` | Reverse proxy traffic (NPM, cloudflared, external-facing services) |
| `nextcloud_network` | Internal services (postgres, redis) |
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
- **nextcloud_harp** - HaRP reverse proxy for ExApps (AppAPI)

### gitea/docker-compose.yaml
- **gitea_app** - Gitea git server
- **gitea_postgres** - PostgreSQL database

## Setup

### 1. Configure Docker log rotation

Set default log rotation for all containers by copying the included `daemon.json` to your Docker daemon configuration:

```bash
sudo cp -n daemon.json /etc/docker/daemon.json && sudo systemctl restart docker
```

If the file already exists (`cp` prints an error and nothing is overwritten), merge the `log-driver` and `log-opts` keys from `daemon.json` into your existing file manually, then restart Docker.

This limits every container to 10MB x 3 log files (30MB max per container). This is especially important because HaRP-spawned ExApp containers are not managed by docker-compose and would otherwise have no log limits.

### 2. Create the proxy network

```bash
docker network create proxy_network
```

### 3. Create a Cloudflare Tunnel

1. Go to [Cloudflare Zero Trust](https://one.dash.cloudflare.com/) → **Networks → Connectors**
2. Create a new tunnel and copy the tunnel token

### 4. Configure environment files

Edit the example values in `reverse-proxy/.env`, `nextcloud/.env`, and `gitea/.env`:

**reverse-proxy/.env**
- `CLOUDFLARE_TUNNEL_TOKEN` - Tunnel token from the previous step
- `DOCKER_VOLUME_DIR` - Base path for NPM data

**nextcloud/.env**
- `NEXTCLOUD_VERSION` - Nextcloud image tag
- `NEXTCLOUD_TRUSTED_DOMAINS` - Space-separated list of domains (e.g., `cloud.example.com staging.example.com`)
- `NEXTCLOUD_LAN_IP` - LAN IP for direct access
- `NEXTCLOUD_LAN_PORT` - Port for LAN direct access (default: 8888)
- `POSTGRES_PASSWORD` - Database password (change this!)
- `HP_SHARED_KEY` - HaRP shared key for ExApp authentication (change this!)
- `DOCKER_VOLUME_DIR` - Base path for Nextcloud data

**gitea/.env**
- `POSTGRES_PASSWORD` - Database password (change this!)
- `DOCKER_VOLUME_DIR` - Base path for Gitea data

### 5. Start the reverse-proxy stack

```bash
docker compose -f reverse-proxy/docker-compose.yaml up -d
```

### 6. Configure NPM and Cloudflare

1. Access the NPM admin panel at `http://<server-ip>:81`
2. Generate an [Origin Certificate](https://dash.cloudflare.com/?to=/:account/:zone/ssl-tls/origin) under **SSL/TLS → Origin Server → Create Certificate** and install it in NPM as a custom SSL certificate for your domain
3. Add a proxy host for your Nextcloud domain pointing to `nextcloud_app:80`
4. Paste the contents of `reverse-proxy/nginx.config` into the **Advanced** tab of the proxy host — this configures security headers, large file uploads, and the notify_push WebSocket proxy
5. Add a proxy host for your Gitea domain pointing to `gitea_app:3000`
6. In the Cloudflare Tunnel config, add public hostnames for your domains (e.g., `cloud.yourdomain.com`, `git.yourdomain.com`) and set the service to `https://nginx-proxy-manager:443`

### 7. Start the Nextcloud and Gitea stacks

```bash
docker compose -f nextcloud/docker-compose.yaml up -d
docker compose -f gitea/docker-compose.yaml up -d
```

### 8. Copy hook scripts to the volume directory

The hook scripts automate initial Nextcloud configuration (trusted domains, trusted proxies, phone region, maintenance window, database indices). Copy them to the volume directory before first startup:

```bash
source nextcloud/.env
sudo mkdir -p ${NEXTCLOUD_HOOKS_VOLUME}/pre-installation ${NEXTCLOUD_HOOKS_VOLUME}/post-installation
sudo cp nextcloud/hooks/pre-installation.sh ${NEXTCLOUD_HOOKS_VOLUME}/pre-installation/
sudo cp nextcloud/hooks/post-installation.sh ${NEXTCLOUD_HOOKS_VOLUME}/post-installation/
sudo chmod +x ${NEXTCLOUD_HOOKS_VOLUME}/pre-installation/*.sh ${NEXTCLOUD_HOOKS_VOLUME}/post-installation/*.sh
```

These scripts run automatically during Nextcloud's initial installation and configure settings based on `nextcloud/.env`.

### 9. Configure notify_push

1. In Nextcloud, install the **Client Push** app
2. Start the notify_push service:
   ```bash
   docker compose -f nextcloud/docker-compose.yaml --profile notify_push up -d
   ```
   **Portainer**: Instead, uncomment `COMPOSE_PROFILES=notify_push` in `nextcloud/.env` and redeploy the stack.
3. Run the setup command:
   ```bash
   docker exec -u www-data nextcloud_app php occ notify_push:setup https://cloud.yourdomain.com/push
   ```

### 10. Configure HaRP/AppAPI

1. In Nextcloud, go to **Administration Settings → AppAPI**
2. Register a new Deploy Daemon:
   - **Host**: `nextcloud_harp:8780`
   - **Network**: `exapps_network`
   - **HaRP Shared Key**: Same as `HP_SHARED_KEY` in your env file

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

- After installation, set `overwriteprotocol` to `https` so Nextcloud generates HTTPS links through NPM:
  ```bash
  docker exec -u www-data nextcloud_app php occ config:system:set overwriteprotocol --value="https"
  ```
