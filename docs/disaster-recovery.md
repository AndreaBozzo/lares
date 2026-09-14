# Disaster recovery

<div align="center">
<img src="../assets/recovery.webp" alt="Lares disaster recovery runbook" width="100%">
</div>

Rebuilding the host from nothing: a blank disk, this repository, the offsite
restic repository, and two credentials you must hold **outside** the machine.

> **Acceptance test**
> blank machine + repo + offsite backup + recovery credentials → working host

**Time:** ~30 minutes of attention, plus however long your backup takes to
download. **Prerequisites:** the two secrets below. Without them, stop — nothing
later in this document will work.

---

## ⚠️ First: the two things that are *not* recoverable

Everything else here can be rebuilt. These cannot, because they are the keys to
the backup itself:

| Secret | Why it cannot be recovered from the backup |
|---|---|
| `RESTIC_PASSWORD` | Decrypts the repository. Without it the backup is noise. |
| B2 `keyID` + `applicationKey` | Reaches the repository at all. Regenerable from the Backblaze account, if you can still log into that. |

**These must live somewhere independent of the Pi.** Vaultwarden is *inside*
the backup, so storing them only there is circular: you would need the restic
password to restore the vault that holds the restic password. Keep them on
paper, or in an account you can reach from a phone with the house on fire.

A Bitwarden client that has already synced holds an offline encrypted copy of
the vault, which may save you — but that is luck, not a recovery plan.

## The path

```
flash Raspberry Pi OS (64-bit, arm64)
  └─ create the user, enable SSH
       └─ git clone this repo
            └─ sudo ./scripts/bootstrap.sh          <- host packages, storage, samba, docker
                 └─ reboot            (memory cgroup)
                      └─ tailscale up
                           └─ recreate /etc/lares/backup.env
                                └─ sudo ./scripts/restore.sh --confirm
                                     └─ docker compose up -d
                                          └─ tailscale serve routes
                                               └─ smbpasswd, Kuma monitors
```

## Step 1 · Host

Flash Raspberry Pi OS 64-bit. Create the user you will name in `.env` as `PI_USER`, enable SSH, boot it.

```sh
git clone <this repo> ~/lares && cd ~/lares
cp .env.example .env && $EDITOR .env    # see below -- bootstrap needs this
sudo ./scripts/bootstrap.sh --check     # report only
sudo ./scripts/bootstrap.sh             # provision
```

**`.env` is gitignored, so a fresh clone has none** and `bootstrap.sh` will not
run without it. It contains no secrets, only topology, so it is reconstructible
by hand in a couple of minutes -- but you must do it before bootstrap, not
after. If you keep a copy anywhere, keep it with your recovery credentials.

`bootstrap.sh` installs packages and Docker, enables the **memory cgroup**
(Raspberry Pi OS ships with it off, which makes Docker silently discard every
`mem_limit`), builds the storage tree with correct ownership, installs the
Samba config, masks `samba-ad-dc` and `rpcbind`, enables unattended-upgrades
without auto-reboot, sets the headless boot target, and installs the systemd
timers.

**Reboot** if it says the cgroup step requires it, then re-run `--check`.

## Step 2 · Private network

```sh
sudo tailscale up --accept-dns=false --hostname="$PI_HOSTNAME"
```

`--accept-dns=false` is not optional: this host *runs* the tailnet's DNS
resolver, so accepting tailnet DNS points it at itself.

## Step 3 · The credentials you kept offline

```sh
sudo mkdir -p /etc/lares && sudo chmod 0700 /etc/lares
sudo nano /etc/lares/backup.env
```

```
RESTIC_REPOSITORY=b2:CHANGE-ME-bucket:lares
RESTIC_PASSWORD=<from your offline copy>
B2_ACCOUNT_ID=<keyID>
B2_ACCOUNT_KEY=<applicationKey>
UPTIME_PUSH_URL=            # refill after Kuma is back
```

```sh
sudo chmod 0600 /etc/lares/backup.env
sudo ./scripts/restore.sh --list        # proves the credentials work
```

## Step 4 · Restore

```sh
sudo ./scripts/restore.sh --target /srv/lares/files/backups/check   # inspect first
sudo ./scripts/restore.sh --confirm             # in place
```

`--confirm` stops the stack before writing, because restoring a SQLite file
under a running Vaultwarden corrupts it. Afterwards it promotes
`db.sqlite3.bak` over `db.sqlite3` and runs `integrity_check`.

**Why `.bak` and not the live file**: `backup.sh` takes a consistent snapshot
through SQLite itself, with locks held. The live `db.sqlite3` in the same
snapshot was copied while Vaultwarden was writing and may be torn. The `-wal`
and `-shm` files are excluded from backups entirely — they are only meaningful
paired with the exact database they came from.

## Step 5 · Services

```sh
docker compose up -d
docker compose ps
```

Images are pinned by digest, so this brings back the *same* versions, not
whatever is current. Then re-establish the HTTPS routes:

```sh
sudo tailscale serve --bg              8384   # Syncthing (root, :443)
sudo tailscale serve --bg --https=8443 8080    # Vaultwarden
sudo tailscale serve --bg --https=8444 3000    # AdGuard
sudo tailscale serve --bg --https=8445 3001    # Uptime Kuma
sudo tailscale serve --bg --https=8446 8090    # ntfy
```

Requires HTTPS certificates enabled in the Tailscale admin console
(DNS → HTTPS Certificates). Vaultwarden's `DOMAIN` in `compose.yaml` must match
its URL exactly, **port included**, or login fails with opaque errors.

## Step 6 · The manual tail

Not recoverable from backup — each needs a human:

- `sudo smbpasswd -a ${PI_USER}` — Samba account
- Tailscale admin → DNS → global nameservers (`<pi tailnet ip>`, `9.9.9.10`),
  Override local DNS. **Two nameservers, not one**: the second is what stops a
  Pi outage becoming a dead phone.
- Tailscale admin → approve the exit node, if you want it
- Kuma monitors: `sudo .venv/bin/python scripts/kuma-monitors.py` after
  recreating `/etc/lares/kuma.env`
- Copy the new Kuma push token into `UPTIME_PUSH_URL` in `backup.env`
- Syncthing: re-pair devices. Accept the folder the **phone** offers rather
  than creating one here — Android's own picker is what grants scoped storage
  access, and a folder created on this side sits at `remoteState: notSharing`.

## ✅ Verify — do not trust exit code 0

Do not trust "the command exited 0":

```sh
sudo sqlite3 /srv/lares/appdata/vaultwarden/db.sqlite3 'pragma integrity_check;'
sudo sqlite3 /srv/lares/appdata/vaultwarden/db.sqlite3 'select count(*) from users;'
dig +short @127.0.0.1 doubleclick.net          # expect 0.0.0.0
curl -s -o /dev/null -w '%{http_code}\n' http://127.0.0.1:8080/alive
```

## What a restore does *not* bring back

`/srv/lares/media` is excluded from backups by design (re-acquirable bulk).
Query logs and statistics are excluded too. Everything under `appdata`,
`documents`, `datasets`, `sync`, plus `/etc/lares` and the Samba config, is
included.
