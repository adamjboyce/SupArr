#!/usr/bin/env bash
# =============================================================================
# Missing Content Search — triggers backfill search across *arr apps
# =============================================================================
# Runs via cron. Staggers searches by 15 minutes to avoid indexer rate limits.
# Excluded: Whisparr (per Walsh)
# =============================================================================
set -uo pipefail

log() { echo "[$(date "+%Y-%m-%d %H:%M:%S")] $1"; }

get_api_key() {
    local container="$1"
    docker exec "$container" cat /config/config.xml 2>/dev/null | grep -oP "(?<=<ApiKey>)[^<]+"
}

trigger_search() {
    local app="$1" port="$2" version="$3" command="$4"
    local apikey
    apikey=$(get_api_key "$app")

    if [ -z "$apikey" ]; then
        log "WARN: Could not get API key for $app — skipping"
        return 1
    fi

    local result
    result=$(curl -sf -X POST "http://localhost:${port}/api/${version}/command" \
        -H "X-Api-Key: ${apikey}" \
        -H "Content-Type: application/json" \
        -d "{\"name\": \"${command}\"}" 2>&1)

    if [ $? -eq 0 ]; then
        log "OK: $app — $command triggered"
    else
        log "WARN: $app — $command failed: $result"
    fi
}

log "=== Missing content search started ==="

# Sonarr — missing episodes
trigger_search "sonarr" 8989 "v3" "MissingEpisodeSearch"
sleep 900  # 15 min stagger

# Radarr — missing movies
trigger_search "radarr" 7878 "v3" "MissingMoviesSearch"
sleep 900

# Lidarr — missing albums
trigger_search "lidarr" 8686 "v1" "MissingAlbumSearch"

log "=== Missing content search complete ==="
