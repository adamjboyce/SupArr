#!/usr/bin/env bash
# =============================================================================
# Weekly Digest — summarizes recently added content to Discord
# =============================================================================
# Runs inside an Alpine container on Privateer. Queries *arr history APIs
# for recent imports and sends a formatted Discord summary.
# =============================================================================
set -euo pipefail

DIGEST_INTERVAL="${DIGEST_INTERVAL:-604800}"  # 7 days in seconds
DISCORD_WEBHOOK_URL="${DISCORD_WEBHOOK_URL:-}"
RADARR_API_KEY="${RADARR_API_KEY:-}"
SONARR_API_KEY="${SONARR_API_KEY:-}"
LIDARR_API_KEY="${LIDARR_API_KEY:-}"

log()  { echo "[$(date '+%Y-%m-%d %H:%M:%S')] [OK] $1"; }
warn() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] [!!] $1"; }

send_digest() {
    if [ -z "$DISCORD_WEBHOOK_URL" ]; then
        warn "No Discord webhook configured — skipping digest"
        return
    fi

    local digest=""
    local NL=$'\n'
    local cutoff_date
    cutoff_date=$(date -d "7 days ago" '+%Y-%m-%dT%H:%M:%SZ' 2>/dev/null || \
                  date -u -d "@$(($(date +%s) - 604800))" '+%Y-%m-%dT%H:%M:%SZ' 2>/dev/null || echo "")

    # --- Radarr: recently imported movies ---
    if [ -n "$RADARR_API_KEY" ]; then
        local movies
        movies=$(curl -sf "http://radarr:7878/api/v3/history?page=1&pageSize=50&sortKey=date&sortDirection=descending" \
            -H "X-Api-Key: ${RADARR_API_KEY}" 2>/dev/null || echo "")

        if [ -n "$movies" ]; then
            local movie_list
            movie_list=$(echo "$movies" | jq -r --arg cutoff "$cutoff_date" '
                [.records[] |
                 select(.eventType == "downloadFolderImported") |
                 select(.date >= $cutoff) |
                 .sourceTitle // .movieId | tostring] |
                unique | .[:15] | .[]' 2>/dev/null || echo "")

            if [ -n "$movie_list" ]; then
                local count
                count=$(echo "$movie_list" | wc -l)
                digest+="${NL}**Movies** (${count}):${NL}"
                while IFS= read -r title; do
                    digest+="- ${title}${NL}"
                done <<< "$movie_list"
            fi
        fi
    fi

    # --- Sonarr: recently imported episodes ---
    if [ -n "$SONARR_API_KEY" ]; then
        local episodes
        episodes=$(curl -sf "http://sonarr:8989/api/v3/history?page=1&pageSize=100&sortKey=date&sortDirection=descending" \
            -H "X-Api-Key: ${SONARR_API_KEY}" 2>/dev/null || echo "")

        if [ -n "$episodes" ]; then
            local show_list
            show_list=$(echo "$episodes" | jq -r --arg cutoff "$cutoff_date" '
                [.records[] |
                 select(.eventType == "downloadFolderImported") |
                 select(.date >= $cutoff) |
                 .series.title // "Unknown"] |
                group_by(.) | map({title: .[0], count: length}) |
                sort_by(-.count) | .[:15] |
                .[] | "\(.title) (\(.count) ep)"' 2>/dev/null || echo "")

            if [ -n "$show_list" ]; then
                local count
                count=$(echo "$show_list" | wc -l)
                digest+="${NL}**TV Shows** (${count} shows):${NL}"
                while IFS= read -r show; do
                    digest+="- ${show}${NL}"
                done <<< "$show_list"
            fi
        fi
    fi

    # --- Lidarr: recently imported albums ---
    if [ -n "$LIDARR_API_KEY" ]; then
        local albums
        albums=$(curl -sf "http://lidarr:8686/api/v1/history?page=1&pageSize=50&sortKey=date&sortDirection=descending" \
            -H "X-Api-Key: ${LIDARR_API_KEY}" 2>/dev/null || echo "")

        if [ -n "$albums" ]; then
            local album_list
            album_list=$(echo "$albums" | jq -r --arg cutoff "$cutoff_date" '
                [.records[] |
                 select(.eventType == "downloadFolderImported") |
                 select(.date >= $cutoff) |
                 "\(.artist.artistName // "Unknown") - \(.album.title // "Unknown")"] |
                unique | .[:10] | .[]' 2>/dev/null || echo "")

            if [ -n "$album_list" ]; then
                local count
                count=$(echo "$album_list" | wc -l)
                digest+="${NL}**Music** (${count}):${NL}"
                while IFS= read -r album; do
                    digest+="- ${album}${NL}"
                done <<< "$album_list"
            fi
        fi
    fi

    # --- Send digest ---
    if [ -n "$digest" ]; then
        local message="**Weekly Media Digest**${NL}${digest}"
        # Discord message limit is 2000 chars — truncate if needed
        if [ ${#message} -gt 1900 ]; then
            message="${message:0:1900}${NL}...(truncated)"
        fi

        local payload
        payload=$(jq -n --arg c "$message" --arg u "Weekly Digest" \
            '{username: $u, content: $c}')
        curl -sf -X POST "$DISCORD_WEBHOOK_URL" \
            -H "Content-Type: application/json" \
            -d "$payload" > /dev/null 2>&1 && \
            log "Weekly digest sent to Discord" || \
            warn "Could not send digest to Discord"
    else
        log "No new content imported this week — nothing to report"
    fi
}

log "Weekly digest service started"
log "Interval: ${DIGEST_INTERVAL}s"

# Wait before first digest (let apps settle)
sleep 60
send_digest

while true; do
    sleep "$DIGEST_INTERVAL"
    send_digest
done
