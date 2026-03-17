# am-i-overreacting/uptime-kuma/provision_monitors.py
from uptime_kuma_api import UptimeKumaApi, MonitorType

MONITOR_INTERVAL = 60


def monitor_definitions(config: dict) -> list[dict]:
    """Build the full list of monitor dicts from user config.

    Required config keys:
        nextcloud_domain, forgejo_ip, vaultwarden_domain,
        main_server_ip, include_hpb, include_netbird

    Optional (required when include_hpb=True):
        hpb_domain, collabora_domain, hpb_ip

    Optional (required when include_netbird=True):
        netbird_ip
    """
    monitors = [
        # --- am-i-overreacting application monitors ---
        {
            "name": "Nextcloud",
            "type": MonitorType.HTTP,
            "url": f"https://{config['nextcloud_domain']}/status.php",
            "interval": MONITOR_INTERVAL,
            "group": "am-i-overreacting",
        },
        {
            "name": "Forgejo",
            "type": MonitorType.HTTP,
            "url": f"http://{config['forgejo_ip']}:3000/api/v1/version",
            "interval": MONITOR_INTERVAL,
            "group": "am-i-overreacting",
        },
        {
            "name": "Vaultwarden",
            "type": MonitorType.HTTP,
            "url": f"https://{config['vaultwarden_domain']}/alive",
            "interval": MONITOR_INTERVAL,
            "group": "am-i-overreacting",
        },
        {
            "name": "notify_push",
            "type": MonitorType.PORT,
            "hostname": config["main_server_ip"],
            "port": 7867,
            "interval": MONITOR_INTERVAL,
            "group": "am-i-overreacting",
        },
        {
            "name": "Borgmatic",
            "type": MonitorType.PUSH,
            "interval": MONITOR_INTERVAL * 24 * 2,  # 48h: daily runs with margin
            "group": "am-i-overreacting",
            "push_url_key": "borgmatic_push_url",
        },
        # --- Main server host checks ---
        {
            "name": "Main server",
            "type": MonitorType.PING,
            "hostname": config["main_server_ip"],
            "interval": MONITOR_INTERVAL,
            "group": "main-server",
        },
        {
            "name": "Main server SSH",
            "type": MonitorType.PORT,
            "hostname": config["main_server_ip"],
            "port": 22,
            "interval": MONITOR_INTERVAL,
            "group": "main-server",
        },
        {
            "name": "Main server unattended-upgrades",
            "type": MonitorType.PUSH,
            "interval": MONITOR_INTERVAL * 60 * 25,  # 25h: daily runs with margin
            "group": "main-server",
            "push_url_key": "main_unattended_upgrades_push_url",
        },
        {
            "name": "Main server reboot required",
            "type": MonitorType.PUSH,
            "interval": MONITOR_INTERVAL * 60,  # 1h: cron runs hourly
            "group": "main-server",
            "push_url_key": "main_reboot_push_url",
        },
        {
            "name": "Main server disk space",
            "type": MonitorType.PUSH,
            "interval": MONITOR_INTERVAL * 60,  # 1h: cron runs hourly
            "group": "main-server",
            "push_url_key": "main_disk_push_url",
        },
    ]

    if config.get("include_netbird"):
        monitors.append({
            "name": "Netbird",
            "type": MonitorType.PING,
            "hostname": config["netbird_ip"],
            "interval": MONITOR_INTERVAL,
            "group": "main-server",
        })

    if config.get("include_hpb"):
        monitors += [
            {
                "name": "HPB server",
                "type": MonitorType.PING,
                "hostname": config["hpb_ip"],
                "interval": MONITOR_INTERVAL,
                "group": "half-price-books",
            },
            {
                "name": "HPB server SSH",
                "type": MonitorType.PORT,
                "hostname": config["hpb_ip"],
                "port": 22,
                "interval": MONITOR_INTERVAL,
                "group": "half-price-books",
            },
            {
                "name": "HPB unattended-upgrades",
                "type": MonitorType.PUSH,
                "interval": MONITOR_INTERVAL * 60 * 25,
                "group": "half-price-books",
                "push_url_key": "hpb_unattended_upgrades_push_url",
            },
            {
                "name": "HPB reboot required",
                "type": MonitorType.PUSH,
                "interval": MONITOR_INTERVAL * 60,
                "group": "half-price-books",
                "push_url_key": "hpb_reboot_push_url",
            },
            {
                "name": "HPB disk space",
                "type": MonitorType.PUSH,
                "interval": MONITOR_INTERVAL * 60,
                "group": "half-price-books",
                "push_url_key": "hpb_disk_push_url",
            },
            {
                "name": "HPB Signaling",
                "type": MonitorType.HTTP,
                "url": f"https://{config['hpb_domain']}/api/v1/welcome",
                "interval": MONITOR_INTERVAL,
                "group": "half-price-books",
            },
            {
                "name": "Collabora",
                "type": MonitorType.HTTP,
                "url": f"https://{config['collabora_domain']}/hosting/discovery",
                "interval": MONITOR_INTERVAL,
                "group": "half-price-books",
            },
            {
                "name": "HPB coturn",
                "type": MonitorType.PORT,
                "hostname": config["hpb_ip"],
                "port": 3478,
                "interval": MONITOR_INTERVAL,
                "group": "half-price-books",
            },
        ]

    return monitors
