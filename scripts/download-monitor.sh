#!/usr/bin/env bash
# =============================================================================
# Download Health Monitor
# =============================================================================
# Two-layer cleanup:
#
#   Layer 1 — *arr queue cleanup:
#     Checks Radarr/Sonarr/Lidarr/Bookshelf/Whisparr queues for stalled
#     downloads. Removes + blocklists so the *arr auto-searches alternatives.
#
#   Layer 2 — qBittorrent direct cleanup:
#     Catches torrents the *arr layer misses (orphans, metadata-stuck, truly
#     dead). Removes from qBit directly.
#     - metaDL (stuck downloading metadata) > META_THRESHOLD_HOURS
#     - stalledDL with 0 seeds and 0 availability > DEAD_THRESHOLD_HOURS
#     - stalledDL at >=99% progress with 0 seeds > STUCK_COMPLETE_THRESHOLD_HOURS
#       (force recheck first, purge if still stuck next cycle)
#     - missingFiles (orphaned torrents with deleted data)
#
# Removing dead torrents frees active slots for healthy ones. *arr apps detect
# the removal and auto-search for alternative releases.
#
# Runs as a loop inside a container. Configure via environment variables.
# Requires: curl, jq, bash
# =============================================================================

set -euo pipefail

STALL_THRESHOLD_HOURS="${STALL_THRESHOLD_HOURS:-6}"
META_THRESHOLD_HOURS="${META_THRESHOLD_HOURS:-12}"
DEAD_THRESHOLD_HOURS="${DEAD_THRESHOLD_HOURS:-24}"
STUCK_COMPLETE_THRESHOLD_HOURS="${STUCK_COMPLETE_THRESHOLD_HOURS:-24}"
ZOMBIE_THRESHOLD_HOURS="${ZOMBIE_THRESHOLD_HOURS:-48}"
CHECK_INTERVAL="${CHECK_INTERVAL:-3600}"
DISCORD_WEBHOOK_URL="${DISCORD_WEBHOOK_URL:-}"
QBIT_URL="${QBIT_URL:-http://gluetun:8080}"
QBIT_USERNAME="${QBIT_USERNAME:-}"
QBIT_PASSWORD="${QBIT_PASSWORD:-}"

log()  { echo "[$(date '+%Y-%m-%d %H:%M:%S')] [OK] $1"; }
warn() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] [!!] $1"; }
info() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] [->] $1"; }

# Build list of apps to monitor (name:host:port:apiVersion:apiKey)
# Container hostnames used for Docker network resolution
declare -a APPS=()
[ -n "${RADARR_API_KEY:-}" ]    && APPS+=("Radarr:radarr:7878:v3:${RADARR_API_KEY}")
[ -n "${SONARR_API_KEY:-}" ]    && APPS+=("Sonarr:sonarr:8989:v3:${SONARR_API_KEY}")
[ -n "${LIDARR_API_KEY:-}" ]    && APPS+=("Lidarr:lidarr:8686:v1:${LIDARR_API_KEY}")
[ -n "${BOOKSHELF_API_KEY:-}" ] && APPS+=("Bookshelf:bookshelf:8787:v1:${BOOKSHELF_API_KEY}")
[ -n "${WHISPARR_API_KEY:-}" ]  && APPS+=("Whisparr:whisparr:6969:v3:${WHISPARR_API_KEY}")

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

# ── Layer 1: *arr queue cleanup ──────────────────────────────────────────────

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

# ── Layer 2: qBittorrent direct cleanup ──────────────────────────────────────

QBIT_COOKIE_FILE="/tmp/qbit_cookies"

qbit_login() {
    if [ -z "$QBIT_USERNAME" ] || [ -z "$QBIT_PASSWORD" ]; then
        # No auth configured — try without login
        return 0
    fi
    curl -sf -c "$QBIT_COOKIE_FILE" \
        "${QBIT_URL}/api/v2/auth/login" \
        -d "username=${QBIT_USERNAME}&password=${QBIT_PASSWORD}" > /dev/null 2>&1
}

