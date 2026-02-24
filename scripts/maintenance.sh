#!/usr/bin/env bash
# =============================================================================
# Maintenance Robot — disk space alerts, stale download cleanup, empty dir cleanup
# =============================================================================
# Runs inside an Alpine container on Privateer. Daily maintenance cycle:
#   1. Disk space monitoring with Discord alerts
#   2. Stale incomplete download removal
#   3. Empty media directory cleanup
# =============================================================================
set -euo pipefail

DISK_ALERT_THRESHOLD="${DISK_ALERT_THRESHOLD:-85}"
STALE_DOWNLOAD_DAYS="${STALE_DOWNLOAD_DAYS:-7}"
CHECK_INTERVAL="${CHECK_INTERVAL:-86400}"  # 24 hours
DISCORD_WEBHOOK_URL="${DISCORD_WEBHOOK_URL:-}"
DOWNLOADS_DIR="${DOWNLOADS_DIR:-/downloads}"
MEDIA_DIR="${MEDIA_DIR:-/media}"

log()  { echo "[$(date '+%Y-%m-%d %H:%M:%S')] [OK] $1"; }
warn() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] [!!] $1"; }

notify_discord() {
    local message="$1"
    if [ -z "$DISCORD_WEBHOOK_URL" ]; then return; fi
    curl -sf -X POST "$DISCORD_WEBHOOK_URL" \
        -H "Content-Type: application/json" \
        -d "{\"username\": \"Maintenance Bot\", \"content\": \"$message\"}" \
        > /dev/null 2>&1 || true
}

check_disk_space() {
    log "Checking disk space..."
    local alerts=""

    for mount_point in /data /downloads /media; do
        if [ ! -d "$mount_point" ]; then continue; fi
        local usage
        usage=$(df "$mount_point" 2>/dev/null | awk 'NR==2 {gsub(/%/,""); print $5}' || echo "0")
        if [ "${usage:-0}" -gt "$DISK_ALERT_THRESHOLD" ]; then
            local mount_info
            mount_info=$(df -h "$mount_point" 2>/dev/null | awk 'NR==2 {print $4 " free of " $2}')
            warn "DISK ALERT: ${mount_point} at ${usage}% (${mount_info})"
            alerts="${alerts}\n- **${mount_point}**: ${usage}% used (${mount_info})"
        else
            log "  ${mount_point}: ${usage}% used"
        fi
    done

    if [ -n "$alerts" ]; then
        notify_discord "**Disk Space Alert** — usage above ${DISK_ALERT_THRESHOLD}%:${alerts}"
    fi
}

cleanup_stale_downloads() {
    if [ ! -d "$DOWNLOADS_DIR" ]; then return; fi
    log "Checking for stale incomplete downloads (>${STALE_DOWNLOAD_DAYS} days)..."

    local count=0

    # qBittorrent incomplete files (.!qB extension)
    while IFS= read -r -d '' f; do
        rm -f "$f" 2>/dev/null && count=$((count + 1))
    done < <(find "$DOWNLOADS_DIR" -name "*.!qB" -mtime "+${STALE_DOWNLOAD_DAYS}" -print0 2>/dev/null || true)

    # SABnzbd incomplete files
    while IFS= read -r -d '' f; do
        rm -f "$f" 2>/dev/null && count=$((count + 1))
    done < <(find "$DOWNLOADS_DIR" -name "*.nzb.tmp" -mtime "+${STALE_DOWNLOAD_DAYS}" -print0 2>/dev/null || true)

    if [ "$count" -gt 0 ]; then
        log "Removed ${count} stale incomplete download(s)"
        notify_discord "**Maintenance** — Removed ${count} stale incomplete download(s) older than ${STALE_DOWNLOAD_DAYS} days"
    else
        log "No stale incomplete downloads found"
    fi
}

cleanup_empty_dirs() {
    if [ ! -d "$MEDIA_DIR" ]; then return; fi
    log "Checking for empty media directories..."

    local count=0

    # Find and remove empty directories (skip top-level category dirs)
    # mindepth 2 ensures we never delete top-level dirs like /media/movies
    while IFS= read -r -d '' d; do
        rmdir "$d" 2>/dev/null && count=$((count + 1))
    done < <(find "$MEDIA_DIR" -mindepth 2 -type d -empty -print0 2>/dev/null || true)

    if [ "$count" -gt 0 ]; then
        log "Removed ${count} empty media director(ies)"
    else
        log "No empty media directories found"
    fi
}

run_maintenance() {
    log "=== Maintenance cycle starting ==="
    check_disk_space
    cleanup_stale_downloads
    cleanup_empty_dirs
    log "=== Maintenance cycle complete ==="
}

log "Maintenance service started"
log "Disk threshold: ${DISK_ALERT_THRESHOLD}% | Stale days: ${STALE_DOWNLOAD_DAYS} | Interval: ${CHECK_INTERVAL}s"

# Run immediately, then loop
run_maintenance
while true; do
    sleep "$CHECK_INTERVAL"
    run_maintenance
done
