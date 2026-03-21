#!/usr/bin/env bash
# =============================================================================
# Download Cleanup — removes stale completed AND incomplete downloads
# =============================================================================
# Two jobs:
#   1. Completed downloads older than a threshold (NAS mount)
#   2. Incomplete downloads that are clearly dead (local disk)
#
# Completed downloads (NAS — /mnt/downloads/):
#   - torrents/complete/*   → 14 days
#   - usenet/complete/*     → 7 days (usenet has no seeding)
#
# Incomplete downloads (local disk — /opt/arr-stack/downloads/):
#   - usenet-incomplete/*   → 48 hours. SABnzbd finishes or fails in hours.
#                             Anything older is a dead partial that will never
#                             complete. This was the source of a 485GB leak.
#   - torrent stalled 7d+   → Removed via qBittorrent API (stalledDL/error
#                             state with zero progress for 7+ days = dead).
#
# Runs via cron daily at 4 AM.
# =============================================================================
set -uo pipefail

TORRENT_COMPLETE="/mnt/downloads/torrents/complete"
USENET_COMPLETE="/mnt/downloads/usenet/complete"
USENET_INCOMPLETE="/opt/arr-stack/downloads/usenet-incomplete"
TORRENT_AGE_DAYS=14
USENET_AGE_DAYS=7
USENET_INCOMPLETE_AGE_HOURS=48
QBIT_STALLED_AGE_DAYS=7
QBIT_API="http://localhost:8080/api/v2"
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

cleanup_usenet_incomplete() {
    # Usenet incomplete downloads older than 48h are dead partials.
    # SABnzbd either completes or fails within hours. Anything lingering
    # is a failed download whose files were never cleaned up.
    if [ ! -d "$USENET_INCOMPLETE" ]; then
        log "WARN: $USENET_INCOMPLETE does not exist — skipping"
        return
    fi

    local before
    before=$(du -s "$USENET_INCOMPLETE" 2>/dev/null | awk '{print $1}')

    # Find directories older than threshold (each download is a directory)
    local deleted=0
    local age_minutes=$(( USENET_INCOMPLETE_AGE_HOURS * 60 ))
    while IFS= read -r -d '' dir; do
        rm -rf "$dir" 2>/dev/null && deleted=$((deleted + 1))
    done < <(find "$USENET_INCOMPLETE" -maxdepth 1 -mindepth 1 -type d -mmin +"$age_minutes" -print0 2>/dev/null)

    # Also clean stale files directly in the directory
    while IFS= read -r -d '' file; do
        rm -f "$file" 2>/dev/null && deleted=$((deleted + 1))
    done < <(find "$USENET_INCOMPLETE" -maxdepth 1 -mindepth 1 -type f -mmin +"$age_minutes" -print0 2>/dev/null)

    local after
    after=$(du -s "$USENET_INCOMPLETE" 2>/dev/null | awk '{print $1}')

    local freed_mb=$(( (before - after) / 1024 ))
    if [ "$deleted" -gt 0 ]; then
        log "Usenet-incomplete: removed $deleted items older than ${USENET_INCOMPLETE_AGE_HOURS}h (freed ~${freed_mb}MB)"
    else
        log "Usenet-incomplete: nothing to clean"
    fi
}

cleanup_stalled_torrents() {
    # Remove torrents stuck in stalledDL/error state for 7+ days via API.
    # These have no seeds and will never complete. Deletes files too.
    local response
    response=$(curl -sf "${QBIT_API}/torrents/info?filter=all" 2>/dev/null)
    if [ -z "$response" ]; then
        log "WARN: Could not reach qBittorrent API — skipping stalled cleanup"
        return
    fi

    local result
    result=$(echo "$response" | python3 -c "
import sys, json, time
t = json.load(sys.stdin)
now = time.time()
threshold = $QBIT_STALLED_AGE_DAYS * 86400
stalled = []
for x in t:
    if x['progress'] >= 1:
        continue
    if x['state'] in ('stalledDL', 'error', 'missingFiles'):
        age = now - x.get('added_on', now)
        if age >= threshold:
            stalled.append(x['hash'])
if stalled:
    print('|'.join(stalled))
    print(len(stalled), file=sys.stderr)
else:
    print('', file=sys.stderr)
" 2>/tmp/qbit_stalled_count.txt)

    local count
    count=$(cat /tmp/qbit_stalled_count.txt 2>/dev/null)

    if [ -n "$result" ]; then
        curl -sf -X POST "${QBIT_API}/torrents/delete" \
            -d "hashes=${result}&deleteFiles=true" > /dev/null 2>&1
        log "Stalled torrents: removed ${count} torrents stalled ${QBIT_STALLED_AGE_DAYS}+ days (with files)"
    else
        log "Stalled torrents: none found over ${QBIT_STALLED_AGE_DAYS}d threshold"
    fi
    rm -f /tmp/qbit_stalled_count.txt
}

cleanup_seeded_torrents() {
    # Remove torrents that finished seeding (paused after hitting ratio limit).
    # qBit pauses at ratio so Sonarr/Radarr can import first. After 24h paused,
    # the arr has had its chance — safe to delete the torrent and files.
    # This prevents paused torrents from piling up on disk.
    local response
    response=$(curl -sf "${QBIT_API}/torrents/info?filter=all" 2>/dev/null)
    if [ -z "$response" ]; then
        log "WARN: Could not reach qBittorrent API — skipping seeded cleanup"
        return
    fi

    local result
    result=$(echo "$response" | python3 -c "
import sys, json, time
t = json.load(sys.stdin)
now = time.time()
threshold = 24 * 3600  # 24 hours paused
remove = []
for x in t:
    # pausedUP = paused after completing (seeded to ratio)
    # Completed torrents that have been paused for 24h+
    if x['state'] == 'pausedUP' and x['progress'] >= 1:
        # completion_on is when download finished, but we want time since pause
        # Use last_activity as proxy — no activity for 24h means safe to remove
        last = x.get('last_activity', 0)
        if last > 0 and (now - last) >= threshold:
            remove.append(x['hash'])
if remove:
    print('|'.join(remove))
    print(len(remove), file=sys.stderr)
else:
    print('', file=sys.stderr)
" 2>/tmp/qbit_seeded_count.txt)

    local count
    count=$(cat /tmp/qbit_seeded_count.txt 2>/dev/null)

    if [ -n "$result" ]; then
        curl -sf -X POST "${QBIT_API}/torrents/delete" \
            -d "hashes=${result}&deleteFiles=true" > /dev/null 2>&1
        log "Seeded torrents: removed ${count} paused torrents (seeded, inactive 24h+)"
    else
        log "Seeded torrents: none ready for cleanup"
    fi
    rm -f /tmp/qbit_seeded_count.txt
}

log "=== Download cleanup started ==="
cleanup_dir "$TORRENT_COMPLETE" "$TORRENT_AGE_DAYS" "Torrents-complete"
cleanup_dir "$USENET_COMPLETE" "$USENET_AGE_DAYS" "Usenet-complete"
cleanup_usenet_incomplete
cleanup_stalled_torrents
cleanup_seeded_torrents
log "=== Download cleanup complete ==="
