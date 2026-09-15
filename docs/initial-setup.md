# Initial setup

A step-by-step guide from a fresh machine to a working Lares install.

**No prior homelab experience assumed.** If you can copy and paste into a
terminal, you can do this.

> Rebuilding a machine you already had? Use
> [disaster recovery](disaster-recovery.md) instead.

---

## What you'll have at the end

- 📁 A network drive your computers can save files to
- 📵 Ads blocked on every device you own, at home and away
- 🔑 Your own password manager, on your own hardware
- 📷 Phone photos syncing automatically
- 💾 Everything backed up, encrypted, off the premises
- 📱 A text on your phone if any of it breaks

**Time:** about an hour. Most of it is waiting for things to download.
**Cost:** nothing, unless your backups exceed 10 GB (then roughly $0.50/month).

---

## Before you start

You need four things:

| | |
| :--- | :--- |
| 💻 **A small computer** | A Raspberry Pi 4 or 5 works well. This guide is tested on Raspberry Pi OS 64-bit. |
| 🔌 **A network cable** | Wi-Fi works but is worth avoiding. Plugged in is more reliable and faster. |
| ☁️ **A Tailscale account** | Free, at [tailscale.com](https://tailscale.com). This is what lets you reach your machine from anywhere, safely. |
| 🗄️ **A Backblaze B2 account** | Free for 10 GB, at [backblaze.com](https://www.backblaze.com/cloud-storage). This is where backups go. |

You'll also need to be able to log into your machine over SSH. If you flashed
Raspberry Pi OS with the official Imager, enable SSH and set a username there.

**A note on the commands below.** Lines starting with `sudo` run as
administrator; it may ask for your password. If a command fails, stop and read
the error — most of them say exactly what's wrong.

---

## Step 1 · Prepare the machine

⏱️ *10 minutes*

Log into your machine over SSH, then:

```sh
git clone https://github.com/AndreaBozzo/lares.git ~/lares
cd ~/lares
cp .env.example .env
nano .env
```

`nano` is a simple text editor. Fill in these lines, then press
**Ctrl+O**, **Enter**, **Ctrl+X** to save and quit:

| Setting | What to put |
| :--- | :--- |
| `PI_USER` | Your username. Run `whoami` in another terminal if unsure. |
| `PI_HOSTNAME` | A name for this machine, e.g. `lares`. |
| `PI_IFACE` | `eth0` if plugged in, `wlan0` for Wi-Fi. |
| `PI_GATEWAY` | Your router's address. Run `ip route \| grep default` — it's the number after `via`. |
| `PUID` / `PGID` | Run `id -u` and `id -g`. Usually both `1000`. |

Leave the rest alone for now. Then:

```sh
set -a; . ./.env; set +a
sudo ./scripts/bootstrap.sh --check
```

This only *reports* — it changes nothing. You'll see a list of `[ok]` and
`[TODO]` items. Now actually do it:

```sh
sudo ./scripts/bootstrap.sh
```

**If it says a reboot is required, reboot.** This matters more than it sounds:
until you do, the memory limits that stop one service eating the whole machine
are silently ignored.

```sh
sudo reboot
```

Wait a minute, log back in, and confirm:

```sh
cd ~/lares && set -a; . ./.env; set +a
sudo ./scripts/bootstrap.sh --check
```

✅ **Done when:** almost everything says `[ok]`. A few `[TODO]` lines about
Tailscale and passwords are expected — those are the next steps.

---

## Step 2 · Connect it to your private network

⏱️ *10 minutes*

Tailscale creates a private network between your devices. Your machine becomes
reachable from your phone or laptop anywhere in the world, without opening
anything to the public internet.

```sh
sudo tailscale up --accept-dns=false --hostname="$PI_HOSTNAME"
```

It prints a link. Open it in a browser and sign in.

> **Why `--accept-dns=false`?** This machine is about to *become* your DNS
> server. Without this flag it would try to ask itself for answers.

Now two things in the [Tailscale admin console](https://login.tailscale.com/admin/dns):

1. Go to **DNS → HTTPS Certificates** and click **Enable**.
   *Nothing later works without this, and it fails silently if you skip it.*
2. Note your machine's full name — something like `lares.tail1234.ts.net`.

Put that name into `.env`:

```sh
nano .env      # set PI_TAILNET_NAME to the name you just noted
set -a; . ./.env; set +a
```

Also install Tailscale on your **phone and laptop** now, signing in with the
same account. You'll need them shortly.

✅ **Done when:** `tailscale status` lists your machine and your phone.

---

## Step 3 · Set your file-share password

⏱️ *1 minute*

```sh
sudo smbpasswd -a "$PI_USER"
```

Type a password twice. This is separate from your login password — it's only
for accessing the network drive from Windows or macOS.

✅ **Done when:** it says "Added user".

---

## Step 4 · Set up backups

⏱️ *15 minutes*

**Do this before the password manager.** A vault with no backup is worse than
no vault.

### Create the storage

In [Backblaze](https://secure.backblaze.com/b2_buckets.htm):

1. **Create a Bucket** → give it a unique name → set it **Private**
2. Go to **Application Keys** → **Add a New Application Key**
3. Name it `lares`, and under *Allow access to Bucket* pick **the bucket you
   just made** — not "All"
4. Click create. **Copy both values now** — the key is shown only once

> **Why not the master key?** The master key can delete everything in your
> account, and it can create more keys. Scoping a key to one bucket contains
> the blast radius to that bucket.
>
> **What bucket scoping does not do:** it limits *which* bucket a key can
> reach, not *what it may do there*. A normal read-write key includes
> `deleteFiles`, so a compromised machine can still erase the backups in its
> own bucket. Verified against a real deployment: a key created exactly as
> above reported `deleteFiles`, `writeBuckets` and
> `writeBucketLifecycleRules`. Do not treat this key as protection against
> ransomware on the machine holding it. It protects the *rest* of your account.

### Optional: an append-only key

If you want the stronger boundary, create **two** keys instead of one, and give
the machine only the weak one:

| Key | Capabilities | Who holds it |
| :--- | :--- | :--- |
| `lares-daily` | `listBuckets`, `listFiles`, `readFiles`, `writeFiles` | the machine, in `/etc/lares/backup.env` |
| `lares-admin` | the above plus `deleteFiles` | you, on a trusted computer, used by hand |

The daily backup needs no delete rights. When restic is not authorised to
delete, its B2 backend hides files instead, so locks and removals still work
and the previous versions stay in the bucket, recoverable with the admin key.

`restic forget --prune` *does* need delete rights, so with this split
`scripts/maintain.sh` must run with the admin key rather than on its weekly
timer. Restic makes the same recommendation: run destructive maintenance from a
separate, trusted client.

> **Mind the lifecycle rule.** If the bucket is set to permanently delete
> hidden or older versions after N days, then anything an attacker hides
> becomes unrecoverable after N days. Keep N comfortably longer than the time
> you would take to notice.

### Generate a password for your backups

```sh
openssl rand -base64 32
```

Copy the output. You'll need it in a moment — **and again, later, in a
disaster.**

### Write it all down for the machine

```sh
sudo mkdir -p /etc/lares && sudo chmod 0700 /etc/lares
sudo nano /etc/lares/backup.env
```

Paste this, filling in your four values:

```ini
RESTIC_REPOSITORY=b2:<your-bucket-name>:lares
RESTIC_PASSWORD=<paste the random string from above>
B2_ACCOUNT_ID=<your keyID>
B2_ACCOUNT_KEY=<your applicationKey>
```

Save, then lock the file down:

```sh
sudo chmod 0600 /etc/lares/backup.env
```

### Create the backup repository

```sh
sudo -i
set -a; . /etc/lares/backup.env; set +a
restic init
exit
```

> 🛑 **Now write `RESTIC_PASSWORD` somewhere that is not this machine.**
>
> On paper is genuinely fine. In another password manager is fine.
>
> **Not** in the Vaultwarden you're about to install — that lives *inside* the
> backup. You'd need the password to unlock the vault holding the password.
> This is the single most common way people lose everything.

### Run the first backup

```sh
cd ~/lares && sudo ./scripts/backup.sh
```

✅ **Done when:** it ends with `done` and lists a snapshot.

---

## Step 5 · Start the services

⏱️ *10 minutes*

```sh
docker compose up -d
docker compose ps
```

All of them should say `running` or `healthy`. Now set each one up.

The admin pages are deliberately not reachable from your network — you reach
them through an SSH tunnel. **Open a second terminal** on your own computer and
run:

```sh
ssh -L 3000:127.0.0.1:3000 -L 3001:127.0.0.1:3001 -L 8384:127.0.0.1:8384 YOUR_USER@YOUR_MACHINE_NAME
```

Leave that terminal open. It forwards three admin pages to your own browser.

### 🛡️ AdGuard — ad blocking

Open **http://localhost:3000** and follow the wizard.

- **Admin Web Interface:** leave the port as **3000**. Changing it breaks things.
- **DNS server:** all interfaces, port 53
- Create a username and password
- Afterwards: **Settings → DNS settings → Upstream servers**, replace with:
  ```
  https://dns10.quad9.net/dns-query
  ```
  This encrypts your DNS lookups so your internet provider can't read them.

### 📊 Uptime Kuma — monitoring

Open **http://localhost:3001** and create an admin account. That's all for now.

### 🔄 Syncthing — file sync

Open **http://localhost:8384**.

- **Actions → Settings → GUI** → set a username and password
- Remove the "Default Folder" it created — it points somewhere that is not
  backed up

### 🔑 Vaultwarden — passwords

**Skip for now.** It needs HTTPS, which is the next step.

✅ **Done when:** AdGuard, Kuma and Syncthing all have accounts.

---

## Step 6 · Make the admin pages reachable properly

⏱️ *5 minutes*

Back in your machine's terminal:

```sh
sudo tailscale serve --bg              8384   # Syncthing
sudo tailscale serve --bg --https=8443 8080   # Vaultwarden
sudo tailscale serve --bg --https=8444 3000   # AdGuard
sudo tailscale serve --bg --https=8445 3001   # Uptime Kuma
sudo tailscale serve --bg --https=8446 8090   # ntfy
sudo tailscale serve status
```

The first one may ask you to approve it in a browser.

You can now close the SSH tunnel terminal. From any device signed into your
Tailscale account, these work:

| Address | What |
| :--- | :--- |
| `https://YOUR-NAME.ts.net` | Syncthing |
| `https://YOUR-NAME.ts.net:8443` | Vaultwarden |
| `https://YOUR-NAME.ts.net:8444` | AdGuard |
| `https://YOUR-NAME.ts.net:8445` | Uptime Kuma |

These have real certificates and are reachable **only** by your own devices.

### Now set up Vaultwarden

Lares ships with registration **closed**, so you must open it just long enough
to make your own account:

```sh
sed -i 's/SIGNUPS_ALLOWED: "false"/SIGNUPS_ALLOWED: "true"/' compose.yaml
docker compose up -d vaultwarden
```

Now open `https://YOUR-NAME.ts.net:8443` and create your account.

Then **immediately close it again**, so nobody else on your tailnet can:

```sh
sed -i 's/SIGNUPS_ALLOWED: "true"/SIGNUPS_ALLOWED: "false"/' compose.yaml
docker compose up -d vaultwarden
```

Check it really closed — this should print `400`:

```sh
curl -s -o /dev/null -w '%{http_code}
' -X POST   http://127.0.0.1:8080/identity/accounts/register   -H 'Content-Type: application/json' -d '{"email":"x@example.invalid"}'
```

Install the **Bitwarden** app on your phone and browser. Before logging in, tap
the settings gear and choose **Self-hosted**, with server URL
`https://YOUR-NAME.ts.net:8443`.

**Put your `RESTIC_PASSWORD` in it now** — as a second copy, alongside the one
you wrote on paper.

✅ **Done when:** you can open your vault from your phone.

---

## Step 7 · Get notified when things break

⏱️ *10 minutes*

```sh
printf 'NTFY_TOPIC=lares-%s\n' "$(tr -dc a-z0-9 </dev/urandom | head -c 16)" | sudo tee -a /etc/lares/backup.env
printf 'NTFY_URL=https://%s:8446\n' "$PI_TAILNET_NAME" | sudo tee -a /etc/lares/backup.env
printf 'NTFY_INTERNAL_URL=http://ntfy\n' | sudo tee -a /etc/lares/backup.env
sudo grep NTFY_TOPIC /etc/lares/backup.env
```

That last command prints your topic name — a random string that acts as a
password. Copy it.

On your **phone**: install the **ntfy** app → tap **+** → turn on **Use another
server** → enter:

- Server: `https://YOUR-NAME.ts.net:8446`
- Topic: the string you just copied

> Turn off battery optimisation for ntfy in Android settings, or alerts at 3am
> won't arrive.

### Connect the monitoring to it

```sh
sudo nano /etc/lares/kuma.env
```

```ini
KUMA_URL=http://127.0.0.1:3001
KUMA_USERNAME=<the username you made in step 5>
KUMA_PASSWORD=<the password you made in step 5>
```

```sh
sudo chmod 0600 /etc/lares/kuma.env
sudo .venv/bin/python scripts/kuma-monitors.py
```

This creates five monitors and connects them to your phone. It prints a **push
token** near the end — copy it and run:

```sh
printf 'UPTIME_PUSH_URL=http://127.0.0.1:3001/api/push/YOUR_TOKEN\n' | sudo tee -a /etc/lares/backup.env
```

### Test it for real

Don't trust this — check it:

```sh
docker compose stop vaultwarden
```

Within about two minutes your phone should buzz. Then:

```sh
docker compose start vaultwarden
```

✅ **Done when:** your phone actually received the alert.

---

## Step 8 · Block ads on all your devices

⏱️ *5 minutes*

In the [Tailscale admin console](https://login.tailscale.com/admin/dns) →
**Nameservers**:

1. **Add nameserver → Custom**, enter your machine's Tailscale IP
   (`tailscale ip -4` on the machine)
2. **Add nameserver → Quad9** (or Custom → `9.9.9.10`)
3. Turn on **Override local DNS**

> **Add the second one.** With only your machine listed, every device loses
> internet the moment it reboots or goes down. With two, they switch over
> automatically. A few ads slip through as a result — a fair trade for not
> breaking your phone.

✅ **Done when:** on your phone, ads disappear from a site that normally has them.

---

## Step 9 · Check your work

⏱️ *5 minutes*

```sh
cd ~/lares && sudo ./scripts/verify.sh
```

Everything should be green. If not, each failure says what's wrong.

Finally — and this is the step nobody does — prove your backup actually
restores, while nothing is broken:

```sh
sudo ./scripts/restore.sh --list
sudo ./scripts/restore.sh --target /srv/lares/files/backups/drill
```

That restores a copy somewhere harmless, touching nothing live.

> **A backup you have never restored is not a backup.** It's an assumption.

---

## Something went wrong

| Symptom | Cause |
| :--- | :--- |
| `verify.sh` says the memory cgroup is missing | You skipped the reboot in step 1. |
| `tailscale serve` hangs forever | HTTPS Certificates not enabled (step 2). |
| Vaultwarden won't log in | Its `DOMAIN` in `compose.yaml` must match the URL exactly, port included. |
| Alerts never arrive | The URL for Kuma must be `http://ntfy`, not the public one — containers can't resolve tailnet names. |
| Phone photos not syncing | Create the folder **on the phone** and share it to the machine, not the other way round. |
| Can't reach `machine.local` | Normal once Tailscale DNS is on. Use the Tailscale name. |

Still stuck? Open an issue — include the output of `sudo ./scripts/verify.sh`.
