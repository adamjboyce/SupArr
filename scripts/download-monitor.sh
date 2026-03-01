#!/usr/bin/env bash
# =============================================================================
# Download Health Monitor
# =============================================================================
# Checks *arr queue APIs for stalled/warning torrents. Removes stalled items
# (with blocklist) so *arr auto-searches for alternatives.
#
# Runs as a loop inside a container. Configure via environment variables:
#   STALL_THRESHOLD_HOURS  — hours before a warning item is considered stalled (default: 6)
#   CHECK_INTERVAL         — seconds between checks (default: 3600 = 1 hour)
#   DISCORD_WEBHOOK_URL    — optional Discord webhook for notifications
#   RADARR_API_KEY, SONARR_API_KEY, LIDARR_API_KEY, READARR_API_KEY — app keys
#
# Requires: curl, jq, bash
# =============================================================================

set -euo pipefail

STALL_THRESHOLD_HOURS="${STALL_THRESHOLD_HOURS:-6}"
CHECK_INTERVAL="${CHECK_INTERVAL:-3600}"
DISCORD_WEBHOOK_URL="${DISCORD_WEBHOOK_URL:-}"

log()  { echo "[$(date '+%Y-%m-%d %H:%M:%S')] [OK] $1"; }
warn() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] [!!] $1"; }
info() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] [->] $1"; }

# Build list of apps to monitor (name:host:port:apiVersion:apiKey)
# Container hostnames used for Docker network resolution
declare -a APPS=()
[ -n "${RADARR_API_KEY:-}" ]  && APPS+=("Radarr:radarr:7878:v3:${RADARR_API_KEY}")
[ -n "${SONARR_API_KEY:-}" ]  && APPS+=("Sonarr:sonarr:8989:v3:${SONARR_API_KEY}")
[ -n "${LIDARR_API_KEY:-}" ]  && APPS+=("Lidarr:lidarr:8686:v1:${LIDARR_API_KEY}")
[ -n "${READARR_API_KEY:-}" ] && APPS+=("Readarr:readarr:8787:v1:${READARR_API_KEY}")

if [ ${#APPS[@]} -eq 0 ]; then
    warn "No API keys configured — nothing to monitor. Sleeping forever."
    exec sleep infinity
fi

# Notify Discord (fire-and-forget, jq handles JSON escaping)
notify_discord() {
    local message="$1"
    if [ -z "$DISCORD_WEBHOOK_URL" ]; then return; fi
    local payload
    payload=$(jq -n --arg c "$message" --arg u "Download Monitor" \
        '{username: $u, content: $c}')
    curl -sf -X POST "$DISCORD_WEBHOOK_URL" \
        -H "Content-Type: application/json" \
        -d "$payload" > /dev/null 2>&1 || true
}

# Calculate age in hours from ISO timestamp
age_hours() {
    local added="$1"
    local added_epoch
    added_epoch=$(date -d "$added" +%s 2>/dev/null || echo "0")
    if [ "$added_epoch" -eq 0 ]; then echo "0"; return; fi
    local now_epoch
    now_epoch=$(date +%s)
    echo $(( (now_epoch - added_epoch) / 3600 ))
}

# Check one app's queue for stalled downloads
check_and_clean() {
    local name="$1" host="$2" port="$3" api_ver="$4" api_key="$5"
    local url="http://${host}:${port}/api/${api_ver}"

    # Fetch queue
    local queue
    queue=$(curl -sf "${url}/queue?page=1&pageSize=100" \
        -H "X-Api-Key: ${api_key}" 2>/dev/null || echo "")

    if [ -z "$queue" ] || [ "$queue" = "null" ]; then
        return
    fi

    # Find stalled items: status=warning, protocol=torrent, older than threshold
    local stalled_items
    stalled_items=$(echo "$queue" | jq -r --arg thresh "$STALL_THRESHOLD_HOURS" '
        .records // [] | map(
            select(
                .trackedDownloadStatus == "warning" and
                .protocol == "torrent"
            )
        ) | .[] | @base64
    ' 2>/dev/null || echo "")

    if [ -z "$stalled_items" ]; then
        return
    fi

    local removed_count=0
    local removed_titles=""

    for item_b64 in $stalled_items; do
        local item
        item=$(echo "$item_b64" | base64 -d 2>/dev/null || echo "")
        if [ -z "$item" ]; then continue; fi

        local item_id title added
        item_id=$(echo "$item" | jq -r '.id // empty' 2>/dev/null || echo "")
        title=$(echo "$item" | jq -r '.title // "Unknown"' 2>/dev/null || echo "Unknown")
        added=$(echo "$item" | jq -r '.added // empty' 2>/dev/null || echo "")

        if [ -z "$item_id" ] || [ -z "$added" ]; then continue; fi

        local hours
        hours=$(age_hours "$added")

        if [ "$hours" -ge "$STALL_THRESHOLD_HOURS" ]; then
            info "${name}: removing stalled download (${hours}h old): ${title}"

            # Remove from client + blocklist so it won't be grabbed again
            local delete_result
            delete_result=$(curl -sf -X DELETE \
                "${url}/queue/${item_id}?removeFromClient=true&blocklist=true" \
                -H "X-Api-Key: ${api_key}" 2>/dev/null && echo "ok" || echo "fail")

            if [ "$delete_result" = "ok" ]; then
                removed_count=$((removed_count + 1))
                removed_titles+=$'\n'"- ${title} (${hours}h stalled)"
                log "${name}: removed and blocklisted: ${title}"
            else
                warn "${name}: failed to remove: ${title}"
            fi
        fi
    done

    # Send Discord summary for this app if anything was removed
    if [ "$removed_count" -gt 0 ]; then
        notify_discord "**${name}** — Removed ${removed_count} stalled download(s). Auto-searching for alternatives.${removed_titles}"
    fi
}

# ── Main Loop ───────────────────────────────────────────────────────────────

log "Download monitor started"
log "Monitoring: ${APPS[*]}"
log "Stall threshold: ${STALL_THRESHOLD_HOURS}h | Check interval: ${CHECK_INTERVAL}s"

while true; do
    for app_entry in "${APPS[@]}"; do
        IFS=':' read -r name host port api_ver api_key <<< "$app_entry"
        check_and_clean "$name" "$host" "$port" "$api_ver" "$api_key"
    done
    sleep "$CHECK_INTERVAL"
done
