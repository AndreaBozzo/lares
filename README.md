<div align="center">

<img src="assets/logo.webp" alt="Lares" width="160">

# Lares

**Boring, recoverable infrastructure for the home.**

A small self-hosted stack built around failure semantics and reconstruction,
rather than around collecting applications.

</div>

---

Lares assumes the machine will eventually die.

That assumption drives everything here: state is backed up application-consistently
and offsite, images are pinned by digest, resource ceilings are enforced by the
kernel rather than declared and ignored, administrative interfaces never touch the
LAN, and rebuilding the host from a blank disk is a documented, scripted path
instead of an afternoon of remembering.

**Tested on Raspberry Pi OS 64-bit.** Designed for Debian-like, systemd-based
hosts: `bootstrap.sh` uses `apt-get`, `systemctl`, and Raspberry Pi's
`/boot/firmware/cmdline.txt` for the memory cgroup. The name is deliberately not
tied to the hardware and the design generalises, but the bootstrap script does
not yet.

It also assumes a **home host behind NAT**. AdGuard publishes port 53 on every
host interface and Samba binds a LAN interface — do not clone this onto an
internet-facing VM without changing both.

<div align="center">
<img src="assets/architecture.webp" alt="Lares architecture" width="100%">
</div>

## What's in it

| Service | Role | Exposure |
|---|---|---|
| **AdGuard Home** | network DNS + ad blocking | DNS on the LAN; UI localhost only |
| **Syncthing** | continuous file/photo sync | localhost only |
| **Vaultwarden** | password manager | localhost only |
| **Uptime Kuma** | monitoring | localhost only |
| **ntfy** | push notifications to your phone | localhost only |
| **Samba** | SMB file share | LAN, one interface, SMB3 |
| **Tailscale** | private access to all of the above | — |
| **restic** | encrypted offsite backup | outbound |

Every web UI binds to `127.0.0.1` and is published **only** through
`tailscale serve`, with real certificates and tailnet-only reachability. Nothing
administrative is ever on the LAN.

## What happens when…

This is the part that makes Lares different from a Compose file.

| | |
|---|---|
| **the disk dies?** | Documented bare-metal reconstruction: `bootstrap.sh` → `restore.sh` → `compose up`. See [disaster recovery](docs/disaster-recovery.md). |
| **a SQLite service is mid-write during backup?** | Application-consistent snapshots via SQLite's own `.backup`, verified with `integrity_check`, promoted atomically. A failed vault snapshot **fails the job** rather than shipping stale data. |
| **an image updates unexpectedly?** | Every image pinned by digest. Upgrades are deliberate. |
| **the host disappears?** | Clients keep DNS via a second nameserver; password clients keep working from their encrypted local cache. |
| **the backup silently stops running?** | A push monitor with a 25h heartbeat notices, and ntfy tells your phone. |
| **you restore onto a tmpfs?** | `restore.sh` refuses. It checks the target filesystem and free space first. |
| **the machine only has 4 GB?** | Enforced memory ceilings — and a check that the kernel is *actually* enforcing them. |
| **another workload needs a quiet machine?** | `stack.sh quiesce` stops the service layer and reports what still draws power. |

Several of those exist because they went wrong first. The tmpfs guard was written
after a test restore consumed system RAM on the machine serving DNS to the house.

## Rebuild, don't repair

<div align="center">
<img src="assets/recovery.webp" alt="Lares disaster recovery" width="100%">
</div>

Three things must live **outside** the machine, or recovery is impossible:

1. **This repository** — reproducible configuration
2. **The encrypted offsite backup** — persistent data
3. **The recovery credentials** — unrecoverable secrets

That third one has a trap worth stating plainly: **Vaultwarden cannot be the sole
keeper of the backup password**, because Vaultwarden is *inside* the backup. You
would need the password to restore the vault that holds the password. Keep it on
paper, or in something you can reach from a phone while the house is on fire.

## Getting started

```sh
git clone https://github.com/AndreaBozzo/lares.git && cd lares
cp .env.example .env && $EDITOR .env      # identity, storage, network, backup target
sudo ./scripts/bootstrap.sh --check       # report what it would do
sudo ./scripts/bootstrap.sh               # provision the host
sudo tailscale up --accept-dns=false
docker compose up -d
```

`bootstrap.sh` is idempotent and states plainly what it cannot automate —
interactive logins, account creation, and anything needing a browser. It does not
pretend those are done.

## Design rules

- **Verify at the kernel, not in the config.** Raspberry Pi OS ships with the
  memory cgroup disabled, so Docker accepts `mem_limit` and silently discards it
  while `docker inspect` reports `Memory=0`. A limit you haven't confirmed is a
  comment.
- **Internal traffic uses internal names.** Tailnet MagicDNS names are not
  publicly resolvable and containers cannot resolve them. Service-to-service URLs
  use Docker service names. Getting this wrong yields a notification channel that
  reaches nobody, and looks fine until you need it.
- **Prefer structural boundaries to rules.** Service state sits outside the SMB
  share's path rather than being hidden by a veto directive.
- **A guard that has never failed is not a guard.** Every failure path here has
  been triggered deliberately at least once.

## Documentation

- [Disaster recovery](docs/disaster-recovery.md) — the full rebuild path

## License

MIT
