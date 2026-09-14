#!/usr/bin/env bash
# lares weekly repository maintenance: retention, prune, deep verification.
#
# Deliberately SEPARATE from backup.sh. `forget --prune` is the only part of the
# backup system that deletes data, so isolating it means the daily job can later
# hold an append-only B2 key while only this one carries destructive rights --
# restic's own recommended split for an untrusted backup client.
#
# Until that key split happens, this is still worth separating: it keeps the
# nightly run light, and makes "what can delete my backups?" a one-file answer.
set -euo pipefail

ENV_FILE=/etc/lares/backup.env
[ -r "$ENV_FILE" ] || { echo "FATAL: $ENV_FILE missing or unreadable" >&2; exit 1; }
# shellcheck disable=SC1090
set -a; . "$ENV_FILE"; set +a

: "${RESTIC_REPOSITORY:?not set in $ENV_FILE}"
: "${RESTIC_PASSWORD:?not set in $ENV_FILE}"

log() { printf '%s %s\n' "$(date -Is)" "$*"; }
START=$(date +%s)

log "repository: $RESTIC_REPOSITORY"
log "snapshots before:"
restic snapshots --tag lares --compact 2>/dev/null | tail -3

log "applying retention (7 daily, 4 weekly, 6 monthly)"
restic forget \
  --tag lares \
  --keep-daily 7 \
  --keep-weekly 4 \
  --keep-monthly 6 \
  --prune

# Re-reads and re-hashes a slice of real pack data. An index-only check proves
# the repository is self-consistent, not that the bytes are still readable --
# those are different claims, and only this one survives bit rot or a truncated
# upload.
log "deep verification (re-reading 10% of pack data)"
restic check --read-data-subset=10%

log "done in $(( $(date +%s) - START ))s"
restic snapshots --tag lares --compact 2>/dev/null | tail -3
restic stats --mode raw-data 2>/dev/null | tail -4
