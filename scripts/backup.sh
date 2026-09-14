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
# shellcheck disable=SC1090
set -a; . "$ENV_FILE"; set +a

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
trap 'rc=$?; [ $rc -ne 0 ] && push down "backup failed (exit $rc) at line $FAIL_LINE"; exit $rc' EXIT

# Initialise on first run. `cat config` is the cheap "does this repo exist" probe.
if ! restic cat config >/dev/null 2>&1; then
  log "repository not initialised -- creating $RESTIC_REPOSITORY"
  restic init
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
  /srv/lares/appdata \
  /srv/lares/files/documents \
  /srv/lares/files/datasets \
  /srv/lares/files/sync \
  "$REPO_DIR" \
  /etc/samba/smb.conf \
  /etc/lares

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
