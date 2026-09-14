#!/usr/bin/env bash
# lares bootstrap: take a fresh Raspberry Pi OS install to the point where
# `docker compose up -d` and scripts/restore.sh will work.
#
#   sudo ./scripts/bootstrap.sh          provision
#   sudo ./scripts/bootstrap.sh --check   report state, change nothing
#
# Idempotent: safe to re-run. Every step reports what it found before acting.
#
# WHAT THIS DOES NOT DO, because it cannot:
#   - authenticate Tailscale (interactive; prints the login URL)
#   - set the Samba password (interactive; run smbpasswd afterwards)
#   - create /etc/lares/*.env secrets (you restore or retype those)
#   - create Vaultwarden / Uptime Kuma accounts (browser)
# The disaster-recovery doc covers those. See docs/disaster-recovery.md.
set -euo pipefail

REPO_DIR="$(cd "$(dirname "$0")/.." && pwd)"
CHECK_ONLY=false
[ "${1:-}" = "--check" ] && CHECK_ONLY=true

# shellcheck disable=SC1091
. "$REPO_DIR/.env"

say()  { printf '\n\033[1m=== %s ===\033[0m\n' "$1"; }
ok()   { printf '  [ok]   %s\n' "$1"; }
todo() { printf '  [TODO] %s\n' "$1"; }
act()  { printf '  [do]   %s\n' "$1"; }

run() { # run <description> <command...>
  if $CHECK_ONLY; then todo "$1"; else act "$1"; shift; "$@"; fi
}

[ "$(id -u)" -eq 0 ] || { echo "FATAL: run with sudo" >&2; exit 1; }

# --- preflight ------------------------------------------------------------
say "preflight"
ARCH=$(dpkg --print-architecture)
[ "$ARCH" = "arm64" ] || echo "  WARNING: arch is $ARCH, expected arm64"
ok "arch=$ARCH  user=$PI_USER  storage=$STORAGE"
id "$PI_USER" >/dev/null 2>&1 || { echo "FATAL: user $PI_USER does not exist" >&2; exit 1; }
REAL_UID=$(id -u "$PI_USER"); REAL_GID=$(id -g "$PI_USER")
ok "uid=$REAL_UID gid=$REAL_GID"
# Two sources of truth is one too many: containers run as the PUID/PGID in
# .env, while the storage tree is owned by the real user. If they disagree,
# every container write lands unwritable by the share, and it surfaces later.
if [ "${PUID:-$REAL_UID}" != "$REAL_UID" ] || [ "${PGID:-$REAL_GID}" != "$REAL_GID" ]; then
  echo "FATAL: .env says PUID=${PUID:-unset} PGID=${PGID:-unset}, but $PI_USER is" >&2
  echo "$REAL_UID:$REAL_GID. Containers would write files the share cannot modify." >&2
  echo "Set PUID=$REAL_UID and PGID=$REAL_GID in .env." >&2
  exit 1
fi
ok "PUID/PGID in .env match $PI_USER"

# --- packages -------------------------------------------------------------
say "packages"
# bind9-dnsutils, not dnsutils: on Debian 13 the latter is a transitional
# package that is NOT installed even when dig is present, so checking for it
# makes this script report work that does not need doing, every single run.
PKGS="samba smbclient restic sqlite3 bind9-dnsutils unattended-upgrades python3-venv curl ca-certificates"
MISSING=""
for p in $PKGS; do dpkg -s "$p" >/dev/null 2>&1 || MISSING="$MISSING $p"; done
if [ -n "$MISSING" ]; then
  run "install:$MISSING" sh -c "apt-get update -qq && DEBIAN_FRONTEND=noninteractive apt-get install -y -qq $MISSING"
else
  ok "all present"
fi

# A `docker` binary on PATH does NOT mean Docker is installed here: WSL and
# some desktop setups leave a shim that reports no version and creates no
# docker group. Ask for a version and require an answer.
DOCKER_VER=$(docker --version 2>/dev/null | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -1 || true)
if [ -n "$DOCKER_VER" ]; then
  ok "docker $DOCKER_VER"
else
  command -v docker >/dev/null 2>&1 && echo "  note: a docker binary exists but reports no version -- treating as absent"
  run "install docker via get.docker.com" sh -c "curl -fsSL https://get.docker.com | sh"
fi
# Group membership is separate from installation: an existing install with the
# user outside the group fails much later, as a confusing permission error.
if ! getent group docker >/dev/null 2>&1; then
  run "create docker group" groupadd -f docker
fi
if id -nG "$PI_USER" 2>/dev/null | grep -qw docker; then
  ok "$PI_USER in docker group"
else
  run "add $PI_USER to docker group" usermod -aG docker "$PI_USER"
  $CHECK_ONLY || echo "  note: group change needs a new login session to take effect"
fi

