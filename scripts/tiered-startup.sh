#!/usr/bin/env bash
# =============================================================================
# Tiered Startup — Stagger container startup on Privateer
# =============================================================================
# Prevents I/O thundering herd when all 30+ containers start simultaneously
# after a reboot. Stops all auto-started containers, then brings them up
# in tiers with delays between each group.
#
# Designed to run as a systemd service after docker.service.
# =============================================================================

set -euo pipefail

COMPOSE_DIR="/opt/suparr/machine2-arr"
LOG_TAG="TIERED-STARTUP"

LOGFILE="/opt/suparr/logs/tiered-startup.log"
mkdir -p "$(dirname "$LOGFILE")" 2>/dev/null || true
log() { echo "[$(date '+%H:%M:%S')] $LOG_TAG: $*" | tee -a "$LOGFILE"; }

wait_healthy() {
    local container="$1" timeout="${2:-60}"
    local start elapsed health
    start=$(date +%s)
    while true; do
        elapsed=$(( $(date +%s) - start ))
        [ "$elapsed" -ge "$timeout" ] && break
        health=$(docker inspect --format='{{if .State.Health}}{{.State.Health.Status}}{{else}}none{{end}}' "$container" 2>/dev/null || echo "missing")
        case "$health" in
            healthy) log "  $container is healthy"; return 0 ;;
            none)    return 0 ;;  # No healthcheck = assume ready
            missing) log "  $container not found"; return 1 ;;
        esac
        sleep 3
    done
    log "  WARNING: $container not healthy after ${timeout}s, continuing anyway"
}

start_containers() {
    for c in "$@"; do
        docker start "$c" 2>/dev/null && log "  Started $c" || log "  $c not present, skipping"
    done
}

# ── Main ─────────────────────────────────────────────────────────────────────

log "=== Tiered startup beginning ==="
log "Stopping all auto-started containers..."

# Stop everything gracefully. Using docker stop directly since compose stop
# needs COMPOSE_PROFILES and we want to catch ALL containers in this project.
cd "$COMPOSE_DIR"
set -a; source .env 2>/dev/null || true; set +a
docker compose stop --timeout 15 2>/dev/null || true
sleep 3

# Tier 1: Core infrastructure — VPN, remote access, health management, logging
log "── Tier 1: Infrastructure ──"
start_containers gluetun tailscale-privateer autoheal dozzle
wait_healthy gluetun 90
sleep 5

# Tier 2: Databases and indexers — needed before content managers
log "── Tier 2: Databases & Indexers ──"
start_containers immich-db immich-redis prowlarr flaresolverr
sleep 15

# Tier 3: Download clients — depend on VPN being up
log "── Tier 3: Download Clients ──"
start_containers qbittorrent sabnzbd unpackerr autobrr
sleep 10

# Tier 4: Content managers — heaviest I/O (library scanning on startup)
# Stagger these in sub-groups to avoid all hitting NFS at once
log "── Tier 4a: Primary content managers ──"
start_containers sonarr radarr
sleep 10

log "── Tier 4b: Secondary content managers ──"
start_containers lidarr whisparr bookshelf bazarr audiobookshelf
sleep 15

# Tier 5: Everything else — monitoring, utilities, webhooks
log "── Tier 5: Monitoring & Utilities ──"
# Use compose up to catch anything not explicitly named above
# This is idempotent — already-running containers are untouched
docker compose up -d 2>/dev/null || true

TOTAL=$(docker ps -q | wc -l)
log "=== Tiered startup complete — $TOTAL containers running ==="
