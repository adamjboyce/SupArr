#!/usr/bin/env bash
# =============================================================================
# Disk Guard — pause download clients when NVMe free space is low
# =============================================================================
# Protects local NVMe from being filled by download clients. Pauses SABnzbd
# and qBittorrent when free space drops below threshold, resumes when it
# recovers above the resume threshold. Hysteresis prevents flapping.
#
# Install (via init script Phase 8g, or manually):
#   crontab -e
#   */15 * * * * /opt/suparr/scripts/disk_guard.sh
#
# Configuration: environment variables or defaults.
# API keys are extracted from running containers — never hardcoded.
# =============================================================================
set -uo pipefail

# --- Configuration (override via env vars) ---
PAUSE_THRESHOLD_GB="${DISK_GUARD_PAUSE_GB:-120}"
RESUME_THRESHOLD_GB="${DISK_GUARD_RESUME_GB:-200}"
MONITOR_PATH="${DISK_GUARD_PATH:-/}"
STATE_FILE="/tmp/disk_guard_paused"
LOG_TAG="disk_guard"

# --- Resolve compose .env for webhook ---
COMPOSE_DIR="${COMPOSE_DIR:-/opt/suparr/machine2-arr}"
DISCORD_WEBHOOK_URL="${DISCORD_WEBHOOK_URL:-}"
if [ -z "$DISCORD_WEBHOOK_URL" ] && [ -f "${COMPOSE_DIR}/.env" ]; then
    DISCORD_WEBHOOK_URL=$(grep '^DISCORD_WEBHOOK_URL=' "${COMPOSE_DIR}/.env" 2>/dev/null | cut -d'=' -f2- | tr -d "'" | tr -d '"' || true)
fi

# --- Helpers ---
log() { logger -t "$LOG_TAG" "$1"; }

notify_discord() {
    [ -z "$DISCORD_WEBHOOK_URL" ] && return
    local payload
    payload=$(jq -n --arg c "$1" --arg u "Disk Guard" '{username: $u, content: $c}') 2>/dev/null || return
    curl -sf -X POST "$DISCORD_WEBHOOK_URL" \
        -H "Content-Type: application/json" \
        -d "$payload" > /dev/null 2>&1 || true
}

# --- Get SABnzbd API key from container config ---
get_sab_key() {
    docker exec sabnzbd cat /config/sabnzbd.ini 2>/dev/null \
        | grep -oP '^api_key\s*=\s*\K\S+' \
        | head -1
}

# --- Pause / Resume ---
pause_clients() {
    local sab_key
    sab_key=$(get_sab_key)

    # Pause SABnzbd (through gluetun network)
    if [ -n "$sab_key" ]; then
        curl -sf "http://localhost:8085/api?mode=pause&apikey=${sab_key}&output=json" > /dev/null 2>&1 || true
    fi

    # Throttle qBittorrent to 1 B/s (effectively paused)
    curl -sf "http://localhost:8080/api/v2/transfer/setDownloadLimit" -d "limit=1" > /dev/null 2>&1 || true

    touch "$STATE_FILE"
    local msg="CRITICAL: NVMe at ${free_gb}GB free (threshold: ${PAUSE_THRESHOLD_GB}GB). Download clients PAUSED."
    log "$msg"
    notify_discord "🛑 $msg"
}

resume_clients() {
    local sab_key
    sab_key=$(get_sab_key)

    # Resume SABnzbd
    if [ -n "$sab_key" ]; then
        curl -sf "http://localhost:8085/api?mode=resume&apikey=${sab_key}&output=json" > /dev/null 2>&1 || true
    fi

    # Remove qBittorrent download limit
    curl -sf "http://localhost:8080/api/v2/transfer/setDownloadLimit" -d "limit=0" > /dev/null 2>&1 || true

    rm -f "$STATE_FILE"
    local msg="OK: NVMe at ${free_gb}GB free (resume threshold: ${RESUME_THRESHOLD_GB}GB). Download clients RESUMED."
    log "$msg"
    notify_discord "✅ $msg"
}

# --- Main ---
free_gb=$(df --output=avail "$MONITOR_PATH" | tail -1 | awk '{printf "%.0f", $1/1048576}')

if [ "$free_gb" -lt "$PAUSE_THRESHOLD_GB" ]; then
    pause_clients
elif [ -f "$STATE_FILE" ] && [ "$free_gb" -ge "$RESUME_THRESHOLD_GB" ]; then
    resume_clients
elif [ -f "$STATE_FILE" ]; then
    log "WARN: NVMe at ${free_gb}GB free. Still below resume threshold (${RESUME_THRESHOLD_GB}GB). Clients remain paused."
fi
