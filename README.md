# am-i-overreacting

Docker Compose setup for Nextcloud with Nginx Proxy Manager and Cloudflare Tunnel.

## Architecture

```
Internet → Cloudflare Tunnel → NPM → Nextcloud
                                  → HaRP → ExApps
LAN → :8888 → Nextcloud (direct)
    → :8780 → HaRP/ExApps (direct)
```

### Networks

| Network | Purpose |
|---------|---------|
| `proxy_network` | Reverse proxy traffic (NPM, cloudflared, external-facing services) |
| `nextcloud_network` | Internal services (postgres, redis) |
| `exapps_network` | HaRP and managed ExApp containers |

## Services

### npm-compose.yaml
- **nginx-proxy-manager** - Reverse proxy with Let's Encrypt SSL
- **cloudflared** - Cloudflare Tunnel for external access

### nextcloud-compose.yaml
- **nextcloud_app** - Main Nextcloud instance
- **nextcloud_postgres** - PostgreSQL database
- **nextcloud_redis** - Redis cache
- **nextcloud_notify_push** - Push notifications (High Performance Backend)
- **nextcloud_harp** - HaRP reverse proxy for ExApps (AppAPI)

## Setup

### 1. Create the proxy network

```bash
docker network create proxy_network
```

### 2. Configure environment files

Copy and edit the example values in `npm.env` and `nextcloud.env`:

**npm.env**
- `CLOUDFLARE_TUNNEL_TOKEN` - Your Cloudflare Tunnel token
- `DOCKER_VOLUME_DIR` - Base path for NPM data

**nextcloud.env**
- `NEXTCLOUD_VERSION` - Nextcloud image tag
- `NEXTCLOUD_TRUSTED_DOMAINS` - Space-separated trusted domains
- `POSTGRES_PASSWORD` - Database password (change this!)
- `HP_SHARED_KEY` - HaRP shared key for ExApp authentication (change this!)
- `DOCKER_VOLUME_DIR` - Base path for Nextcloud data

### 3. Create volume directories

```bash
sudo mkdir -p /var/lib/nginx-proxy-manager/{data,letsencrypt}
sudo mkdir -p /var/lib/nextcloud/{app,data,db,harp_certs}
```

### 4. Start the stacks

```bash
docker compose -f npm-compose.yaml --env-file npm.env up -d
docker compose -f nextcloud-compose.yaml --env-file nextcloud.env up -d
```

## Configuring HaRP/AppAPI

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

External traffic flows through Cloudflare Tunnel, so NPM doesn't need ports 80/443 exposed.

## Notes

- The `OVERWRITEPROTOCOL` env var should be set to `https` if using SSL termination at NPM
- Configure NPM to proxy to `nextcloud_app:80` for the main Nextcloud instance
- For notify_push, proxy to `nextcloud_notify_push:7867`