# --- memory cgroup --------------------------------------------------------
# Raspberry Pi OS boots WITHOUT the memory controller, so Docker silently
# discards every mem_limit and reports Memory=0. This is the single highest
# value line in this script on a 4 GB box.
say "memory cgroup"
CMDLINE=/boot/firmware/cmdline.txt
if grep -q memory /sys/fs/cgroup/cgroup.controllers 2>/dev/null; then
  ok "memory controller active"
elif grep -q "cgroup_enable=memory" "$CMDLINE" 2>/dev/null; then
  ok "configured in cmdline.txt -- REBOOT REQUIRED to take effect"
else
  run "append cgroup_enable=memory cgroup_memory=1 to $CMDLINE" sh -c \
    "cp '$CMDLINE' '$CMDLINE.bak.\$(date +%s)'; sed -i '1 s/\$/ cgroup_enable=memory cgroup_memory=1/' '$CMDLINE'"
  $CHECK_ONLY || { [ "$(grep -c 'cgroup_enable=memory' "$CMDLINE")" = 1 ] || { echo "FATAL: cmdline edit did not apply exactly once"; exit 1; }; }
  echo "  >> REBOOT REQUIRED before mem_limit is enforced <<"
fi

# --- storage tree ---------------------------------------------------------
say "storage tree"
for d in files files/documents files/datasets files/media files/photos files/backups files/sync files/sync/laptop files/sync/desktop files/sync/phone; do
  if [ -d "$STORAGE/$d" ]; then ok "$STORAGE/$d"
  else run "create $STORAGE/$d" install -d -o "$PI_USER" -g "$PI_USER" -m 2775 "$STORAGE/$d"; fi
done
for d in appdata appdata/syncthing appdata/adguard appdata/adguard/work appdata/adguard/conf appdata/vaultwarden appdata/uptime-kuma; do
  if [ -d "$STORAGE/$d" ]; then ok "$STORAGE/$d"
  else run "create $STORAGE/$d (0700)" install -d -o "$PI_USER" -g "$PI_USER" -m 0700 "$STORAGE/$d"; fi
done

# --- samba ----------------------------------------------------------------
say "samba"
# smb.conf ships as a TEMPLATE with @TOKENS@, rendered here. Samba's own
# substitution syntax is %U / %$(envvar) -- it does NOT expand shell ${VAR},
# so a config containing ${PI_USER} would put that literal string in
# `valid users` and silently deny every login.
if [ -f "$REPO_DIR/config/smb.conf" ]; then
  RENDERED=$(mktemp)
  sed -e "s|@LARES_USER@|$PI_USER|g"       -e "s|@LARES_IFACE@|$PI_IFACE|g"       -e "s|@LARES_HOSTNAME@|$PI_HOSTNAME|g"       "$REPO_DIR/config/smb.conf" > "$RENDERED"
  if grep -q '@LARES_[A-Z]*@' "$RENDERED"; then
    rm -f "$RENDERED"; echo "FATAL: unrendered token left in smb.conf" >&2; exit 1
  fi
  if cmp -s "$RENDERED" /etc/samba/smb.conf; then ok "smb.conf already current"
  elif $CHECK_ONLY; then todo "install rendered smb.conf"
  else
    act "install rendered smb.conf"
    install -o root -g root -m 0644 "$RENDERED" /etc/samba/smb.conf
    # Refuse to continue on a config Samba itself rejects.
    testparm -s /etc/samba/smb.conf >/dev/null 2>&1 || { echo "FATAL: testparm rejected the rendered smb.conf" >&2; exit 1; }
  fi
  rm -f "$RENDERED"
fi
# Debian enables samba-ad-dc (an Active Directory DC) on install -- wrong
# service entirely for a standalone file server.
if [ "$(systemctl is-enabled samba-ad-dc.service 2>&1)" = "masked" ]; then ok "samba-ad-dc masked"
else run "mask samba-ad-dc" sh -c "systemctl disable --now samba-ad-dc.service 2>/dev/null; systemctl mask samba-ad-dc.service 2>/dev/null; true"; fi
if systemctl is-active nmbd.service >/dev/null 2>&1; then
  run "disable nmbd (NetBIOS off)" sh -c "systemctl disable --now nmbd.service 2>/dev/null; true"
else ok "nmbd inactive"; fi
if systemctl is-active smbd.service >/dev/null 2>&1; then ok "smbd active"
else run "enable smbd" sh -c "systemctl enable --now smbd.service"; fi
# pdbedit lists Samba accounts; absence means the share will reject logins.
if pdbedit -L 2>/dev/null | grep -q "^$PI_USER:"; then ok "samba account for $PI_USER exists"
else todo "set the share password: sudo smbpasswd -a $PI_USER"; fi

# --- hardening ------------------------------------------------------------
say "hardening"
if systemctl is-enabled rpcbind.socket >/dev/null 2>&1; then
  run "mask rpcbind (listens on :111 with no NFS)" sh -c "systemctl disable --now rpcbind.socket rpcbind.service 2>/dev/null; systemctl mask rpcbind.socket rpcbind.service 2>/dev/null; true"
