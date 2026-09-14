#!/usr/bin/env python3
"""Create the lares monitors in Uptime Kuma.

Uptime Kuma 1.23 has no REST API for monitors -- /api/monitors returns the SPA's
index.html, byte-identical to a nonsense route, and API keys only authorise
/metrics. Monitor management is socket.io, which needs username + password.

Credentials are read from /etc/lares/kuma.env (root, 0600) so they never pass
through a shell argument, process list, or chat transcript:

    KUMA_URL=http://127.0.0.1:3001
    KUMA_USERNAME=...
    KUMA_PASSWORD=...

Idempotent: monitors are matched by name, and existing ones are left alone.
"""
import os
import sys

from uptime_kuma_api import UptimeKumaApi, MonitorType

ENV = "/etc/lares/kuma.env"


def load_env(path):
    if not os.path.exists(path):
        sys.exit(f"FATAL: {path} not found. Create it with KUMA_URL/USERNAME/PASSWORD.")
    cfg = {}
    with open(path) as fh:
        for line in fh:
            line = line.strip()
            if line and not line.startswith("#") and "=" in line:
                k, v = line.split("=", 1)
                cfg[k.strip()] = v.strip()
    return cfg


# Targets verified from inside the Kuma container before being written here.
# Service names (vaultwarden, syncthing) resolve on the compose network and
# survive container IP changes. 172.19.0.1 is the bridge gateway, reaching
# AdGuard through its published port -- the subnet is pinned in compose so this
# address cannot drift.
MONITORS = [
    dict(
        type=MonitorType.DNS,
        name="AdGuard DNS",
        hostname="doubleclick.net",
        dns_resolve_server="172.19.0.1",
        port=53,
        dns_resolve_type="A",
        interval=60,
        # A blocklisted domain is answered locally, so this stays up during an
        # ISP outage and only goes red when AdGuard itself is down.
    ),
    dict(
        type=MonitorType.HTTP,
        name="Vaultwarden",
        url="http://vaultwarden:8080/alive",
        interval=60,
    ),
    dict(
        type=MonitorType.HTTP,
        name="Syncthing",
        url="http://syncthing:8384/rest/noauth/health",
        interval=60,
    ),
    dict(
        type=MonitorType.PING,
        name="Router / internet",
        hostname="${PI_GATEWAY}",
        interval=60,
    ),
    dict(
        type=MonitorType.PUSH,
        name="Nightly backup",
        # 25h: one missed nightly run trips it, a slow run does not.
        interval=90000,
    ),
]


def ensure_ntfy(api):
    """Attach an ntfy notification channel to every monitor.

    Without this, Kuma records outages and tells nobody -- which is the state
    this stack was in until ntfy existed. isDefault/applyExisting mean new
    monitors get it automatically and existing ones are back-filled.

    ntfy settings come from /etc/lares/backup.env (the topic is the shared
    secret, so it is not committed).
    """
    from uptime_kuma_api import NotificationType

    bk = load_env("/etc/lares/backup.env")
    topic = bk.get("NTFY_TOPIC")
    # Kuma runs in a container and CANNOT resolve the tailnet MagicDNS name --
    # those are not public, and container DNS goes out to Quad9. Verified:
    # pi5.<tailnet>.ts.net returns ENOTFOUND from inside the container while
    # http://ntfy returns 200. Using the external URL here silently produced a
    # monitor that detected outages and notified nobody.
    # The phone subscribes via the external HTTPS URL; services use this one.
    url = bk.get("NTFY_INTERNAL_URL", "http://ntfy")
    if not topic:
        print("  ! NTFY_TOPIC not in /etc/lares/backup.env -- skipping")
        return

    if any(n["name"] == "ntfy" for n in api.get_notifications()):
        print("  = ntfy notification: already configured")
        return

    api.add_notification(
        name="ntfy",
        type=NotificationType.NTFY,
        isDefault=True,
        applyExisting=True,
        ntfyserverurl=url,
        ntfytopic=topic,
        ntfyPriority=5,
        ntfyAuthenticationMethod="none",
    )
    print(f"  + ntfy notification: created -> {url}/{topic[:8]}...")


def main():
    cfg = load_env(ENV)
    url = cfg.get("KUMA_URL", "http://127.0.0.1:3001")
    user = cfg.get("KUMA_USERNAME")
    pw = cfg.get("KUMA_PASSWORD")
    if not user or not pw:
        sys.exit(f"FATAL: KUMA_USERNAME/KUMA_PASSWORD missing from {ENV}")

    api = UptimeKumaApi(url)
    try:
        api.login(user, pw)
        existing = {m["name"]: m for m in api.get_monitors()}
        print(f"connected; {len(existing)} monitor(s) already present")

        for spec in MONITORS:
            name = spec["name"]
            if name in existing:
                print(f"  = {name}: already exists, left alone")
                continue
            api.add_monitor(**spec)
            print(f"  + {name}: created")

        print("\nnotifications:")
        ensure_ntfy(api)

        print("\nfinal state:")
        for m in api.get_monitors():
            extra = ""
            if m["type"] == "push":
                extra = f"  pushToken={m.get('pushToken')}"
            print(f"  [{m['type']}] {m['name']}{extra}")
    finally:
        api.disconnect()


if __name__ == "__main__":
    main()
