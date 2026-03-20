#!/usr/bin/env bash
# =============================================================================
# Queue Cleanup — removes stale/rejected items from *arr queues
# =============================================================================
# Clears: quality rejections, missing episode mismatches, path-not-found errors,
# and import-blocked items (series ID conflicts).
# Removes from *arr queue only — does NOT delete files from download client.
# Runs via cron. Covers Sonarr and Radarr.
# =============================================================================
set -uo pipefail

log() { echo "[$(date "+%Y-%m-%d %H:%M:%S")] $1"; }

get_api_key() {
    local container="$1"
    docker exec "$container" cat /config/config.xml 2>/dev/null | grep -oP '(?<=<ApiKey>)[^<]+'
}

cleanup_arr() {
    local NAME="$1" PORT="$2" CONTAINER="$3" UNKNOWN_PARAM="$4"
    local APIKEY
    APIKEY=$(get_api_key "$CONTAINER")
    if [ -z "$APIKEY" ]; then
        log "WARN: Could not get $NAME API key"
        return
    fi

    local result
    result=$(curl -sf "http://localhost:${PORT}/api/v3/queue?pageSize=1000&${UNKNOWN_PARAM}=true" \
        -H "X-Api-Key: ${APIKEY}" 2>/dev/null)

    if [ -z "$result" ]; then
        log "WARN: Could not fetch $NAME queue"
        return
    fi

    local ids
    ids=$(echo "$result" | python3 -c '
import sys, json
d = json.load(sys.stdin)
remove = []
for r in d.get("records", []):
    msgs = []
    for sm in r.get("statusMessages", []):
        msgs.extend(sm.get("messages", []))
    for msg in msgs:
        if any(kw in msg for kw in [
            "Not a quality revision upgrade",
            "Not an upgrade for existing",
            "was not found in the grabbed release",
            "No files found are eligible for import",
            "path does not exist or is not accessible",
            "Automatic import is not possible"
        ]):
            remove.append(r["id"])
            break
if remove:
    print(json.dumps(remove))
' 2>/dev/null)

    if [ -n "$ids" ] && [ "$ids" != "null" ]; then
        local count
        count=$(echo "$ids" | python3 -c 'import sys,json; print(len(json.load(sys.stdin)))')
        curl -sf -X DELETE "http://localhost:${PORT}/api/v3/queue/bulk?removeFromClient=false&blocklist=false" \
            -H "X-Api-Key: ${APIKEY}" \
            -H "Content-Type: application/json" \
            -d "{\"ids\": ${ids}}" > /dev/null 2>&1
        log "$NAME: removed ${count} rejected items"
    else
        log "$NAME: queue clean"
    fi
}

log "=== Queue cleanup started ==="
cleanup_arr "Sonarr" 8989 "sonarr" "includeUnknownSeriesItems"
cleanup_arr "Radarr" 7878 "radarr" "includeUnknownMovieItems"
log "=== Queue cleanup complete ==="
