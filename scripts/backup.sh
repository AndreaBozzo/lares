#!/usr/bin/env bash
# lares backup. Run by the lares-backup.timer systemd unit, or by hand.
#
# Config and secrets live in /etc/lares/backup.env (root-only, NOT in git).
# That file sets RESTIC_REPOSITORY, RESTIC_PASSWORD, and for B2 the
# B2_ACCOUNT_ID / B2_ACCOUNT_KEY pair.
#
# WHY THIS EXISTS: /srv/lares is a single copy on the same USB SSD that boots
# the OS. There is no second disk. Without this, one disk failure loses the
# service state, the password vault, and everything synced here.
set -euo pipefail

# Derived, never configured: the repo path is knowable from argv[0]. It used to
# come from ${LARES_DIR}, which /etc/lares/backup.env does not define -- under
# `set -u` that killed every scheduled run with "unbound variable" before a
# single byte was written.
REPO_DIR="$(cd "$(dirname "$0")/.." && pwd)"
ENV_FILE=/etc/lares/backup.env
[ -r "$ENV_FILE" ] || { echo "FATAL: $ENV_FILE missing or unreadable" >&2; exit 1; }
set -a
# A shellcheck directive binds to the NEXT command. On a compound line it
# attached to `set -a`, not to the source, so SC1090 still fired.
# shellcheck disable=SC1090
. "$ENV_FILE"
set +a

: "${RESTIC_REPOSITORY:?not set in $ENV_FILE}"
: "${RESTIC_PASSWORD:?not set in $ENV_FILE}"

log() { printf '%s %s\n' "$(date -Is)" "$*"; }

START=$(date +%s)

# Uptime Kuma push monitor. Optional: unset means no reporting, which must not
# break the backup itself -- so every push is best-effort and never fatal.
push() { # push <up|down> <message>
  [ -n "${UPTIME_PUSH_URL:-}" ] || return 0
  curl -fsS --max-time 15 --get \
    --data-urlencode "status=$1" \
    --data-urlencode "msg=$2" \
    --data-urlencode "ping=$(( $(date +%s) - START ))" \
    "$UPTIME_PUSH_URL" >/dev/null 2>&1 || log "warning: uptime push failed (ignored)"
}

# Report failure immediately rather than waiting for the heartbeat to lapse.
# Without this, a backup that starts failing tonight is invisible for 25 hours.
#
# Two traps, not one: $LINENO inside an EXIT trap reports the trap's own line,
# so the ERR trap captures where it actually failed first. Verified by forcing
# a failure -- a single EXIT trap reported "line 1" for every error.
FAIL_LINE='?'
trap 'FAIL_LINE=$LINENO' ERR
# rc is assigned in the trap body below; shellcheck cannot see inside the
# single-quoted string, so SC2154 is a false positive here.
# shellcheck disable=SC2154
trap 'rc=$?; [ $rc -ne 0 ] && push down "backup failed (exit $rc) at line $FAIL_LINE"; exit $rc' EXIT

# A restic killed mid-run -- a cancelled restore drill, a reboot, an OOM --
# leaves its lock behind, and a lock is enough to make the probe below fail.
# Clearing stale locks FIRST matters: otherwise a leftover lock is reported as
# "cannot read repository", which sends you looking for a credentials or
# network fault that is not there. Observed live: a killed restore left three
# locks, and the nightly run then failed for a day while snapshots kept saving
# normally.
#
# `restic unlock` (without --remove-all) removes only locks restic considers
# stale: older than 30 minutes, or created on this host by a process that is
# gone. A running restic refreshes its lock every few minutes, so a healthy
# concurrent job is never removed. The units also carry Conflicts=, so the
# backup and maintenance jobs cannot overlap in the first place.
#
# Reported, never silent: locks needing removal on every run would mean
# something is killing restic regularly, and that is worth seeing.
if UNLOCKED=$(restic unlock 2>&1) && [ -n "$UNLOCKED" ]; then
  log "stale locks cleared: $UNLOCKED"
fi

# Refuse to initialise implicitly. "the repository does not exist" and "I
# cannot reach or decrypt the repository" look identical to `cat config`, and
# auto-creating on the second case silently starts a brand-new empty repository
# while the real backups sit unreachable -- and the monitor goes green.
#
# Initialise once, deliberately:  restic init
if ! restic cat config >/dev/null 2>&1; then
  log "FATAL: cannot read repository $RESTIC_REPOSITORY"
  log "Either it was never initialised (run 'restic init' once, by hand), or it"
  log "is unreachable / the password is wrong. Refusing to guess between those:"
  log "creating a new empty repository here would hide the real one."
  exit 1
fi

