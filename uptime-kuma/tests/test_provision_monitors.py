# am-i-overreacting/uptime-kuma/tests/test_provision_monitors.py
import sys
import pytest
from pathlib import Path
sys.path.insert(0, str(Path(__file__).parent.parent))

from unittest.mock import MagicMock
from provision_monitors import monitor_definitions, get_existing, provision_monitor, connect, format_push_url_output
from uptime_kuma_api import UptimeKumaApi, MonitorType

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


def _make_client(existing_monitors):
    client = MagicMock()
    client.get_monitors.return_value = existing_monitors
    return client


def test_get_existing_returns_dict_keyed_by_name():
    client = _make_client([
        {"id": 1, "name": "Nextcloud", "type": MonitorType.HTTP,
         "url": "https://cloud.example.com/status.php", "interval": 60},
    ])
    result = get_existing(client)
    assert "Nextcloud" in result
    assert result["Nextcloud"]["id"] == 1


def test_provision_creates_missing_monitor():
    client = _make_client([])
    desired = {"name": "Nextcloud", "type": MonitorType.HTTP,
               "url": "https://cloud.example.com/status.php", "interval": 60, "group": "aio"}
    status = provision_monitor(client, desired, {})
    assert status == "created"
    client.add_monitor.assert_called_once()


def test_provision_skips_unchanged_monitor():
    existing = {
        "Nextcloud": {"id": 1, "name": "Nextcloud", "type": MonitorType.HTTP,
                      "url": "https://cloud.example.com/status.php", "interval": 60}
    }
    client = _make_client([existing["Nextcloud"]])
    desired = {"name": "Nextcloud", "type": MonitorType.HTTP,
               "url": "https://cloud.example.com/status.php", "interval": 60, "group": "aio"}
    status = provision_monitor(client, desired, existing)
    assert status == "unchanged"
    client.add_monitor.assert_not_called()
    client.edit_monitor.assert_not_called()


def test_provision_updates_changed_url():
    existing = {
        "Nextcloud": {"id": 1, "name": "Nextcloud", "type": MonitorType.HTTP,
                      "url": "https://old.example.com/status.php", "interval": 60}
    }
    client = _make_client([existing["Nextcloud"]])
    desired = {"name": "Nextcloud", "type": MonitorType.HTTP,
               "url": "https://cloud.example.com/status.php", "interval": 60, "group": "aio"}
    status = provision_monitor(client, desired, existing)
    assert status == "updated"
    client.edit_monitor.assert_called_once()


def test_provision_updates_changed_interval():
    existing = {
        "Nextcloud": {"id": 1, "name": "Nextcloud", "type": MonitorType.HTTP,
                      "url": "https://cloud.example.com/status.php", "interval": 30}
    }
    client = _make_client([existing["Nextcloud"]])
    desired = {"name": "Nextcloud", "type": MonitorType.HTTP,
               "url": "https://cloud.example.com/status.php", "interval": 60, "group": "aio"}
    status = provision_monitor(client, desired, existing)
    assert status == "updated"


def test_provision_push_monitor_skips_when_interval_unchanged():
    existing = {
        "Borgmatic": {"id": 5, "name": "Borgmatic", "type": MonitorType.PUSH, "interval": 2880}
    }
    client = _make_client([existing["Borgmatic"]])
    desired = {"name": "Borgmatic", "type": MonitorType.PUSH,
               "interval": 2880, "group": "aio", "push_url_key": "borgmatic_push_url"}
    status = provision_monitor(client, desired, existing)
    assert status == "unchanged"


def test_provision_does_not_pass_group_to_api():
    """The 'group' field is internal bookkeeping; should not be sent to Uptime Kuma."""
    client = _make_client([])
    desired = {"name": "Nextcloud", "type": MonitorType.HTTP,
               "url": "https://cloud.example.com/status.php", "interval": 60, "group": "aio"}
    provision_monitor(client, desired, {})
    call_kwargs = client.add_monitor.call_args[1]
    assert "group" not in call_kwargs


def test_provision_does_not_pass_push_url_key_to_api():
    """push_url_key is internal; should not be sent to Uptime Kuma."""
    client = _make_client([])
    desired = {"name": "Borgmatic", "type": MonitorType.PUSH,
               "interval": 2880, "group": "aio", "push_url_key": "borgmatic_push_url"}
    provision_monitor(client, desired, {})
    call_kwargs = client.add_monitor.call_args[1]
    assert "push_url_key" not in call_kwargs


def test_connect_raises_on_bad_credentials(monkeypatch):
    """connect() should print a clear error and exit on login failure."""
    def fake_init(self, url):
        pass
    def fake_login(self, username, password):
        raise Exception("Invalid credentials")

    monkeypatch.setattr(UptimeKumaApi, "__init__", fake_init)
    monkeypatch.setattr(UptimeKumaApi, "login", fake_login)

    with pytest.raises(SystemExit) as exc:
        connect("http://localhost:3001", "admin", "wrongpassword")
    assert exc.value.code != 0


def test_connect_raises_on_connection_refused(monkeypatch):
    """connect() should print a clear error and exit if Uptime Kuma is unreachable."""
    def fake_init(self, url):
        raise ConnectionRefusedError("Connection refused")

    monkeypatch.setattr(UptimeKumaApi, "__init__", fake_init)

    with pytest.raises(SystemExit) as exc:
        connect("http://localhost:3001", "admin", "password")
    assert exc.value.code != 0


def test_format_includes_main_server_block():
    push_urls = {
        "main_unattended_upgrades_push_url": "https://uk.example.com/api/push/aaa",
        "main_reboot_push_url": "https://uk.example.com/api/push/bbb",
        "main_disk_push_url": "https://uk.example.com/api/push/ccc",
    }
    output = format_push_url_output(push_urls)
    assert "uptime-kuma-hooks-playbook.yml" in output
    assert "main_unattended_upgrades_push_url" in output
    assert "https://uk.example.com/api/push/aaa" in output


def test_format_includes_hpb_block_when_present():
    push_urls = {
        "hpb_unattended_upgrades_push_url": "https://uk.example.com/api/push/ddd",
        "hpb_reboot_push_url": "https://uk.example.com/api/push/eee",
        "hpb_disk_push_url": "https://uk.example.com/api/push/fff",
    }
    output = format_push_url_output(push_urls)
    assert "uptime-kuma-hooks-hpb-playbook.yml" in output
    assert "hpb_unattended_upgrades_push_url" in output


def test_format_omits_hpb_block_when_no_hpb_urls():
    push_urls = {
        "main_unattended_upgrades_push_url": "https://uk.example.com/api/push/aaa",
    }
    output = format_push_url_output(push_urls)
    assert "uptime-kuma-hooks-hpb-playbook.yml" not in output


def test_format_includes_borgmatic_block():
    push_urls = {"borgmatic_push_url": "https://uk.example.com/api/push/ggg"}
    output = format_push_url_output(push_urls)
    assert "backup/.env" in output
    assert "HEALTHCHECK_PING_URL" in output
    assert "https://uk.example.com/api/push/ggg" in output
