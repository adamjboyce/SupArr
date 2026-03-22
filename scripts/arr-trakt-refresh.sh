#!/usr/bin/env bash
# =============================================================================
# Trakt OAuth Token Auto-Refresh
# =============================================================================
# Refreshes Trakt OAuth tokens for all import lists in Radarr and Sonarr.
# Tokens expire in 7 days; this runs every 3 days to keep them alive.
#
# Uses auth.servarr.com renew endpoint (handles client_id/secret server-side).
# CRITICAL: Refresh tokens are single-use. Once consumed, the old one is dead.
# Always GET the latest token from the API before refreshing.
#
# API keys are extracted from running containers — never hardcoded.
# Trakt import lists are discovered dynamically — no hardcoded list IDs.
#
# Install (via init script Phase 8g, or manually):
#   crontab -e
#   0 6 */3 * * /opt/suparr/scripts/arr-trakt-refresh.sh >> /var/log/suparr-trakt-refresh.log 2>&1
# =============================================================================
set -uo pipefail

# --- Resolve compose .env for webhook ---
COMPOSE_DIR="${COMPOSE_DIR:-/opt/suparr/machine2-arr}"
DISCORD_WEBHOOK_URL="${DISCORD_WEBHOOK_URL:-}"
if [ -z "$DISCORD_WEBHOOK_URL" ] && [ -f "${COMPOSE_DIR}/.env" ]; then
    DISCORD_WEBHOOK_URL=$(grep '^DISCORD_WEBHOOK_URL=' "${COMPOSE_DIR}/.env" 2>/dev/null | cut -d'=' -f2- | tr -d "'" | tr -d '"' || true)
fi

LOG="/var/log/suparr-trakt-refresh.log"

# --- Helpers ---
log() { echo "$(date -u '+%Y-%m-%d %H:%M:%S UTC') $1"; }

notify_discord() {
    [ -z "$DISCORD_WEBHOOK_URL" ] && return
    local payload
    payload=$(jq -n --arg c "$1" --arg u "Trakt Refresh" '{username: $u, content: $c}') 2>/dev/null || return
    curl -sf -X POST "$DISCORD_WEBHOOK_URL" \
        -H "Content-Type: application/json" \
        -d "$payload" > /dev/null 2>&1 || true
}

get_api_key() {
    local container="$1"
    docker exec "$container" cat /config/config.xml 2>/dev/null \
        | grep -oP '(?<=<ApiKey>)[^<]+' \
        | head -1
}

