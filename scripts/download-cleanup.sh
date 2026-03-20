#!/usr/bin/env bash
# =============================================================================
# Download Cleanup — removes stale completed downloads
# =============================================================================
# Deletes completed download files older than a threshold. By the time a
# download has sat for 14 days, the *arr apps have either imported it or
# never will. Safe to remove.
#
# Covers:
#   - /mnt/downloads/torrents/complete/*   (14 days)
#   - /mnt/downloads/usenet/complete/*     (7 days, usenet has no seeding)
#
# Does NOT touch:
#   - incomplete downloads (still in progress)
#   - the category directories themselves (sonarr/, radarr/, etc.)
#   - anything outside /mnt/downloads/
#
# Runs via cron daily at 4 AM.
# =============================================================================
set -uo pipefail

TORRENT_COMPLETE="/mnt/downloads/torrents/complete"
USENET_COMPLETE="/mnt/downloads/usenet/complete"
TORRENT_AGE_DAYS=14
USENET_AGE_DAYS=7
LOG="/var/log/suparr-download-cleanup.log"

log() { echo "[$(date "+%Y-%m-%d %H:%M:%S")] $1" | tee -a "$LOG"; }

cleanup_dir() {
    local DIR="$1" AGE="$2" LABEL="$3"

    if [ ! -d "$DIR" ]; then
        log "WARN: $DIR does not exist — skipping"
        return
    fi

    # Count before
    local before
    before=$(du -s "$DIR" 2>/dev/null | awk '{print $1}')

    # Find and remove files older than threshold
    # Only target files inside category subdirs, not the category dirs themselves
    local deleted=0
    while IFS= read -r -d '' file; do
        rm -f "$file" 2>/dev/null && deleted=$((deleted + 1))
    done < <(find "$DIR" -mindepth 2 -type f -mtime +"$AGE" -print0 2>/dev/null)

    # Remove empty directories left behind (but not the category dirs)
    find "$DIR" -mindepth 2 -type d -empty -delete 2>/dev/null

    # Count after
    local after
    after=$(du -s "$DIR" 2>/dev/null | awk '{print $1}')

    local freed_mb=$(( (before - after) / 1024 ))
    if [ "$deleted" -gt 0 ]; then
        log "$LABEL: removed $deleted files older than ${AGE}d (freed ~${freed_mb}MB)"
    else
        log "$LABEL: nothing to clean (no files older than ${AGE}d)"
    fi
}

log "=== Download cleanup started ==="
cleanup_dir "$TORRENT_COMPLETE" "$TORRENT_AGE_DAYS" "Torrents"
cleanup_dir "$USENET_COMPLETE" "$USENET_AGE_DAYS" "Usenet"
log "=== Download cleanup complete ==="
