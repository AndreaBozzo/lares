#!/usr/bin/env bash
# Lares post-install verification: answer "is this actually working" in one
# command, without a human remembering eight of them.
#
#   ./scripts/verify.sh
#
# Checks the *behaviour*, not the configuration. A mem_limit in compose.yaml
# proves nothing if the kernel is discarding it; a monitor that exists proves
# nothing if it notifies a host nothing can resolve. Every check here looks at
# the running system.
#
# Exit code is the number of failures, so it is usable from cron or a monitor.
set -uo pipefail

REPO_DIR="$(cd "$(dirname "$0")/.." && pwd)"
if [ -r "$REPO_DIR/.env" ]; then
  # shellcheck disable=SC1091
  . "$REPO_DIR/.env"
fi
: "${STORAGE:=/srv/lares}"
: "${APPDATA:=/srv/lares/appdata}"
# Compose project name, from compose.yaml's `name:` key.
PROJECT=lares

PASS=0; FAIL=0; SKIP=0
ok()   { printf '  \033[32m✓\033[0m %s\n' "$1"; PASS=$((PASS+1)); }
bad()  { printf '  \033[31m✗\033[0m %s\n' "$1"; FAIL=$((FAIL+1)); }
skip() { printf '  \033[33m–\033[0m %s\n' "$1"; SKIP=$((SKIP+1)); }
say()  { printf '\n\033[1m%s\033[0m\n' "$1"; }

say "host"
if grep -qw memory /sys/fs/cgroup/cgroup.controllers 2>/dev/null; then
  ok "memory cgroup active (mem_limit is enforceable)"
else
  bad "memory cgroup MISSING -- Docker is silently discarding every mem_limit"
fi
[ -d "$STORAGE" ] && ok "storage root $STORAGE" || bad "storage root $STORAGE missing"
AVAIL=$(df -Pk "$STORAGE" 2>/dev/null | awk 'NR==2{print int($4/1048576)}')
[ -n "$AVAIL" ] && ok "free space: ${AVAIL} GiB" || skip "free space unknown"

say "containers"
if ! command -v docker >/dev/null 2>&1; then
  skip "docker not installed"
else
  while read -r name status; do
    [ -z "$name" ] && continue
    case "$status" in
      *healthy*)   ok "$name ($status)" ;;
      *starting*)  skip "$name still starting" ;;
      *)           bad "$name ($status)" ;;
    esac
  done < <(docker ps --filter "label=com.docker.compose.project=$PROJECT"              --format '{{.Names}} {{.Status}}' 2>/dev/null || true)

  # The limit as the KERNEL sees it, not as compose declares it.
  # Scoped to this compose project: Lares explicitly coexists with other
  # workloads, so an unrelated unlimited container must not fail OUR check.
  for c in $(docker ps --filter "label=com.docker.compose.project=$PROJECT"                --format '{{.Names}}' 2>/dev/null); do
    id=$(docker inspect "$c" --format '{{.Id}}' 2>/dev/null) || continue
    max=$(cat "/sys/fs/cgroup/system.slice/docker-$id.scope/memory.max" 2>/dev/null)
    case "$max" in
      ""|max) bad "$c has NO enforced memory limit" ;;
      *)      ok "$c capped at $((max/1024/1024)) MiB (kernel-enforced)" ;;
    esac
  done
fi

say "dns"
if command -v dig >/dev/null 2>&1; then
  dig +short +time=3 @127.0.0.1 example.com A >/dev/null 2>&1 \
    && ok "resolves through the local resolver" || bad "local resolver not answering"
  # A blocklisted domain is answered locally, so this works offline too.
  if [ "$(dig +short +time=3 @127.0.0.1 doubleclick.net A 2>/dev/null | head -1)" = "0.0.0.0" ]; then
    ok "filtering active (blocklisted domain -> 0.0.0.0)"
  else
    bad "filtering NOT active -- queries are being answered unfiltered"
  fi
else
  skip "dig not installed (apt install bind9-dnsutils)"
fi

say "file sharing"
if command -v ss >/dev/null 2>&1; then
  if ss -tln 2>/dev/null | grep -q ':445 '; then
    ss -tln 2>/dev/null | grep -q '0.0.0.0:445' \
      && bad "SMB bound to ALL interfaces -- should be loopback + LAN only" \
      || ok "SMB bound to specific interfaces only"
  else
    skip "SMB not listening"
  fi
  ss -tln 2>/dev/null | grep -q ':139 ' \
    && bad "legacy NetBIOS port 139 open (set 'smb ports = 445')" \
    || ok "port 139 closed"
fi

say "backup"
BE=/etc/lares/backup.env
if [ ! -r "$BE" ]; then
  bad "$BE unreadable -- backups cannot run (need root? try sudo)"
else
  set -a
  # Directive binds to the NEXT command, so it cannot share a line with `set -a`.
  # shellcheck disable=SC1090
  . "$BE"
  set +a
  ok "credentials present (repo: ${RESTIC_REPOSITORY:-unset})"
  if command -v restic >/dev/null 2>&1; then
    if LATEST=$(restic snapshots --tag lares --latest 1 --json 2>/dev/null \
        | python3 -c 'import sys,json,datetime;s=json.load(sys.stdin);print(s[0]["time"][:19]) if s else print("")' 2>/dev/null) \
       && [ -n "$LATEST" ]; then
      AGE=$(( ( $(date +%s) - $(date -d "$LATEST" +%s 2>/dev/null || echo 0) ) / 3600 ))
      [ "$AGE" -lt 48 ] \
        && ok "last snapshot ${AGE}h ago ($LATEST)" \
        || bad "last snapshot ${AGE}h ago -- backups may have stopped silently"
    else
      bad "cannot list snapshots (unreachable repo, or wrong password)"
    fi
  fi
  [ -f "$APPDATA/vaultwarden/db.sqlite3.bak" ] \
    && ok "verified vault snapshot on disk" \
    || bad "no vault snapshot -- backup.sh has not run successfully"
fi

say "scheduling"
for t in lares-backup.timer lares-backup-maintain.timer; do
  case "$(systemctl is-enabled "$t" 2>/dev/null)" in
    enabled)
      systemctl is-active "$t" >/dev/null 2>&1 \
        && ok "$t enabled and active" \
        || bad "$t enabled but NOT active (needs 'systemctl start', or a reboot)" ;;
    *) bad "$t not enabled" ;;
  esac
done

say "private network"
if command -v tailscale >/dev/null 2>&1; then
  tailscale status >/dev/null 2>&1 && ok "tailscale up" || bad "tailscale not authenticated"
  N=$(tailscale serve status 2>/dev/null | grep -c '^https' || echo 0)
  [ "$N" -gt 0 ] && ok "$N HTTPS endpoint(s) published to the tailnet" \
                 || bad "no tailscale serve routes -- admin UIs unreachable"
else
  skip "tailscale not installed"
fi

printf '\n\033[1m%d passed, %d failed, %d skipped\033[0m\n' "$PASS" "$FAIL" "$SKIP"
[ "$FAIL" -eq 0 ] && printf 'Lares looks healthy.\n' || printf 'Investigate the failures above.\n'
exit "$FAIL"
