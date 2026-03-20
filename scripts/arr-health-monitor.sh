#!/bin/bash
# SupArr stack health monitor.
# Runs every 30 minutes via cron. Checks all services, fires Discord alerts on issues.
# Proactive monitoring — catches problems before they're noticed.

WEBHOOK_URL="${SUPARR_DISCORD_WEBHOOK:?SUPARR_DISCORD_WEBHOOK not set}"
LOG="/var/log/arr-stack/health-monitor.log"

RADARR_KEY=$(docker exec radarr cat /config/config.xml 2>/dev/null | grep -oP '(?<=<ApiKey>)[^<]+')
SONARR_KEY=$(docker exec sonarr cat /config/config.xml 2>/dev/null | grep -oP '(?<=<ApiKey>)[^<]+')
PROWLARR_KEY=$(docker exec prowlarr cat /config/config.xml 2>/dev/null | grep -oP '(?<=<ApiKey>)[^<]+')

ISSUES=""
ISSUE_COUNT=0

log() { echo "$(date -u '+%Y-%m-%d %H:%M:%S UTC') $1" >> "$LOG"; }

add_issue() {
    ISSUES="${ISSUES}\n- $1"
    ISSUE_COUNT=$((ISSUE_COUNT + 1))
}

# --- Container health checks ---
check_container() {
    local NAME="$1"
    local STATUS
    STATUS=$(docker inspect "$NAME" --format '{{.State.Status}}' 2>/dev/null)
    if [ -z "$STATUS" ]; then
        add_issue "**$NAME**: container not found"
        return
    fi
    if [ "$STATUS" != "running" ]; then
        add_issue "**$NAME**: status=$STATUS (expected running)"
        return
    fi
    # Check for crash-looping: container started within last 5 min AND has restarted
    local STARTED_AT UPTIME_SECS RESTARTS
    STARTED_AT=$(docker inspect "$NAME" --format '{{.State.StartedAt}}' 2>/dev/null)
    UPTIME_SECS=$(( $(date +%s) - $(date -d "$STARTED_AT" +%s 2>/dev/null || echo 0) ))
    RESTARTS=$(docker inspect "$NAME" --format '{{.RestartCount}}' 2>/dev/null)
    if [ "$UPTIME_SECS" -lt 300 ] && [ "$RESTARTS" -gt 3 ] 2>/dev/null; then
        add_issue "**$NAME**: restarted ${UPTIME_SECS}s ago ($RESTARTS total restarts — possible crash loop)"
    fi
    # Check health if available
    local HEALTH
    HEALTH=$(docker inspect "$NAME" --format '{{.State.Health.Status}}' 2>/dev/null)
    if [ "$HEALTH" = "unhealthy" ]; then
        add_issue "**$NAME**: unhealthy"
    fi
}

