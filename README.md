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

### reverse-proxy/docker-compose.yaml
- **nginx-proxy-manager** - Reverse proxy with Let's Encrypt SSL
- **cloudflared** - Cloudflare Tunnel for external access

### nextcloud/docker-compose.yaml
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

### 2. Create a Cloudflare Tunnel

1. Go to [Cloudflare Zero Trust](https://one.dash.cloudflare.com/) → **Networks → Connectors → Tunnels**
2. Create a new tunnel and copy the tunnel token

### 3. Configure environment files

Copy and edit the example values in `reverse-proxy/.env` and `nextcloud/.env`:

**reverse-proxy/.env**
- `CLOUDFLARE_TUNNEL_TOKEN` - Tunnel token from the previous step
- `DOCKER_VOLUME_DIR` - Base path for NPM data

**nextcloud/.env**
- `NEXTCLOUD_VERSION` - Nextcloud image tag
- `NEXTCLOUD_TRUSTED_DOMAINS` - Space-separated trusted domains
- `POSTGRES_PASSWORD` - Database password (change this!)
- `HP_SHARED_KEY` - HaRP shared key for ExApp authentication (change this!)
- `DOCKER_VOLUME_DIR` - Base path for Nextcloud data

### 4. Create volume directories

```bash
sudo mkdir -p /var/lib/nginx-proxy-manager/{data,letsencrypt}
sudo mkdir -p /var/lib/nextcloud/{app,data,db,harp_certs}
```

### 5. Start the reverse-proxy stack

```bash
docker compose -f reverse-proxy/docker-compose.yaml up -d
```

### 6. Configure NPM and Cloudflare

1. Access the NPM admin panel at `http://<server-ip>:81`
2. Generate an [Origin Certificate](https://dash.cloudflare.com/?to=/:account/:zone/ssl-tls/origin) under **SSL/TLS → Origin Server → Create Certificate** and install it in NPM as a custom SSL certificate for your domain
3. Add a proxy host for your Nextcloud domain pointing to `nextcloud_app:80`
4. Paste the contents of `reverse-proxy/nginx.config` into the **Advanced** tab of the proxy host — this configures security headers, large file uploads, and the notify_push WebSocket proxy
5. In the Cloudflare Tunnel config, add a public hostname for your domain (e.g., `cloud.yourdomain.com`) and set the service to `https://nginx-proxy-manager:443`

### 7. Start the Nextcloud stack

```bash
docker compose -f nextcloud/docker-compose.yaml up -d
```

### 8. Configure notify_push

1. In Nextcloud, install the **Client Push** app
2. Run the setup command:
   ```bash
   docker exec -u www-data nextcloud-nextcloud_app-1 php occ notify_push:setup https://cloud.yourdomain.com/push
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

- After installation, set `overwriteprotocol` to `https` in Nextcloud's `config.php` so it generates HTTPS links through NPM