qbit_api() {
    local endpoint="$1"
    shift
    curl -sf -b "$QBIT_COOKIE_FILE" "${QBIT_URL}/api/v2${endpoint}" "$@" 2>/dev/null
}

RECHECK_TRACKING_FILE="/tmp/rechecked_hashes"

clean_qbit() {
    # Login if needed
    qbit_login || { warn "qBit: login failed, skipping direct cleanup"; return; }

    # Fetch all torrents
    local torrents
    torrents=$(qbit_api "/torrents/info" || echo "")

    if [ -z "$torrents" ] || [ "$torrents" = "[]" ]; then
        return
    fi

    local now
    now=$(date +%s)
    local meta_removed=0
    local dead_removed=0
    local missing_removed=0
    local removed_names=""

    # Load previously rechecked hashes, then clear for this cycle
    touch "$RECHECK_TRACKING_FILE"
    local prev_rechecked
    prev_rechecked=$(cat "$RECHECK_TRACKING_FILE")
    : > "${RECHECK_TRACKING_FILE}.new"

    # Process each torrent
    echo "$torrents" | jq -c '.[]' | while read -r torrent; do
        local state name hash added_on seeds connected_seeds avail progress
        state=$(echo "$torrent" | jq -r '.state')
        name=$(echo "$torrent" | jq -r '.name')
        hash=$(echo "$torrent" | jq -r '.hash')
        added_on=$(echo "$torrent" | jq -r '.added_on')
        seeds=$(echo "$torrent" | jq -r '.num_complete // 0')
        connected_seeds=$(echo "$torrent" | jq -r '.num_seeds // 0')
        avail=$(echo "$torrent" | jq -r '.availability // 0')
        progress=$(echo "$torrent" | jq -r '.progress // 0')

        local age_h=$(( (now - added_on) / 3600 ))

        local should_remove=false
        local reason=""

        # Metadata stuck — no info dict available
        if [ "$state" = "metaDL" ] && [ "$age_h" -ge "$META_THRESHOLD_HOURS" ]; then
            should_remove=true
            reason="metadata stuck ${age_h}h"
        fi

        # Stalled with no connected peers — truly dead
        # Uses num_seeds (actually connected) rather than num_complete (tracker-claimed)
        # because dead XXX trackers commonly report phantom seeds that never serve data.
        if [ "$state" = "stalledDL" ] && [ "$connected_seeds" -eq 0 ] && [ "$age_h" -ge "$DEAD_THRESHOLD_HOURS" ]; then
            should_remove=true
            reason="dead (0 connected seeds, ${age_h}h)"
        fi

        # Zombie — stalledDL with tracker-reported seeds but 0 bytes downloaded
        # Tracker says seeds exist, but nobody is actually serving data.
        if [ "$state" = "stalledDL" ] && [ "$age_h" -ge "$ZOMBIE_THRESHOLD_HOURS" ] && [ "$should_remove" = "false" ]; then
            local downloaded
            downloaded=$(echo "$torrent" | jq -r '.downloaded // 0')
            local dlspeed
            dlspeed=$(echo "$torrent" | jq -r '.dlspeed // 0')
            if [ "$downloaded" -eq 0 ] && [ "$dlspeed" -eq 0 ]; then
                should_remove=true
                reason="zombie (${age_h}h stalled, 0 bytes downloaded despite ${seeds} tracker seeds)"
            fi
        fi

        # Stuck complete — stalledDL at >=99% with 0 seeds
        # These often have stale piece maps. Recheck first, purge next cycle.
        if [ "$state" = "stalledDL" ] && [ "$seeds" -eq 0 ] && [ "$age_h" -ge "$STUCK_COMPLETE_THRESHOLD_HOURS" ]; then
            local progress_pct
            progress_pct=$(echo "$progress" | awk '{printf "%d", $1 * 100}')
            if [ "${progress_pct:-0}" -ge 99 ]; then
                if echo "$prev_rechecked" | grep -qxF "$hash"; then
                    # Already rechecked last cycle, still stuck — purge
                    should_remove=true
                    reason="stuck complete after recheck (${progress_pct}%, 0 seeds, ${age_h}h)"
                else
                    # First time seeing this — force recheck, track for next cycle
                    info "qBit: force recheck [${progress_pct}%, 0 seeds, ${age_h}h]: ${name:0:70}"
                    qbit_api "/torrents/recheck" -d "hashes=${hash}" > /dev/null 2>&1
                    echo "$hash" >> "${RECHECK_TRACKING_FILE}.new"
                fi
            fi
        fi

        # Abandoned — partially downloaded but no connected seeders, no speed.
        if [ "$state" = "stalledDL" ] && [ "$connected_seeds" -eq 0 ] && [ "$age_h" -ge "$DEAD_THRESHOLD_HOURS" ] && [ "$should_remove" = "false" ]; then
            local dlspeed_chk
            dlspeed_chk=$(echo "$torrent" | jq -r '.dlspeed // 0')
            if [ "$dlspeed_chk" -eq 0 ]; then
                local progress_pct_ab
                progress_pct_ab=$(echo "$progress" | awk '{printf "%d", $1 * 100}')
                should_remove=true
                reason="abandoned (0 seeds, 0 speed, ${progress_pct_ab}% done, ${age_h}h)"
            fi
        fi

        # Missing files — orphaned torrent
        if [ "$state" = "missingFiles" ]; then
            should_remove=true
            reason="missing files"
        fi

        if [ "$should_remove" = "true" ]; then
            info "qBit: removing [${reason}]: ${name:0:70}"
            qbit_api "/torrents/delete" -d "hashes=${hash}&deleteFiles=true" > /dev/null 2>&1
        fi
    done

    # Update recheck tracking — only keep hashes from this cycle
    mv "${RECHECK_TRACKING_FILE}.new" "$RECHECK_TRACKING_FILE" 2>/dev/null || true

    # Count what was removed (re-fetch and compare)
    local after_count
    after_count=$(qbit_api "/torrents/info" | jq 'length' 2>/dev/null || echo "?")
    local before_count
    before_count=$(echo "$torrents" | jq 'length')
    local diff=$((before_count - after_count))

    if [ "$diff" -gt 0 ]; then
        log "qBit: removed ${diff} dead/stuck torrent(s) (was ${before_count}, now ${after_count})"
        notify_discord "**qBittorrent** — Removed ${diff} dead torrent(s) (metadata stuck, 0-seed stalled, missing files). Active slots freed for healthy downloads."
    else
        log "qBit: no dead torrents to clean"
    fi
}

