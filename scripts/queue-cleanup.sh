#!/usr/bin/env bash
# =============================================================================
# Queue Cleanup — removes stale/rejected items from *arr queues
# =============================================================================
# Clears: quality rejections, missing episode mismatches, path-not-found errors.
# Removes from *arr queue only — does NOT delete files from download client.
# Runs via cron. Covers Sonarr and Radarr.
# =============================================================================
set -uo pipefail

log() { echo "[$(date "+%Y-%m-%d %H:%M:%S")] $1"; }

get_api_key() {
    local container="$1"
    docker exec "$container" cat /config/config.xml 2>/dev/null | grep -oP "(?<=<ApiKey>)[^<]+"
}

cleanup_sonarr() {
    local APIKEY
    APIKEY=$(get_api_key "sonarr")
    if [ -z "$APIKEY" ]; then
        log "WARN: Could not get Sonarr API key"
        return
    fi

    local result
    result=$(curl -sf "http://localhost:8989/api/v3/queue?pageSize=1000&includeUnknownSeriesItems=true" \
        -H "X-Api-Key: ${APIKEY}" 2>/dev/null)

    if [ -z "$result" ]; then
        log "WARN: Could not fetch Sonarr queue"
        return
    fi

    local ids
    ids=$(echo "$result" | python3 -c "
import sys, json
d = json.load(sys.stdin)
remove = []
for r in d.get(records, []):
    msgs = []
    for sm in r.get(statusMessages, []):
        msgs.extend(sm.get(messages, []))
    for msg in msgs:
        if any(kw in msg for kw in [
            Not a quality revision upgrade,
            was not found in the grabbed release,
            No files found are eligible for import,
            path does not exist or is not accessible
        ]):
            remove.append(r[id])
            break
if remove:
    print(json.dumps(remove))
" 2>/dev/null)

    if [ -n "$ids" ] && [ "$ids" != "null" ]; then
        local count
        count=$(echo "$ids" | python3 -c "import sys,json; print(len(json.load(sys.stdin)))")
        curl -sf -X DELETE "http://localhost:8989/api/v3/queue/bulk?removeFromClient=false&blocklist=false" \
            -H "X-Api-Key: ${APIKEY}" \
            -H "Content-Type: application/json" \
            -d "{\"ids\": ${ids}}" > /dev/null 2>&1
        log "Sonarr: removed ${count} rejected items"
    else
        log "Sonarr: queue clean"
    fi
}

cleanup_radarr() {
    local APIKEY
    APIKEY=$(get_api_key "radarr")
    if [ -z "$APIKEY" ]; then
        log "WARN: Could not get Radarr API key"
        return
    fi

    local result
    result=$(curl -sf "http://localhost:7878/api/v3/queue?pageSize=1000&includeUnknownMovieItems=true" \
        -H "X-Api-Key: ${APIKEY}" 2>/dev/null)

    if [ -z "$result" ]; then
        log "WARN: Could not fetch Radarr queue"
        return
    fi

    local ids
    ids=$(echo "$result" | python3 -c "
import sys, json
d = json.load(sys.stdin)
remove = []
for r in d.get(records, []):
    msgs = []
    for sm in r.get(statusMessages, []):
        msgs.extend(sm.get(messages, []))
    for msg in msgs:
        if any(kw in msg for kw in [
            Not a quality revision upgrade,
            Not an upgrade for existing movie file,
            No files found are eligible for import,
            path does not exist or is not accessible
        ]):
            remove.append(r[id])
            break
if remove:
    print(json.dumps(remove))
" 2>/dev/null)

    if [ -n "$ids" ] && [ "$ids" != "null" ]; then
        local count
        count=$(echo "$ids" | python3 -c "import sys,json; print(len(json.load(sys.stdin)))")
        curl -sf -X DELETE "http://localhost:7878/api/v3/queue/bulk?removeFromClient=false&blocklist=false" \
            -H "X-Api-Key: ${APIKEY}" \
            -H "Content-Type: application/json" \
            -d "{\"ids\": ${ids}}" > /dev/null 2>&1
        log "Radarr: removed ${count} rejected items"
    else
        log "Radarr: queue clean"
    fi
}

log "=== Queue cleanup started ==="
cleanup_sonarr
cleanup_radarr
log "=== Queue cleanup complete ==="
