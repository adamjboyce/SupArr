#!/usr/bin/env bash
# =============================================================================
# Container Watchdog — detect and recover dead containers after updates
# =============================================================================
# Runs on the host via cron (not inside a container). Checks all compose
# services for exited containers and brings them back with `docker compose up`.
# Alerts Discord on recovery or persistent failure.
#
# Install (run once):
#   crontab -e
#   # Run 15 min after Watchtower (5:00am), then every 30 min as safety net
#   15 5 * * * /opt/suparr/scripts/container-watchdog.sh
#   */30 * * * * /opt/suparr/scripts/container-watchdog.sh --quiet
#
# The --quiet flag suppresses Discord alerts for routine "all healthy" checks.
# Only the 5:15am post-Watchtower run sends recovery alerts.
# =============================================================================
set -euo pipefail

COMPOSE_DIR="${COMPOSE_DIR:-/opt/suparr/machine2-arr}"
DISCORD_WEBHOOK_URL="${DISCORD_WEBHOOK_URL:-}"
QUIET=false

# Load .env for Discord webhook if not set
if [ -z "$DISCORD_WEBHOOK_URL" ] && [ -f "${COMPOSE_DIR}/.env" ]; then
    DISCORD_WEBHOOK_URL=$(grep '^DISCORD_WEBHOOK_URL=' "${COMPOSE_DIR}/.env" 2>/dev/null | cut -d'=' -f2- | tr -d "'" | tr -d '"' || true)
fi

for arg in "$@"; do
    case "$arg" in
        --quiet) QUIET=true ;;
    esac
done

log()  { echo "[$(date '+%Y-%m-%d %H:%M:%S')] [watchdog] $1"; }
warn() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] [watchdog] [!!] $1"; }

notify_discord() {
    local message="$1"
    if [ -z "$DISCORD_WEBHOOK_URL" ]; then return; fi
    local payload
    payload=$(jq -n --arg c "$message" --arg u "Container Watchdog" \
        '{username: $u, content: $c}')
    curl -sf -X POST "$DISCORD_WEBHOOK_URL" \
        -H "Content-Type: application/json" \
        -d "$payload" > /dev/null 2>&1 || true
}

cd "$COMPOSE_DIR"

# Get all compose service containers and their states
exited_containers=()
while IFS= read -r line; do
    name=$(echo "$line" | awk '{print $1}')
    state=$(echo "$line" | awk '{print $2}')
    if [ "$state" = "exited" ] || [ "$state" = "dead" ]; then
        exited_containers+=("$name")
    fi
done < <(docker compose ps -a --format '{{.Name}} {{.State}}' 2>/dev/null)

if [ ${#exited_containers[@]} -eq 0 ]; then
    if [ "$QUIET" = false ]; then
        log "All containers healthy"
    fi
    exit 0
fi

# Found dead containers — attempt recovery
warn "Found ${#exited_containers[@]} dead container(s): ${exited_containers[*]}"

# Use docker compose up to recreate properly (handles network_mode deps)
log "Running docker compose up -d..."
compose_output=$(docker compose up -d 2>&1) || true
log "$compose_output"

# Wait for health checks
sleep 15

# Verify recovery
still_dead=()
while IFS= read -r line; do
    name=$(echo "$line" | awk '{print $1}')
    state=$(echo "$line" | awk '{print $2}')
    if [ "$state" = "exited" ] || [ "$state" = "dead" ]; then
        still_dead+=("$name")
    fi
done < <(docker compose ps -a --format '{{.Name}} {{.State}}' 2>/dev/null)

# Report results
recovered=()
for container in "${exited_containers[@]}"; do
    found_dead=false
    for dead in "${still_dead[@]+"${still_dead[@]}"}"; do
        if [ "$container" = "$dead" ]; then
            found_dead=true
            break
        fi
    done
    if [ "$found_dead" = false ]; then
        recovered+=("$container")
    fi
done

if [ ${#recovered[@]} -gt 0 ]; then
    log "Recovered: ${recovered[*]}"
    notify_discord "**Container Watchdog** — Recovered ${#recovered[@]} container(s): ${recovered[*]}"
fi

if [ ${#still_dead[@]} -gt 0 ]; then
    warn "STILL DEAD: ${still_dead[*]}"
    notify_discord "**Container Watchdog — ALERT** — Failed to recover: ${still_dead[*]}. Manual intervention required."
    exit 1
fi

log "All containers recovered successfully"
