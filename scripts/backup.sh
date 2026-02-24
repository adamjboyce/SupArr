#!/usr/bin/env bash
# =============================================================================
# Config Backup — tar+gzip APPDATA, 7-day rotation, Discord notification
# =============================================================================
# Runs inside an Alpine container. Backs up config directories on a schedule
# and rotates old backups. Sends Discord notifications on success/failure.
# =============================================================================
set -euo pipefail

BACKUP_DIR="${BACKUP_DIR:-/backups}"
APPDATA="${APPDATA:-/data}"
BACKUP_RETENTION_DAYS="${BACKUP_RETENTION_DAYS:-7}"
BACKUP_INTERVAL="${BACKUP_INTERVAL:-604800}"  # 7 days in seconds
DISCORD_WEBHOOK_URL="${DISCORD_WEBHOOK_URL:-}"
MACHINE_NAME="${MACHINE_NAME:-unknown}"

log()  { echo "[$(date '+%Y-%m-%d %H:%M:%S')] [OK] $1"; }
warn() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] [!!] $1"; }

notify_discord() {
    local message="$1"
    if [ -z "$DISCORD_WEBHOOK_URL" ]; then return; fi
    curl -sf -X POST "$DISCORD_WEBHOOK_URL" \
        -H "Content-Type: application/json" \
        -d "{\"username\": \"Backup Bot\", \"content\": \"$message\"}" \
        > /dev/null 2>&1 || true
}

run_backup() {
    local timestamp
    timestamp=$(date +%Y%m%d-%H%M%S)
    local backup_file="${BACKUP_DIR}/${MACHINE_NAME}-config-${timestamp}.tar.gz"
    mkdir -p "$BACKUP_DIR"

    log "Starting backup of ${APPDATA}..."
    if tar -czf "$backup_file" -C "$(dirname "$APPDATA")" "$(basename "$APPDATA")" 2>/dev/null; then
        local size
        size=$(du -sh "$backup_file" | cut -f1)
        log "Backup complete: ${backup_file} (${size})"
        notify_discord "**${MACHINE_NAME}** — Config backup complete (${size})"
    else
        warn "Backup failed!"
        notify_discord "**${MACHINE_NAME}** — Config backup FAILED"
        return 1
    fi

    # Rotate old backups
    find "$BACKUP_DIR" -name "${MACHINE_NAME}-config-*.tar.gz" \
        -mtime "+${BACKUP_RETENTION_DAYS}" -delete 2>/dev/null || true
    log "Rotation: kept last ${BACKUP_RETENTION_DAYS} days"
}

log "Backup service started for ${MACHINE_NAME}"
log "Backup dir: ${BACKUP_DIR} | Retention: ${BACKUP_RETENTION_DAYS} days | Interval: ${BACKUP_INTERVAL}s"

# Run immediately, then loop
run_backup || true
while true; do
    sleep "$BACKUP_INTERVAL"
    run_backup || true
done