else ok "rpcbind already masked/absent"; fi
# A box with no console must never reboot itself unattended.
if systemctl is-active unattended-upgrades >/dev/null 2>&1 \
   && grep -q 'Automatic-Reboot "false"' /etc/apt/apt.conf.d/51-no-auto-reboot 2>/dev/null; then
  ok "unattended-upgrades active, auto-reboot disabled"
else
  run "unattended-upgrades, no auto-reboot" sh -c \
    "printf 'Unattended-Upgrade::Automatic-Reboot \"false\";\n' > /etc/apt/apt.conf.d/51-no-auto-reboot; systemctl enable --now unattended-upgrades"
fi
if [ "$(systemctl get-default)" = "multi-user.target" ]; then ok "headless boot target"
else run "set multi-user.target (frees the desktop's RAM)" systemctl set-default multi-user.target; fi

# --- tailscale ------------------------------------------------------------
say "tailscale"
if command -v tailscale >/dev/null 2>&1; then
  ok "installed: $(tailscale version | head -1)"
  if tailscale status >/dev/null 2>&1; then ok "authenticated"
  else todo "authenticate: sudo tailscale up --accept-dns=false --hostname=$PI_HOSTNAME"; fi
else
  run "install tailscale" sh -c "curl -fsSL https://tailscale.com/install.sh | sh"
  todo "authenticate: sudo tailscale up --accept-dns=false --hostname=$PI_HOSTNAME"
fi
# --accept-dns=false matters: this host RUNS the tailnet's DNS resolver, so
# accepting tailnet DNS would point it at itself.
todo "tailscale serve routes: see docs/disaster-recovery.md"

# --- systemd units --------------------------------------------------------
say "systemd units"
# systemd cannot expand variables, so the units ship with a literal
# @LARES_DIR@ token that is rendered here at install time. Shipping a unit with
# ${LARES_DIR} in ExecStart would silently fail to start.
for u in lares-backup.service lares-backup.timer lares-backup-maintain.service lares-backup-maintain.timer; do
  [ -f "$REPO_DIR/systemd/$u" ] || continue
  RENDERED=$(mktemp)
  sed "s|@LARES_DIR@|$REPO_DIR|g" "$REPO_DIR/systemd/$u" > "$RENDERED"
  if cmp -s "$RENDERED" "/etc/systemd/system/$u"; then
    ok "$u already current"; rm -f "$RENDERED"; continue
  fi
  if $CHECK_ONLY; then
    todo "install $u (rendering @LARES_DIR@ -> $REPO_DIR)"; rm -f "$RENDERED"; NEED_RELOAD=1; continue
  fi
  act "install $u"
  install -o root -g root -m 0644 "$RENDERED" "/etc/systemd/system/$u"
  rm -f "$RENDERED"
  grep -q '@LARES_DIR@' "/etc/systemd/system/$u" && { echo "FATAL: token left unrendered in $u"; exit 1; }
  NEED_RELOAD=1
done
# Only reload and re-enable if something actually changed -- otherwise --check
# reports work on every run and stops being worth reading.
if [ "${NEED_RELOAD:-0}" = "1" ]; then
  run "daemon-reload" systemctl daemon-reload
else
  ok "systemd units unchanged"
fi
TIMERS_OK=1
for t in lares-backup.timer lares-backup-maintain.timer; do
  systemctl is-enabled "$t" >/dev/null 2>&1 && systemctl is-active "$t" >/dev/null 2>&1 || TIMERS_OK=0
done
if [ "$TIMERS_OK" = "1" ]; then
  ok "backup timers enabled and active"
else
  run "enable + start backup timers" sh -c "systemctl enable --now lares-backup.timer lares-backup-maintain.timer"
fi
todo "secrets are NOT restored by this script: /etc/lares/backup.env (restic+B2) and kuma.env"

# --- python venv ----------------------------------------------------------
say "python venv (uptime kuma monitors)"
if [ -x "$REPO_DIR/.venv/bin/python" ]; then ok ".venv present"
else run "create venv + uptime-kuma-api" sh -c \
  "python3 -m venv '$REPO_DIR/.venv' && '$REPO_DIR/.venv/bin/pip' install -q 'uptime-kuma-api==1.2.1' && chown -R $PI_USER:$PI_USER '$REPO_DIR/.venv'"; fi

say "next steps"
cat <<EOF
  1. reboot if the cgroup step said so, then re-run --check to confirm
  2. sudo tailscale up --accept-dns=false --hostname=$PI_HOSTNAME
  3. restore or recreate /etc/lares/backup.env  (needs RESTIC_PASSWORD)
  4. ./scripts/restore.sh            <-- brings back appdata + documents
  5. docker compose up -d
  6. sudo smbpasswd -a $PI_USER
  7. tailscale serve routes, Kuma monitors: docs/disaster-recovery.md
EOF
