#!/usr/bin/env bash
# lares restore from the offsite restic repository.
#
#   sudo ./scripts/restore.sh --list              show snapshots, change nothing
#   sudo ./scripts/restore.sh --dry-run           show what would be written
#   sudo ./scripts/restore.sh --target DIR        restore elsewhere to inspect
#   sudo ./scripts/restore.sh --confirm           restore IN PLACE over /srv
#
# In-place restore requires --confirm and stops the stack first: restoring a
# SQLite database under a running Vaultwarden would be overwritten or corrupted.
#
# Restoring the vault uses db.sqlite3.bak, the consistent snapshot taken by
# backup.sh -- not db.sqlite3, which was copied live. See RESTORING THE VAULT.
set -euo pipefail

REPO_DIR="$(cd "$(dirname "$0")/.." && pwd)"
if [ -r "$REPO_DIR/.env" ]; then
  # shellcheck disable=SC1091
  . "$REPO_DIR/.env"
fi
: "${STORAGE:=/srv/lares}"
ENV_FILE=/etc/lares/backup.env
MODE=list
TARGET=/

while [ $# -gt 0 ]; do
  case "$1" in
    --list) MODE=list ;;
    --dry-run) MODE=dry ;;
    --confirm) MODE=inplace ;;
    --target) MODE=target; TARGET="$2"; shift ;;
    *) echo "unknown option: $1" >&2; exit 2 ;;
  esac
  shift
done

[ "$(id -u)" -eq 0 ] || { echo "FATAL: run with sudo" >&2; exit 1; }
[ -r "$ENV_FILE" ] || {
  echo "FATAL: $ENV_FILE missing." >&2
  echo "Recreate it before restoring -- you need RESTIC_PASSWORD, which is NOT" >&2
  echo "recoverable from the backup itself. That is why it must be stored" >&2
  echo "somewhere independent of this machine." >&2
  exit 1
}
set -a
# A shellcheck directive binds to the NEXT command. On a compound line it
# attached to `set -a`, not to the source, so SC1090 still fired.
# shellcheck disable=SC1090
. "$ENV_FILE"
set +a
: "${RESTIC_REPOSITORY:?}" "${RESTIC_PASSWORD:?}"

log() { printf '%s %s\n' "$(date -Is)" "$*"; }

log "repository: $RESTIC_REPOSITORY"

case "$MODE" in
  list)
    restic snapshots --tag lares
    echo
    echo "Re-run with --dry-run, --target <dir>, or --confirm."
    ;;
  dry)
    restic restore latest --target /tmp/pi-restore-dryrun --dry-run --verbose 2>&1 | tail -20
    ;;
  target)
    mkdir -p "$TARGET"
    # Guard against restoring into RAM. /tmp on Raspberry Pi OS is a tmpfs, so
    # a naive `--target /tmp/...` writes the entire repository into memory and
    # will OOM a 4 GB box long before it finishes. Learned the hard way: a test
    # restore drove available memory from 3.3 GiB to 999 MiB before being
    # killed, with DNS for the whole tailnet running on the same machine.
    FSTYPE=$(stat -f -c %T "$TARGET" 2>/dev/null || echo unknown)
    case "$FSTYPE" in
      tmpfs|ramfs)
        echo "FATAL: $TARGET is $FSTYPE -- that is RAM, not disk." >&2
        echo "Pick a path on real storage, e.g. $STORAGE/backups/restore-check" >&2
        exit 1 ;;
    esac

    # Refuse if the restore obviously will not fit.
    NEED_KB=$(restic stats latest --mode restore-size --json 2>/dev/null \
      | python3 -c 'import sys,json; print(int(json.load(sys.stdin)["total_size"]/1024))' 2>/dev/null || echo 0)
    AVAIL_KB=$(df -Pk "$TARGET" | awk 'NR==2{print $4}')
    if [ "$NEED_KB" -gt 0 ] && [ "$NEED_KB" -gt "$AVAIL_KB" ]; then
      echo "FATAL: need $((NEED_KB/1024)) MiB, only $((AVAIL_KB/1024)) MiB free at $TARGET" >&2
      exit 1
    fi
    log "target $TARGET ($FSTYPE): need $((NEED_KB/1024)) MiB, have $((AVAIL_KB/1024)) MiB"

    log "restoring to $TARGET (nothing in place is touched)"
    restic restore latest --target "$TARGET"
    log "done -- inspect $TARGET before any in-place restore"
    ;;
  inplace)
    log "IN-PLACE restore requested"
    if command -v docker >/dev/null 2>&1 && [ -f "$REPO_DIR/compose.yaml" ]; then
      log "stopping the stack first (restoring a live SQLite db corrupts it)"
      # Fail closed: restoring over a live SQLite database corrupts it, so a
      # failed stop must abort rather than proceed. `|| true` here contradicted
      # the entire point of the restore path.
      if ! (cd "$REPO_DIR" && docker compose stop); then
        echo "FATAL: could not stop the stack; refusing to restore over live databases" >&2
        exit 1
      fi
    fi
    # NEVER restore /etc/lares/backup.env over itself. You reached this point by
    # reconstructing working credentials -- possibly a NEW B2 key, because the
    # old one was revoked or lost with the machine. Restoring the backed-up copy
    # would overwrite those working credentials with the dead ones, and the next
    # scheduled backup would fail. The file that opened the repository is
    # authoritative; the copy inside it is history.
    restic restore latest --target / --exclude /etc/lares/backup.env
    log "restored. Promoting consistent SQLite snapshots over the live copies:"
    # Vaultwarden required, Kuma may degrade -- the same asymmetry backup.sh
    # enforces. A password vault that restores "with warnings" is not restored.
    RC=0
    for entry in \
      "/srv/lares/appdata/vaultwarden/db.sqlite3:required" \
      "/srv/lares/appdata/uptime-kuma/kuma.db:optional"; do
      req="${entry##*:}"; pair="${entry%%:*}"
      if [ -f "$pair.bak" ]; then
        # The .bak was taken through SQLite with locks held; the live file in
        # the snapshot was copied mid-write and may be torn.
        rm -f "$pair-wal" "$pair-shm"
        cp -f "$pair.bak" "$pair"
        if sqlite3 "$pair" 'pragma integrity_check;' 2>/dev/null | grep -qx ok; then
          log "  ok: $pair restored from verified snapshot"
        else
          log "  ERROR: $pair failed integrity_check after restore"
          [ "$req" = required ] && RC=1
        fi
      else
        log "  ERROR: no verified snapshot (.bak) for $pair"
        [ "$req" = required ] && RC=1
      fi
    done
    if [ "$RC" -ne 0 ]; then
      echo "FATAL: a required database did not restore verifiably. Do NOT start" >&2
      echo "the stack -- starting Vaultwarden on a bad database can overwrite the" >&2
      echo "good copy still in the repository." >&2
      exit 1
    fi
    log "start the stack when ready: docker compose up -d"
    ;;
esac