# ── Main Loop ───────────────────────────────────────────────────────────────

if [ ${#APPS[@]} -eq 0 ] && [ -z "${QBIT_URL:-}" ]; then
    warn "No API keys or qBit URL configured — nothing to monitor. Sleeping forever."
    exec sleep infinity
fi

log "Download monitor started"
[ ${#APPS[@]} -gt 0 ] && log "Layer 1 (*arr): $(printf '%s\n' "${APPS[@]}" | cut -d: -f1 | tr '\n' ' ')"
log "Layer 2 (qBit): ${QBIT_URL}"
log "Thresholds — *arr stall: ${STALL_THRESHOLD_HOURS}h | metadata: ${META_THRESHOLD_HOURS}h | dead: ${DEAD_THRESHOLD_HOURS}h | zombie: ${ZOMBIE_THRESHOLD_HOURS}h | stuck complete: ${STUCK_COMPLETE_THRESHOLD_HOURS}h"
log "Check interval: ${CHECK_INTERVAL}s"

while true; do
    # Layer 1: *arr queue cleanup
    for app_entry in "${APPS[@]}"; do
        IFS=':' read -r name host port api_ver api_key <<< "$app_entry"
        check_and_clean "$name" "$host" "$port" "$api_ver" "$api_key"
    done

    # Layer 2: qBit direct cleanup
    clean_qbit

    sleep "$CHECK_INTERVAL"
done
