#!/usr/bin/env bash
# lares stack control. Run on pi5 from ~/lares.
#
#   ./scripts/stack.sh up      start the home stack
#   ./scripts/stack.sh stop    stop it, leaving the other workload untouched
#   ./scripts/stack.sh quiesce stop it AND report what is still running,
#                              for a clean power/benchmark baseline
#   ./scripts/stack.sh status  what is up, and what it is costing in RAM
set -euo pipefail
cd "$(dirname "$0")/.."

case "${1:-status}" in
  up)
    docker compose up -d
    ;;
  stop)
    docker compose stop
    ;;
  down)
    docker compose down
    ;;
  quiesce)
    # The published the other workload numbers rest on a ~3.0 W idle floor. Anything left
    # running here contaminates a re-measurement, so name it rather than assume.
    docker compose stop
    echo "--- lares stopped. Still running: ---"
    docker ps --format '  {{.Names}} ({{.Image}})'
    echo "--- host services that also draw power: ---"
    for s in smbd tailscaled docker; do
      printf '  %-12s %s\n' "$s" "$(systemctl is-active "$s" 2>&1)"
    done
    echo "Stop smbd/tailscaled too for a true idle baseline."
    ;;
  status)
    docker compose ps
    echo "--- memory ---"
    free -h | head -2
    echo "--- per-container ---"
    docker stats --no-stream --format \
      'table {{.Name}}\t{{.MemUsage}}\t{{.MemPerc}}\t{{.CPUPerc}}'
    ;;
  *)
    echo "usage: $0 {up|stop|down|quiesce|status}" >&2; exit 2
    ;;
esac