# Vaultwarden and Uptime Kuma both use SQLite in WAL mode. Copying a live
# db.sqlite3 plus its -wal/-shm mid-transaction can capture a torn state that
# restores corrupt -- unacceptable for a password vault. `.backup` takes a
# consistent snapshot through SQLite itself, holding the right locks.
# The -wal/-shm files are excluded below: they are only meaningful paired with
# the exact db they came from, and restoring a mismatched set is worse than
# not having them.
# snapshot_sqlite <db path> <required: yes|no>
#
# Writes to a .tmp, verifies it with integrity_check, and only then renames it
# over the previous snapshot -- rename within one filesystem is atomic, so the
# .bak is either the old good copy or the new good copy, never a half-written
# one. On failure the stale .bak is REMOVED: a previous day's snapshot getting
# silently included in today's backup while the job reports success is the
# exact failure this is meant to prevent. An absent file is visible; a stale
# one that looks current is not.
snapshot_sqlite() {
  db="$1"; required="$2"; tmp="$1.tmp"; final="$1.bak"
  if [ ! -f "$db" ]; then
    [ "$required" = yes ] && { log "ERROR: required database missing: $db"; return 1; }
    return 0
  fi
  rm -f "$tmp"
  if ! sqlite3 "$db" ".backup '$tmp'" 2>/dev/null; then
    log "ERROR: sqlite .backup failed for $db"
    rm -f "$tmp" "$final"
    [ "$required" = yes ] && return 1
    return 0
  fi
  if ! sqlite3 "$tmp" 'pragma integrity_check;' 2>/dev/null | grep -qx ok; then
    log "ERROR: integrity_check failed on snapshot of $db"
    rm -f "$tmp" "$final"
    [ "$required" = yes ] && return 1
    return 0
  fi
  mv -f "$tmp" "$final"
  log "sqlite snapshot ok: $final"
  return 0
}

log "snapshotting live databases"
# Vaultwarden is required: a backup that silently omits or staler the password
# vault is worse than no backup, because it will be trusted.
if ! snapshot_sqlite /srv/lares/appdata/vaultwarden/db.sqlite3 yes; then
  log "FATAL: refusing to back up without a verified Vaultwarden snapshot"
  exit 1
fi
# Uptime Kuma is monitoring config -- recoverable by hand, so a failure warns.
snapshot_sqlite /srv/lares/appdata/uptime-kuma/kuma.db no

log "starting backup"
restic backup \
  --verbose \
  --tag lares \
  --exclude-caches \
  --exclude '/srv/lares/files/media' \
  --exclude '/srv/lares/appdata/adguard/work/data/querylog*.json' \
  --exclude '/srv/lares/appdata/adguard/work/data/stats.db' \
  --exclude '/srv/lares/appdata/*/index.db' \
  --exclude '*.sqlite3-wal' \
  --exclude '*.sqlite3-shm' \
  --exclude '*.db-wal' \
  --exclude '*.db-shm' \
  --exclude '*.tmp' \
  --exclude '/etc/lares/backup.env' \
  /srv/lares/appdata \
  /srv/lares/files/documents \
  /srv/lares/files/datasets \
  /srv/lares/files/sync \
  "$REPO_DIR" \
  /etc/samba/smb.conf \
  /etc/lares

# Why /etc/lares/backup.env is excluded above.
#
# It holds the object-storage credential, and backing it up puts that
# credential inside the repository it protects. Circular in the direction that
# hurts: it cannot help a recovery, because you already need RESTIC_PASSWORD
# from somewhere else before you can decrypt a single byte -- so the copy in
# here is unreadable exactly when you would want it.
#
# What it does do is defeat an append-only key. Rotate to a credential without
# delete rights, and every older snapshot still carries the delete-capable one.
# The host holds RESTIC_PASSWORD and can read its own snapshots, so whatever
# compromises the host recovers a key that can erase the repository -- and the
# append-only credential protects nothing.
#
# The failure is invisible while it is happening: backups succeed, verification
# passes, and the protection is simply absent. Excluding it costs nothing,
# because the recovery path already has you retype these secrets by hand.
#
# Rotating a key therefore also means REVOKING the old one at the provider.
# Snapshots taken before this exclusion still contain it.

# Retention and pruning live in scripts/maintain.sh, run weekly, NOT here.
#
# Two reasons. First, `forget --prune` is destructive and needs delete rights on
# the repository; separating it is the precondition for ever giving this daily
# job an append-only B2 key, so a compromised Pi cannot erase its own backups.
# Second, pruning plus a data-verifying check every single night is far heavier
# than the risk warrants on a 21.6 Mbps uplink.
#
# The daily run still verifies structure, which is cheap and catches a corrupt
# index immediately. It does NOT re-read pack data -- maintain.sh does that.
log "verifying repository structure"
restic check

log "done"
restic snapshots --tag lares --latest 3

SNAP=$(restic snapshots --tag lares --latest 1 --json 2>/dev/null \
  | python3 -c 'import sys,json; s=json.load(sys.stdin); print(s[0]["short_id"] if s else "none")' 2>/dev/null || echo unknown)
push up "ok snapshot=$SNAP in $(( $(date +%s) - START ))s"
