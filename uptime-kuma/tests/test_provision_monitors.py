# am-i-overreacting/uptime-kuma/tests/test_provision_monitors.py
import sys
from pathlib import Path
sys.path.insert(0, str(Path(__file__).parent.parent))

from provision_monitors import monitor_definitions
from uptime_kuma_api import MonitorType

BASE_CONFIG = {
    "nextcloud_domain": "cloud.example.com",
    "forgejo_ip": "192.168.1.10",
    "vaultwarden_domain": "vault.example.com",
    "main_server_ip": "192.168.1.10",
    "include_hpb": False,
    "include_netbird": False,
}


def test_nextcloud_monitor_present():
    monitors = monitor_definitions(BASE_CONFIG)
    names = [m["name"] for m in monitors]
    assert "Nextcloud" in names


def test_nextcloud_monitor_type_and_url():
    monitors = monitor_definitions(BASE_CONFIG)
    nc = next(m for m in monitors if m["name"] == "Nextcloud")
    assert nc["type"] == MonitorType.HTTP
    assert nc["url"] == "https://cloud.example.com/status.php"


def test_forgejo_monitor_present():
    monitors = monitor_definitions(BASE_CONFIG)
    fg = next(m for m in monitors if m["name"] == "Forgejo")
    assert fg["type"] == MonitorType.HTTP
    assert "192.168.1.10" in fg["url"]


def test_vaultwarden_monitor_present():
    monitors = monitor_definitions(BASE_CONFIG)
    vw = next(m for m in monitors if m["name"] == "Vaultwarden")
    assert vw["type"] == MonitorType.HTTP
    assert vw["url"] == "https://vault.example.com/alive"


def test_notify_push_tcp_monitor():
    monitors = monitor_definitions(BASE_CONFIG)
    np = next(m for m in monitors if m["name"] == "notify_push")
    assert np["type"] == MonitorType.PORT
    assert np["port"] == 7867


def test_borgmatic_push_monitor():
    monitors = monitor_definitions(BASE_CONFIG)
    bm = next(m for m in monitors if m["name"] == "Borgmatic")
    assert bm["type"] == MonitorType.PUSH
    assert bm["push_url_key"] == "borgmatic_push_url"


def test_main_server_ping():
    monitors = monitor_definitions(BASE_CONFIG)
    ping = next(m for m in monitors if m["name"] == "Main server")
    assert ping["type"] == MonitorType.PING
    assert ping["hostname"] == "192.168.1.10"


def test_main_server_ssh():
    monitors = monitor_definitions(BASE_CONFIG)
    ssh = next(m for m in monitors if m["name"] == "Main server SSH")
    assert ssh["type"] == MonitorType.PORT
    assert ssh["port"] == 22


def test_main_server_push_monitors():
    monitors = monitor_definitions(BASE_CONFIG)
    push_keys = {m["push_url_key"] for m in monitors if m.get("push_url_key")}
    assert "main_unattended_upgrades_push_url" in push_keys
    assert "main_reboot_push_url" in push_keys
    assert "main_disk_push_url" in push_keys


def test_hpb_monitors_excluded_when_not_configured():
    monitors = monitor_definitions(BASE_CONFIG)
    names = [m["name"] for m in monitors]
    assert "HPB Signaling" not in names
    assert "Collabora" not in names


def test_hpb_monitors_included_when_configured():
    config = {**BASE_CONFIG, "include_hpb": True,
              "hpb_domain": "signal.example.com",
              "collabora_domain": "office.example.com",
              "hpb_ip": "10.0.0.5"}
    monitors = monitor_definitions(config)
    names = [m["name"] for m in monitors]
    assert "HPB Signaling" in names
    assert "Collabora" in names
    assert "HPB coturn" in names
    assert "HPB server" in names
    assert "HPB server SSH" in names


def test_hpb_signaling_url():
    config = {**BASE_CONFIG, "include_hpb": True,
              "hpb_domain": "signal.example.com",
              "collabora_domain": "office.example.com",
              "hpb_ip": "10.0.0.5"}
    monitors = monitor_definitions(config)
    sig = next(m for m in monitors if m["name"] == "HPB Signaling")
    assert sig["url"] == "https://signal.example.com/api/v1/welcome"


def test_netbird_excluded_when_not_configured():
    monitors = monitor_definitions(BASE_CONFIG)
    names = [m["name"] for m in monitors]
    assert "Netbird" not in names


def test_netbird_included_when_configured():
    config = {**BASE_CONFIG, "include_netbird": True, "netbird_ip": "100.64.0.1"}
    monitors = monitor_definitions(config)
    nb = next(m for m in monitors if m["name"] == "Netbird")
    assert nb["type"] == MonitorType.PING
    assert nb["hostname"] == "100.64.0.1"


def test_all_monitors_have_required_fields():
    monitors = monitor_definitions(BASE_CONFIG)
    for m in monitors:
        assert "name" in m, f"Monitor missing name: {m}"
        assert "type" in m, f"Monitor {m['name']} missing type"
        assert "interval" in m, f"Monitor {m['name']} missing interval"
        assert "group" in m, f"Monitor {m['name']} missing group"
