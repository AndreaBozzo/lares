#!/usr/bin/env bash
# lares weekly repository maintenance: retention, prune, deep verification.
#
# Deliberately SEPARATE from backup.sh. `forget --prune` is the only part of the
# backup system that deletes data, so isolating it is what lets the daily job
# hold an append-only key while only this one carries destructive rights --
# restic's own recommended split for an untrusted backup client.
#
# CONSEQUENCE: once the host holds an append-only credential, this script
# cannot run there at all. It belongs on a trusted machine, with the admin
# credential, run by hand -- not on the host's weekly timer. See
# docs/initial-setup.md.
set -euo pipefail

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

# Say WHICH problem this is before restic says it badly. Without delete rights
# `forget --prune` fails partway with a provider authorisation error, after
# already having decided what to remove -- a confusing place to land, and one
# that reads like repository corruption rather than a deliberate boundary.
case "${RESTIC_REPOSITORY:-}" in
  b2:*)
    if command -v curl >/dev/null 2>&1 && [ -n "${B2_ACCOUNT_ID:-}" ]; then
      CAPS=$(curl -s --max-time 15 -u "$B2_ACCOUNT_ID:$B2_ACCOUNT_KEY" \
               https://api.backblazeb2.com/b2api/v3/b2_authorize_account 2>/dev/null)
      case "$CAPS" in
        *'"deleteFiles"'*) : ;;
        *'"capabilities"'*)
          log "FATAL: this credential cannot delete, so pruning is impossible here."
          log "That is by design: the backup host holds an append-only key so a"
          log "compromise cannot erase its backups. Run this from the trusted"
          log "machine that holds the admin credential instead."
          exit 1 ;;
      esac
    fi ;;
esac

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