# --- Arr app health API checks ---
check_arr_health() {
    local NAME="$1"
    local URL="$2"
    local KEY="$3"

    local RESPONSE
    RESPONSE=$(curl -sf --connect-timeout 5 "$URL/api/v3/health?apikey=$KEY" 2>/dev/null)
    if [ $? -ne 0 ]; then
        add_issue "**$NAME**: API unreachable"
        return
    fi

    # Check for errors (not just warnings)
    local ERRORS
    ERRORS=$(echo "$RESPONSE" | python3 -c "
import json, sys
items = json.load(sys.stdin)
errors = [i for i in items if i['type'] == 'error']
for e in errors:
    print(f\"{e['source']}: {e['message']}\")
" 2>/dev/null)

    if [ -n "$ERRORS" ]; then
        while IFS= read -r err; do
            add_issue "**$NAME**: $err"
        done <<< "$ERRORS"
    fi
}

# --- Prowlarr health (v1 API) ---
check_prowlarr_health() {
    local RESPONSE
    RESPONSE=$(curl -sf --connect-timeout 5 "http://localhost:9696/api/v1/health?apikey=$PROWLARR_KEY" 2>/dev/null)
    if [ $? -ne 0 ]; then
        add_issue "**Prowlarr**: API unreachable"
        return
    fi

    # Count disabled indexers
    local DISABLED
    DISABLED=$(curl -sf "http://localhost:9696/api/v1/indexerstatus?apikey=$PROWLARR_KEY" 2>/dev/null | python3 -c "
import json, sys
statuses = json.load(sys.stdin)
disabled = [s for s in statuses if s.get('disabledTill')]
if len(disabled) > 6:
    print(f'{len(disabled)} indexers disabled')
" 2>/dev/null)

    if [ -n "$DISABLED" ]; then
        add_issue "**Prowlarr**: $DISABLED"
    fi
}

# --- Trakt token expiry check ---
check_trakt_expiry() {
    local NAME="$1"
    local URL="$2"
    local KEY="$3"
    local LIST_ID="$4"

    local CONFIG
    CONFIG=$(curl -sf --connect-timeout 5 "$URL/api/v3/importlist/$LIST_ID?apikey=$KEY" 2>/dev/null)
    if [ $? -ne 0 ]; then
        return
    fi

    local DAYS_LEFT
    DAYS_LEFT=$(echo "$CONFIG" | python3 -c "
import json, sys
from datetime import datetime, timezone
config = json.load(sys.stdin)
for f in config.get('fields', []):
    if f['name'] == 'expires':
        exp = datetime.fromisoformat(f['value'].replace('Z', '+00:00'))
        remaining = (exp - datetime.now(timezone.utc)).days
        if remaining < 3:
            print(remaining)
        break
" 2>/dev/null)

    if [ -n "$DAYS_LEFT" ]; then
        add_issue "**$NAME Trakt token**: expires in ${DAYS_LEFT}d — auto-refresh should handle this"
    fi
}

# --- Plex check (on Spyglass) ---
check_plex() {
    local STATUS
    STATUS=$(curl -sf --connect-timeout 5 -o /dev/null -w '%{http_code}' "http://192.168.1.104:32400/identity" 2>/dev/null)
    if [ "$STATUS" != "200" ]; then
        add_issue "**Plex (Spyglass)**: HTTP $STATUS (expected 200)"
    fi
}

# --- Download client check ---
check_downloads() {
    # qBittorrent via Gluetun
    local QB_STATUS
    QB_STATUS=$(curl -sf --connect-timeout 5 -o /dev/null -w '%{http_code}' "http://localhost:8080/api/v2/app/version" 2>/dev/null)
    if [ "$QB_STATUS" != "200" ]; then
        add_issue "**qBittorrent**: HTTP $QB_STATUS"
    fi

    # SABnzbd
    local SAB_STATUS
    SAB_STATUS=$(curl -sf --connect-timeout 5 -o /dev/null -w '%{http_code}' "http://localhost:8085" 2>/dev/null)
    if [ "$SAB_STATUS" != "200" ] && [ "$SAB_STATUS" != "301" ] && [ "$SAB_STATUS" != "302" ]; then
        add_issue "**SABnzbd**: HTTP $SAB_STATUS"
    fi
}

# --- Disk space ---
check_disk() {
    local USAGE
    USAGE=$(df /opt --output=pcent | tail -1 | tr -d ' %')
    if [ "$USAGE" -gt 90 ]; then
        add_issue "**Disk /opt**: ${USAGE}% used"
    fi

    # NAS mount check (if applicable)
    if mountpoint -q /mnt/media 2>/dev/null; then
        local NAS_USAGE
        NAS_USAGE=$(df /mnt/media --output=pcent | tail -1 | tr -d ' %')
        if [ "$NAS_USAGE" -gt 90 ]; then
            add_issue "**NAS /mnt/media**: ${NAS_USAGE}% used"
        fi
    fi
}

# =========================================
# Run all checks
# =========================================
mkdir -p /var/log/arr-stack
log "=== Health check starting ==="

# Core containers
for C in radarr sonarr prowlarr gluetun qbittorrent sabnzbd bazarr lidarr whisparr flaresolverr; do
    check_container "$C"
done

# Arr health APIs
check_arr_health "Radarr" "http://localhost:7878" "$RADARR_KEY"
check_arr_health "Sonarr" "http://localhost:8989" "$SONARR_KEY"
check_prowlarr_health

# Trakt token expiry
check_trakt_expiry "Radarr" "http://localhost:7878" "$RADARR_KEY" 2
check_trakt_expiry "Sonarr" "http://localhost:8989" "$SONARR_KEY" 2

# Plex
check_plex

# Download clients
check_downloads

# Disk
check_disk

log "=== Health check complete: $ISSUE_COUNT issues ==="

# --- Alert if issues found ---
if [ $ISSUE_COUNT -gt 0 ]; then
    log "Issues found:$ISSUES"
    MSG="**SupArr Health Alert** ($ISSUE_COUNT issues):$(echo -e "$ISSUES")"
    curl -sf -X POST "$WEBHOOK_URL" \
        -H "Content-Type: application/json" \
        -d "$(python3 -c "import json; print(json.dumps({'content': '''$MSG'''}))")" \
        -o /dev/null
fi