# --- Refresh one import list's Trakt tokens ---
refresh_trakt_list() {
    local APP_NAME="$1"
    local APP_URL="$2"
    local API_KEY="$3"
    local LIST_ID="$4"
    local LIST_NAME="$5"

    log "[$APP_NAME] Refreshing Trakt token for list $LIST_ID ($LIST_NAME)"

    # GET current import list config
    local CONFIG
    CONFIG=$(curl -sf "$APP_URL/api/v3/importlist/$LIST_ID" \
        -H "X-Api-Key: $API_KEY" 2>/dev/null)
    if [ -z "$CONFIG" ]; then
        log "[$APP_NAME] ERROR: Failed to GET import list $LIST_ID"
        notify_discord "**Trakt Refresh FAILED** ($APP_NAME/$LIST_NAME): Could not read import list config"
        return 1
    fi

    # Extract current refresh token and expiry
    local REFRESH_TOKEN EXPIRES
    read -r REFRESH_TOKEN EXPIRES < <(echo "$CONFIG" | python3 -c "
import json, sys
config = json.load(sys.stdin)
rt = exp = ''
for f in config.get('fields', []):
    if f['name'] == 'refreshToken': rt = f.get('value', '')
    if f['name'] == 'expires': exp = f.get('value', '')
print(f'{rt} {exp}')
" 2>/dev/null)

    if [ -z "$REFRESH_TOKEN" ]; then
        log "[$APP_NAME] SKIP: No refresh token in list $LIST_ID ($LIST_NAME) — not a Trakt list or not authed"
        return 0
    fi

    log "[$APP_NAME] Current expiry: $EXPIRES"

    # Check if token needs refresh (< 4 days remaining)
    local SHOULD_REFRESH
    SHOULD_REFRESH=$(python3 -c "
from datetime import datetime, timezone, timedelta
try:
    exp = datetime.fromisoformat('$EXPIRES'.replace('Z', '+00:00'))
    remaining = exp - datetime.now(timezone.utc)
    print('yes' if remaining < timedelta(days=4) else 'no')
except:
    print('yes')
" 2>/dev/null)

    if [ "$SHOULD_REFRESH" = "no" ]; then
        log "[$APP_NAME] Token still valid for list $LIST_ID ($LIST_NAME), skipping"
        return 0
    fi

    # Call Servarr renew endpoint
    log "[$APP_NAME] Refreshing via auth.servarr.com..."
    local RENEW_RESPONSE
    RENEW_RESPONSE=$(curl -sf "https://auth.servarr.com/v1/trakt/renew?refresh_token=$REFRESH_TOKEN" 2>/dev/null)
    if [ -z "$RENEW_RESPONSE" ]; then
        log "[$APP_NAME] ERROR: Servarr renew failed for list $LIST_ID. Token may need manual re-auth."
        notify_discord "**Trakt Refresh FAILED** ($APP_NAME/$LIST_NAME): Servarr renew returned error. Manual re-auth needed in UI."
        return 1
    fi

    # Extract new tokens and update the config
    local UPDATED_CONFIG
    UPDATED_CONFIG=$(python3 -c "
import json, sys
from datetime import datetime, timezone, timedelta

renew = json.loads('''$RENEW_RESPONSE''')
config = json.load(sys.stdin)

new_access = renew.get('access_token', '')
new_refresh = renew.get('refresh_token', '')
expires_in = renew.get('expires_in', 604800)
new_expires = (datetime.now(timezone.utc) + timedelta(seconds=expires_in)).strftime('%Y-%m-%dT%H:%M:%SZ')

if not new_access or not new_refresh:
    sys.exit(1)

for f in config['fields']:
    if f['name'] == 'accessToken': f['value'] = new_access
    elif f['name'] == 'refreshToken': f['value'] = new_refresh
    elif f['name'] == 'expires': f['value'] = new_expires

print(json.dumps(config))
" <<< "$CONFIG" 2>/dev/null)

    if [ -z "$UPDATED_CONFIG" ]; then
        log "[$APP_NAME] ERROR: Could not parse renew response for list $LIST_ID"
        notify_discord "**Trakt Refresh FAILED** ($APP_NAME/$LIST_NAME): Could not parse Servarr response"
        return 1
    fi

    # PUT updated config back
    local PUT_STATUS
    PUT_STATUS=$(curl -sf -o /dev/null -w '%{http_code}' -X PUT \
        "$APP_URL/api/v3/importlist/$LIST_ID" \
        -H "X-Api-Key: $API_KEY" \
        -H "Content-Type: application/json" \
        -d "$UPDATED_CONFIG" 2>/dev/null)

    if [ "$PUT_STATUS" = "202" ] || [ "$PUT_STATUS" = "200" ]; then
        log "[$APP_NAME] SUCCESS: Token refreshed for list $LIST_ID ($LIST_NAME)"
        notify_discord "**Trakt Token Refreshed** ($APP_NAME/$LIST_NAME)"
        return 0
    else
        log "[$APP_NAME] ERROR: PUT returned $PUT_STATUS for list $LIST_ID. Tokens obtained but not saved!"
        notify_discord "**Trakt Refresh FAILED** ($APP_NAME/$LIST_NAME): PUT returned $PUT_STATUS"
        return 1
    fi
}

# --- Discover and refresh all Trakt import lists for an app ---
refresh_app() {
    local APP_NAME="$1"
    local APP_URL="$2"
    local CONTAINER="$3"

    local API_KEY
    API_KEY=$(get_api_key "$CONTAINER")
    if [ -z "$API_KEY" ]; then
        log "[$APP_NAME] SKIP: Container '$CONTAINER' not running or no API key"
        return 0
    fi

    # Get all import lists and find Trakt ones (have refreshToken field)
    local ALL_LISTS
    ALL_LISTS=$(curl -sf "$APP_URL/api/v3/importlist" \
        -H "X-Api-Key: $API_KEY" 2>/dev/null)
    if [ -z "$ALL_LISTS" ]; then
        log "[$APP_NAME] SKIP: Could not fetch import lists"
        return 0
    fi

    # Extract Trakt list IDs and names
    local TRAKT_LISTS
    TRAKT_LISTS=$(echo "$ALL_LISTS" | python3 -c "
import json, sys
lists = json.load(sys.stdin)
for lst in lists:
    fields = {f['name']: f.get('value', '') for f in lst.get('fields', [])}
    if fields.get('refreshToken'):
        print(f\"{lst['id']} {lst.get('name', 'unnamed')}\")
" 2>/dev/null)

    if [ -z "$TRAKT_LISTS" ]; then
        log "[$APP_NAME] No Trakt import lists found — skipping"
        return 0
    fi

    while IFS=' ' read -r list_id list_name; do
        refresh_trakt_list "$APP_NAME" "$APP_URL" "$API_KEY" "$list_id" "$list_name" || true
    done <<< "$TRAKT_LISTS"
}

# --- Main ---
log "=== Trakt refresh cycle starting ==="

refresh_app "Radarr" "http://localhost:7878" "radarr"
refresh_app "Sonarr" "http://localhost:8989" "sonarr"

log "=== Trakt refresh cycle complete ==="
