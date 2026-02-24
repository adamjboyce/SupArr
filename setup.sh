#!/usr/bin/env bash
# =============================================================================
# SupArr — Interactive Setup
# =============================================================================
# Single entry point for the entire media stack. Prompts for everything,
# writes .env, runs the appropriate init script, does post-config.
#
# Usage:
#   chmod +x setup.sh
#   sudo ./setup.sh
#
# Re-run safe — skips already-configured items and already-answered prompts
# if .env exists.
# =============================================================================

set -euo pipefail

# ── Colors & Helpers ─────────────────────────────────────────────────────────
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
CYAN='\033[0;36m'; BOLD='\033[1m'; DIM='\033[2m'; NC='\033[0m'

log()    { echo -e "${GREEN}[✓]${NC} $1"; }
warn()   { echo -e "${YELLOW}[!]${NC} $1"; }
err()    { echo -e "${RED}[✗]${NC} $1"; }
info()   { echo -e "${CYAN}[→]${NC} $1"; }
header() { echo -e "\n${BOLD}══════════════════════════════════════════════════${NC}"; echo -e "${BOLD}  $1${NC}"; echo -e "${BOLD}══════════════════════════════════════════════════${NC}\n"; }

validate_ip() {
    local ip="$1"
    [[ "$ip" =~ ^[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}$ ]] || return 1
    local IFS='.'; read -ra octets <<< "$ip"
    for octet in "${octets[@]}"; do (( octet <= 255 )) || return 1; done
}

validate_path() { [[ "$1" =~ ^/ ]]; }

# Prompt with default value. If .env already has a non-empty value, use that.
# Usage: ask VAR_NAME "Prompt text" "default_value" [secret]
ask() {
    local var_name="$1" prompt="$2" default="${3:-}" secret="${4:-}"
    local current="${!var_name:-}"

    # If already set and non-empty, keep it
    if [ -n "$current" ] && [ "$current" != "claim-XXXXXXXXXXXXXXXXXXXX" ] && \
       [ "$current" != "tskey-auth-XXXXXXXXXXXXXXXXXXXX" ] && \
       [ "$current" != "your_nord_service_email" ] && \
       [ "$current" != "your_nord_service_password" ]; then
        return
    fi

    local display_default=""
    if [ -n "$default" ]; then
        display_default=" ${DIM}[${default}]${NC}"
    fi

    if [ "$secret" = "secret" ]; then
        echo -en "${CYAN}  ${prompt}${display_default}: ${NC}"
        read -rs value
        echo ""
    else
        echo -en "${CYAN}  ${prompt}${display_default}: ${NC}"
        read -r value
    fi

    value="${value:-$default}"
    printf -v "$var_name" "%s" "$value"
}

# Yes/no prompt
ask_yn() {
    local prompt="$1" default="${2:-y}"
    local yn_hint="[Y/n]"
    [ "$default" = "n" ] && yn_hint="[y/N]"
    echo -en "${CYAN}  ${prompt} ${yn_hint}: ${NC}"
    read -r answer
    answer="${answer:-$default}"
    [[ "$answer" =~ ^[Yy] ]]
}

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

# ── Detect which machine we're on ───────────────────────────────────────────
header "SupArr Setup"

echo -e "  ${BOLD}Welcome to SupArr.${NC}"
echo -e "  Two machines. One NAS. One script to rule them all.\n"

# Check for iGPU to auto-detect machine role
HAS_IGPU=false
[ -e /dev/dri/renderD128 ] && HAS_IGPU=true

# Check RAM to help guess
TOTAL_RAM_GB=$(awk '/MemTotal/ {printf "%.0f", $2/1024/1024}' /proc/meminfo 2>/dev/null || echo "0")

if [ "$HAS_IGPU" = true ] && [ "$TOTAL_RAM_GB" -lt 64 ]; then
    DETECTED_ROLE="plex"
    info "Detected: Intel iGPU + ${TOTAL_RAM_GB}GB RAM → looks like Spyglass (Plex)"
elif [ "$HAS_IGPU" = false ] && [ "$TOTAL_RAM_GB" -ge 64 ]; then
    DETECTED_ROLE="arr"
    info "Detected: ${TOTAL_RAM_GB}GB RAM, no iGPU → looks like Privateer (*arr)"
else
    DETECTED_ROLE=""
fi

echo ""
echo -e "  ${BOLD}Which machine is this?${NC}"
echo -e "    ${BOLD}1)${NC} Spyglass  — Plex Server (needs Intel Quick Sync for HW transcoding)"
echo -e "    ${BOLD}2)${NC} Privateer — *arr Stack  (download + library management)"
echo -e "    ${BOLD}3)${NC} Both      — Single Machine (everything on one box)"
echo ""

if [ "$HAS_IGPU" = true ] && [ "$TOTAL_RAM_GB" -ge 64 ]; then
    DETECTED_ROLE="both"
    info "Detected: iGPU + ${TOTAL_RAM_GB}GB RAM → could run both stacks"
fi

if [ "$DETECTED_ROLE" = "plex" ]; then
    default_choice="1"
elif [ "$DETECTED_ROLE" = "arr" ]; then
    default_choice="2"
elif [ "$DETECTED_ROLE" = "both" ]; then
    default_choice="3"
else
    default_choice=""
fi

echo -en "${CYAN}  Choose [1/2/3]${default_choice:+ [${default_choice}]}: ${NC}"
read -r MACHINE_CHOICE
MACHINE_CHOICE="${MACHINE_CHOICE:-$default_choice}"

case "$MACHINE_CHOICE" in
    1) ROLE="plex" ;;
    2) ROLE="arr" ;;
    3) ROLE="both" ;;
    *) err "Invalid choice. Run again and pick 1, 2, or 3."; exit 1 ;;
esac

# ── Load existing .env if present ────────────────────────────────────────────
PLEX_PROJECT_DIR="$SCRIPT_DIR/machine1-plex"
ARR_PROJECT_DIR="$SCRIPT_DIR/machine2-arr"

if [ "$ROLE" = "plex" ]; then
    PROJECT_DIR="$PLEX_PROJECT_DIR"
    INIT_SCRIPT="$SCRIPT_DIR/scripts/init-machine1-plex.sh"
elif [ "$ROLE" = "arr" ]; then
    PROJECT_DIR="$ARR_PROJECT_DIR"
    INIT_SCRIPT="$SCRIPT_DIR/scripts/init-machine2-arr.sh"
else
    # both — load from arr .env first (has more vars), plex overrides if present
    PROJECT_DIR="$ARR_PROJECT_DIR"
fi

if [ "$ROLE" = "both" ]; then
    [ -f "$PLEX_PROJECT_DIR/.env" ] && { set -a; source "$PLEX_PROJECT_DIR/.env"; set +a; }
    [ -f "$ARR_PROJECT_DIR/.env" ] && { set -a; source "$ARR_PROJECT_DIR/.env"; set +a; }
    [ -f "$PLEX_PROJECT_DIR/.env" ] || [ -f "$ARR_PROJECT_DIR/.env" ] && \
        log "Loaded existing .env files — will skip already-answered questions"
else
    ENV_FILE="$PROJECT_DIR/.env"
    if [ -f "$ENV_FILE" ]; then
        set -a; source "$ENV_FILE"; set +a
        log "Loaded existing .env — will skip already-answered questions"
    fi
fi

# ── Common Questions ─────────────────────────────────────────────────────────
header "Basic Configuration"

ask PUID "User ID (run 'id -u' to check)" "1000"
ask PGID "Group ID (run 'id -g' to check)" "1000"
ask TZ "Timezone" "America/Chicago"

header "NAS Configuration"

ask NAS_IP "NAS IP address (leave blank to skip NFS setup)" ""
if [ -n "$NAS_IP" ] && ! validate_ip "$NAS_IP"; then
    err "Invalid IP address: $NAS_IP"; exit 1
fi
if [ -n "$NAS_IP" ]; then
    ask NAS_MEDIA_EXPORT "NAS media export path" "/volume1/media"
    if [ "$ROLE" = "arr" ] || [ "$ROLE" = "both" ]; then
        ask NAS_DOWNLOADS_EXPORT "NAS downloads export path" "/volume1/downloads"
    fi
fi

ask MEDIA_ROOT "Local media mount point" "/mnt/media"
validate_path "$MEDIA_ROOT" || { err "MEDIA_ROOT must be an absolute path (start with /)"; exit 1; }

if [ "$ROLE" = "plex" ]; then
    ask APPDATA "App data directory (local SSD)" "/opt/media-stack"
    validate_path "$APPDATA" || { err "APPDATA must be an absolute path (start with /)"; exit 1; }
elif [ "$ROLE" = "both" ]; then
    ask PLEX_APPDATA "Spyglass (Plex) app data directory" "/opt/media-stack"
    validate_path "$PLEX_APPDATA" || { err "Plex APPDATA must be an absolute path"; exit 1; }
    ask ARR_APPDATA "Privateer (*arr) app data directory" "/opt/arr-stack"
    validate_path "$ARR_APPDATA" || { err "*arr APPDATA must be an absolute path"; exit 1; }
    ask DOWNLOADS_ROOT "Download scratch directory (local NVMe ideal)" "/mnt/downloads"
    validate_path "$DOWNLOADS_ROOT" || { err "DOWNLOADS_ROOT must be an absolute path"; exit 1; }
else
    ask APPDATA "App data directory (local SSD)" "/opt/arr-stack"
    validate_path "$APPDATA" || { err "APPDATA must be an absolute path (start with /)"; exit 1; }
    ask DOWNLOADS_ROOT "Download scratch directory (local NVMe ideal)" "/mnt/downloads"
    validate_path "$DOWNLOADS_ROOT" || { err "DOWNLOADS_ROOT must be an absolute path"; exit 1; }
fi

header "Tailscale — Remote Access"
echo -e "  ${DIM}Tailscale lets you access everything remotely with zero ports exposed.${NC}"
echo -e "  ${DIM}Generate a key at: https://login.tailscale.com/admin/settings/keys${NC}\n"

ask TAILSCALE_AUTH_KEY "Tailscale auth key (or 'skip')" "skip"
ask LOCAL_SUBNET "Local network subnet" "192.168.1.0/24"

# ── Role-Specific Questions ──────────────────────────────────────────────────

collect_plex_questions() {
    header "Spyglass — Plex Configuration"
    echo -e "  ${DIM}Get a claim token at: https://plex.tv/claim (valid ~4 minutes)${NC}"
    echo -e "  ${DIM}You can also set this later — just re-run setup.${NC}\n"

    ask PLEX_CLAIM_TOKEN "Plex claim token (or 'skip')" "skip"

    echo -e "\n  ${DIM}Plex token for Kometa/Tautulli integration.${NC}"
    echo -e "  ${DIM}Find it: https://support.plex.tv/articles/204059436${NC}\n"
    ask PLEX_TOKEN "Plex token (or 'skip' — set later)" "skip"
    ask PLEX_IP "Plex server IP for Kometa" "localhost"

    header "Kometa — Library Aesthetics"
    echo -e "  ${DIM}Kometa makes your Plex look like a real streaming service.${NC}"
    echo -e "  ${DIM}These are all free API keys. Skip any you don't have yet.${NC}\n"

    ask TMDB_API_KEY "TMDb API key (free: themoviedb.org/settings/api)" "skip"
    ask MDBLIST_API_KEY "MDBList API key (free: mdblist.com/preferences)" "skip"
    ask TRAKT_CLIENT_ID "Trakt client ID (trakt.tv/oauth/applications)" "skip"
    ask TRAKT_CLIENT_SECRET "Trakt client secret" "skip"

    # Clean up "skip" values
    [ "$PLEX_CLAIM_TOKEN" = "skip" ] && PLEX_CLAIM_TOKEN=""
    [ "$PLEX_TOKEN" = "skip" ] && PLEX_TOKEN=""
    [ "$TMDB_API_KEY" = "skip" ] && TMDB_API_KEY=""
    [ "$MDBLIST_API_KEY" = "skip" ] && MDBLIST_API_KEY=""
    [ "$TRAKT_CLIENT_ID" = "skip" ] && TRAKT_CLIENT_ID=""
    [ "$TRAKT_CLIENT_SECRET" = "skip" ] && TRAKT_CLIENT_SECRET=""
}

collect_arr_questions() {
    header "Privateer — NordVPN Configuration"
    echo -e "  ${DIM}All download traffic routes through this VPN tunnel.${NC}"
    echo -e "  ${DIM}Kill switch is automatic — if VPN drops, downloads stop. No leaks.${NC}\n"

    echo -e "  ${BOLD}VPN type?${NC}"
    echo -e "    ${BOLD}1)${NC} OpenVPN (easier — use Nord service credentials)"
    echo -e "    ${BOLD}2)${NC} WireGuard/NordLynx (faster — needs private key)"
    echo ""
    echo -en "${CYAN}  Choose [1/2] [1]: ${NC}"
    read -r vpn_choice
    vpn_choice="${vpn_choice:-1}"

    if [ "$vpn_choice" = "2" ]; then
        NORD_VPN_TYPE="wireguard"
        ask NORD_WIREGUARD_KEY "NordLynx private key" "" "secret"
        NORD_USER="${NORD_USER:-}"
        NORD_PASS="${NORD_PASS:-}"
    else
        NORD_VPN_TYPE="openvpn"
        echo -e "\n  ${DIM}Nord service credentials (NOT your login email/password).${NC}"
        echo -e "  ${DIM}Find them at: https://my.nordaccount.com/dashboard/nordvpn/manual-configuration/${NC}\n"
        ask NORD_USER "Nord service username" ""
        ask NORD_PASS "Nord service password" "" "secret"
        NORD_WIREGUARD_KEY="${NORD_WIREGUARD_KEY:-}"
    fi

    ask NORD_COUNTRY "VPN server country" "United States"
    ask NORD_CITY "VPN server city (blank for auto)" ""

    header "qBittorrent"
    echo -e "  ${DIM}Setting a custom password now so you don't have to change it later.${NC}\n"
    ask QBIT_PASSWORD "qBittorrent web UI password" "SupArr2026!" "secret"

    header "Notification & Monitoring"
    ask NOTIFIARR_API_KEY "Notifiarr API key (notifiarr.com, or 'skip')" "skip"

    [ "$NOTIFIARR_API_KEY" = "skip" ] && NOTIFIARR_API_KEY=""

    # API keys — init script populates these automatically
    RADARR_API_KEY="${RADARR_API_KEY:-}"
    SONARR_API_KEY="${SONARR_API_KEY:-}"
    LIDARR_API_KEY="${LIDARR_API_KEY:-}"
    PROWLARR_API_KEY="${PROWLARR_API_KEY:-}"
    BAZARR_API_KEY="${BAZARR_API_KEY:-}"
    READARR_API_KEY="${READARR_API_KEY:-}"
    WHISPARR_API_KEY="${WHISPARR_API_KEY:-}"
    SABNZBD_API_KEY="${SABNZBD_API_KEY:-}"
}

if [ "$ROLE" = "plex" ]; then
    collect_plex_questions
    ask WATCHTOWER_NOTIFICATION_URL "Notification URL for updates (or 'skip')" "skip"
    [ "$WATCHTOWER_NOTIFICATION_URL" = "skip" ] && WATCHTOWER_NOTIFICATION_URL=""
    [ "$TAILSCALE_AUTH_KEY" = "skip" ] && TAILSCALE_AUTH_KEY=""

elif [ "$ROLE" = "both" ]; then
    collect_plex_questions
    collect_arr_questions
    ask WATCHTOWER_NOTIFICATION_URL "Watchtower notification URL (or 'skip')" "skip"
    [ "$WATCHTOWER_NOTIFICATION_URL" = "skip" ] && WATCHTOWER_NOTIFICATION_URL=""
    [ "$TAILSCALE_AUTH_KEY" = "skip" ] && TAILSCALE_AUTH_KEY=""

else
    collect_arr_questions
    ask WATCHTOWER_NOTIFICATION_URL "Watchtower notification URL (or 'skip')" "skip"
    [ "$WATCHTOWER_NOTIFICATION_URL" = "skip" ] && WATCHTOWER_NOTIFICATION_URL=""
    [ "$TAILSCALE_AUTH_KEY" = "skip" ] && TAILSCALE_AUTH_KEY=""
fi

# ── Write .env ───────────────────────────────────────────────────────────────
header "Writing Configuration"

write_plex_env() {
    local target="$1"
    local appdata_val="${2:-$APPDATA}"
    cat > "$target" <<ENVEOF
# =============================================================================
# Spyglass (Plex Server) — Generated by SupArr setup.sh
# =============================================================================
PUID=${PUID}
PGID=${PGID}
TZ=${TZ}
MEDIA_ROOT=${MEDIA_ROOT}
APPDATA=${appdata_val}
NAS_IP=${NAS_IP}
NAS_MEDIA_EXPORT=${NAS_MEDIA_EXPORT:-}
PLEX_CLAIM_TOKEN=${PLEX_CLAIM_TOKEN}
PLEX_TOKEN=${PLEX_TOKEN}
PLEX_IP=${PLEX_IP}
TAILSCALE_AUTH_KEY=${TAILSCALE_AUTH_KEY}
LOCAL_SUBNET=${LOCAL_SUBNET}
TMDB_API_KEY=${TMDB_API_KEY}
MDBLIST_API_KEY=${MDBLIST_API_KEY}
TRAKT_CLIENT_ID=${TRAKT_CLIENT_ID}
TRAKT_CLIENT_SECRET=${TRAKT_CLIENT_SECRET}
WATCHTOWER_NOTIFICATION_URL=${WATCHTOWER_NOTIFICATION_URL}
ENVEOF
    chmod 600 "$target"
}

write_arr_env() {
    local target="$1"
    local appdata_val="${2:-$APPDATA}"
    cat > "$target" <<ENVEOF
# =============================================================================
# Privateer (*arr Stack) — Generated by SupArr setup.sh
# =============================================================================
PUID=${PUID}
PGID=${PGID}
TZ=${TZ}
MEDIA_ROOT=${MEDIA_ROOT}
DOWNLOADS_ROOT=${DOWNLOADS_ROOT}
APPDATA=${appdata_val}
NAS_IP=${NAS_IP}
NAS_MEDIA_EXPORT=${NAS_MEDIA_EXPORT:-}
NAS_DOWNLOADS_EXPORT=${NAS_DOWNLOADS_EXPORT:-}
NORD_VPN_TYPE=${NORD_VPN_TYPE}
NORD_USER=${NORD_USER:-}
NORD_PASS=${NORD_PASS:-}
NORD_WIREGUARD_KEY=${NORD_WIREGUARD_KEY:-}
NORD_COUNTRY=${NORD_COUNTRY}
NORD_CITY=${NORD_CITY}
LOCAL_SUBNET=${LOCAL_SUBNET}
TAILSCALE_AUTH_KEY=${TAILSCALE_AUTH_KEY}
QBIT_PASSWORD=${QBIT_PASSWORD:-SupArr2026!}
RADARR_API_KEY=${RADARR_API_KEY}
SONARR_API_KEY=${SONARR_API_KEY}
LIDARR_API_KEY=${LIDARR_API_KEY}
PROWLARR_API_KEY=${PROWLARR_API_KEY}
BAZARR_API_KEY=${BAZARR_API_KEY}
READARR_API_KEY=${READARR_API_KEY}
WHISPARR_API_KEY=${WHISPARR_API_KEY}
SABNZBD_API_KEY=${SABNZBD_API_KEY}
NOTIFIARR_API_KEY=${NOTIFIARR_API_KEY}
WATCHTOWER_NOTIFICATION_URL=${WATCHTOWER_NOTIFICATION_URL}
ENVEOF
    chmod 600 "$target"
}

if [ "$ROLE" = "plex" ]; then
    write_plex_env "$PLEX_PROJECT_DIR/.env"
    log "Configuration written to $PLEX_PROJECT_DIR/.env"
elif [ "$ROLE" = "both" ]; then
    write_plex_env "$PLEX_PROJECT_DIR/.env" "$PLEX_APPDATA"
    write_arr_env "$ARR_PROJECT_DIR/.env" "$ARR_APPDATA"
    log "Configuration written to both .env files"
else
    write_arr_env "$ARR_PROJECT_DIR/.env"
    log "Configuration written to $ARR_PROJECT_DIR/.env"
fi

# ── Confirm and Launch ───────────────────────────────────────────────────────
header "Ready to Deploy"

if [ "$ROLE" = "plex" ]; then
    echo -e "  Machine:    ${BOLD}Spyglass (Plex Server)${NC}"
    echo -e "  App data:   ${APPDATA}"
elif [ "$ROLE" = "both" ]; then
    echo -e "  Mode:       ${BOLD}Single Machine (Spyglass + Privateer)${NC}"
    echo -e "  Plex data:  ${PLEX_APPDATA}"
    echo -e "  *arr data:  ${ARR_APPDATA}"
else
    echo -e "  Machine:    ${BOLD}Privateer (*arr Stack)${NC}"
    echo -e "  App data:   ${APPDATA}"
fi
echo -e "  Media:      ${MEDIA_ROOT}"
[ -n "$NAS_IP" ] && echo -e "  NAS:        ${NAS_IP}"
echo ""

if ! ask_yn "Deploy now?" "y"; then
    if [ "$ROLE" = "both" ]; then
        log "Config saved. Run init scripts manually when ready."
    else
        log "Config saved — run the init script when ready."
    fi
    exit 0
fi

# ── Overseerr readiness check (quiet — no output) ─────────────────────────────
check_overseerr_ready() {
    local plex_appdata="$1"
    local settings="$plex_appdata/overseerr/config/settings.json"
    [ -f "$settings" ] || return 1
    local os_key
    os_key=$(jq -r '.main.apiKey // empty' "$settings" 2>/dev/null || echo "")
    [ -z "$os_key" ] && return 1
    curl -sf -o /dev/null "http://localhost:5055/api/v1/settings/public" 2>/dev/null || return 1
    local initialized
    initialized=$(curl -sf "http://localhost:5055/api/v1/settings/public" 2>/dev/null | jq -r '.initialized // false' 2>/dev/null || echo "false")
    [ "$initialized" = "true" ]
}

# ── Plex library check (quiet — no output) ─────────────────────────────────────
check_plex_has_libraries() {
    local plex_token="${1:-}"
    local url="http://localhost:32400/library/sections"
    [ -n "$plex_token" ] && url="${url}?X-Plex-Token=${plex_token}"
    local count
    count=$(curl -sf -H "Accept: application/json" "$url" 2>/dev/null | jq '.MediaContainer.size // 0' 2>/dev/null || echo "0")
    [ "${count:-0}" -gt 0 ]
}

# ── Kometa first-run trigger ──────────────────────────────────────────────────
trigger_kometa_first_run() {
    local plex_appdata="$1"
    local marker="$plex_appdata/kometa/.first-run-triggered"

    if [ -f "$marker" ]; then
        log "Kometa first run already triggered previously"
        return 0
    fi

    if ! docker ps --format '{{.Names}}' | grep -q '^kometa$'; then
        warn "Kometa container not running"
        return 1
    fi

    info "Triggering Kometa first run (processes entire library)..."
    docker exec -d kometa python kometa.py --run
    touch "$marker"
    log "Kometa first run started in background"
    echo -e "  ${DIM}Takes hours on first run. Check progress: docker logs -f kometa${NC}"
    return 0
}

# ── Overseerr auto-config helper ─────────────────────────────────────────────
configure_overseerr() {
    local arr_host="$1" radarr_key="$2" sonarr_key="$3" plex_appdata="$4"

    if [ -z "$radarr_key" ] && [ -z "$sonarr_key" ]; then
        warn "Overseerr: no *arr API keys available — skipping"
        return 1
    fi

    info "Configuring Overseerr → Radarr/Sonarr..."

    # Read Overseerr API key from settings.json
    local settings="$plex_appdata/overseerr/config/settings.json"
    if [ ! -f "$settings" ]; then
        warn "Overseerr not initialized — complete the setup wizard at http://localhost:5055 first, then re-run"
        return
    fi

    local os_key
    os_key=$(jq -r '.main.apiKey // empty' "$settings" 2>/dev/null || echo "")
    if [ -z "$os_key" ]; then
        warn "Overseerr API key not found — complete the setup wizard first"
        return 1
    fi

    local os_url="http://localhost:5055/api/v1"

    # Wait for API
    local ready=false
    for _ in $(seq 1 10); do
        if curl -sf -o /dev/null "${os_url}/settings/public" 2>/dev/null; then
            ready=true; break
        fi
        sleep 2
    done
    if [ "$ready" = false ]; then
        warn "Overseerr API not responding"
        return 1
    fi

    # Check if initialized
    local initialized
    initialized=$(curl -sf "${os_url}/settings/public" 2>/dev/null | jq -r '.initialized // false' 2>/dev/null || echo "false")
    if [ "$initialized" != "true" ]; then
        warn "Overseerr not initialized — complete setup wizard first, then re-run"
        return 1
    fi

    # --- Radarr ---
    if [ -n "$radarr_key" ]; then
        local existing
        existing=$(curl -sf "${os_url}/settings/radarr" -H "X-Api-Key: ${os_key}" 2>/dev/null | jq 'length' 2>/dev/null || echo "0")
        if [ "${existing:-0}" -eq 0 ]; then
            local prof_id prof_name root_path
            prof_id=$(curl -sf "http://${arr_host}:7878/api/v3/qualityprofile" -H "X-Api-Key: ${radarr_key}" 2>/dev/null | jq '.[0].id // 1' 2>/dev/null || echo "1")
            prof_name=$(curl -sf "http://${arr_host}:7878/api/v3/qualityprofile" -H "X-Api-Key: ${radarr_key}" 2>/dev/null | jq -r '.[0].name // "Any"' 2>/dev/null || echo "Any")
            root_path=$(curl -sf "http://${arr_host}:7878/api/v3/rootfolder" -H "X-Api-Key: ${radarr_key}" 2>/dev/null | jq -r '.[0].path // "/movies"' 2>/dev/null || echo "/movies")

            curl -sf -X POST "${os_url}/settings/radarr" \
                -H "X-Api-Key: ${os_key}" \
                -H "Content-Type: application/json" \
                -d "{
                    \"name\": \"Radarr\",
                    \"hostname\": \"${arr_host}\",
                    \"port\": 7878,
                    \"apiKey\": \"${radarr_key}\",
                    \"useSsl\": false,
                    \"baseUrl\": \"\",
                    \"activeProfileId\": ${prof_id},
                    \"activeProfileName\": \"${prof_name}\",
                    \"activeDirectory\": \"${root_path}\",
                    \"is4k\": false,
                    \"minimumAvailability\": \"released\",
                    \"isDefault\": true,
                    \"externalUrl\": \"\",
                    \"syncEnabled\": false,
                    \"preventSearch\": false
                }" > /dev/null 2>&1 && \
                log "  Overseerr → Radarr (${arr_host}:7878)" || \
                warn "  Overseerr → Radarr failed"
        else
            log "  Overseerr → Radarr already configured"
        fi
    fi

    # --- Sonarr ---
    if [ -n "$sonarr_key" ]; then
        local existing
        existing=$(curl -sf "${os_url}/settings/sonarr" -H "X-Api-Key: ${os_key}" 2>/dev/null | jq 'length' 2>/dev/null || echo "0")
        if [ "${existing:-0}" -eq 0 ]; then
            local prof_id prof_name root_path anime_path
            prof_id=$(curl -sf "http://${arr_host}:8989/api/v3/qualityprofile" -H "X-Api-Key: ${sonarr_key}" 2>/dev/null | jq '.[0].id // 1' 2>/dev/null || echo "1")
            prof_name=$(curl -sf "http://${arr_host}:8989/api/v3/qualityprofile" -H "X-Api-Key: ${sonarr_key}" 2>/dev/null | jq -r '.[0].name // "Any"' 2>/dev/null || echo "Any")
            root_path=$(curl -sf "http://${arr_host}:8989/api/v3/rootfolder" -H "X-Api-Key: ${sonarr_key}" 2>/dev/null | jq -r '.[0].path // "/tv"' 2>/dev/null || echo "/tv")
            anime_path=$(curl -sf "http://${arr_host}:8989/api/v3/rootfolder" -H "X-Api-Key: ${sonarr_key}" 2>/dev/null | jq -r '[.[] | select(.path | test("anime"))] | .[0].path // "/anime"' 2>/dev/null || echo "/anime")

            curl -sf -X POST "${os_url}/settings/sonarr" \
                -H "X-Api-Key: ${os_key}" \
                -H "Content-Type: application/json" \
                -d "{
                    \"name\": \"Sonarr\",
                    \"hostname\": \"${arr_host}\",
                    \"port\": 8989,
                    \"apiKey\": \"${sonarr_key}\",
                    \"useSsl\": false,
                    \"baseUrl\": \"\",
                    \"activeProfileId\": ${prof_id},
                    \"activeProfileName\": \"${prof_name}\",
                    \"activeDirectory\": \"${root_path}\",
                    \"activeAnimeProfileId\": ${prof_id},
                    \"activeAnimeProfileName\": \"${prof_name}\",
                    \"activeAnimeDirectory\": \"${anime_path}\",
                    \"is4k\": false,
                    \"enableSeasonFolders\": true,
                    \"isDefault\": true,
                    \"externalUrl\": \"\",
                    \"syncEnabled\": false,
                    \"preventSearch\": false
                }" > /dev/null 2>&1 && \
                log "  Overseerr → Sonarr (${arr_host}:8989)" || \
                warn "  Overseerr → Sonarr failed"
        else
            log "  Overseerr → Sonarr already configured"
        fi
    fi
}

# ── Run Init Script(s) ──────────────────────────────────────────────────────
header "Deploying..."

if [ "$ROLE" = "both" ]; then
    info "Deploying Spyglass (Plex) stack..."
    chmod +x "$SCRIPT_DIR/scripts/init-machine1-plex.sh"
    bash "$SCRIPT_DIR/scripts/init-machine1-plex.sh"

    info "Deploying Privateer (*arr) stack..."
    chmod +x "$SCRIPT_DIR/scripts/init-machine2-arr.sh"
    bash "$SCRIPT_DIR/scripts/init-machine2-arr.sh"

    # Re-source *arr .env to get discovered API keys
    set -a; source "$ARR_PROJECT_DIR/.env"; set +a

    # Detect machine IP for cross-stack Overseerr → *arr connection
    MACHINE_IP=$(hostname -I 2>/dev/null | awk '{print $1}')
    [ -z "${MACHINE_IP:-}" ] && MACHINE_IP="localhost"

    OVERSEERR_CONFIGURED=false
    header "Overseerr → Radarr/Sonarr"
    configure_overseerr "$MACHINE_IP" "${RADARR_API_KEY:-}" "${SONARR_API_KEY:-}" "$PLEX_APPDATA" && \
        OVERSEERR_CONFIGURED=true

    # Try Kometa first run if Plex already has libraries
    KOMETA_TRIGGERED=false
    if check_plex_has_libraries "${PLEX_TOKEN:-}"; then
        trigger_kometa_first_run "$PLEX_APPDATA" && KOMETA_TRIGGERED=true
    fi

elif [ "$ROLE" = "plex" ]; then
    chmod +x "$SCRIPT_DIR/scripts/init-machine1-plex.sh"
    bash "$SCRIPT_DIR/scripts/init-machine1-plex.sh"

    # Try Kometa first run if Plex already has libraries
    KOMETA_TRIGGERED=false
    if check_plex_has_libraries "${PLEX_TOKEN:-}"; then
        trigger_kometa_first_run "$APPDATA" && KOMETA_TRIGGERED=true
    fi
else
    chmod +x "$SCRIPT_DIR/scripts/init-machine2-arr.sh"
    bash "$SCRIPT_DIR/scripts/init-machine2-arr.sh"
fi

# ── Final Report ─────────────────────────────────────────────────────────────
header "SupArr Deployment Complete"

echo ""
if [ "$ROLE" = "plex" ] || [ "$ROLE" = "both" ]; then
    echo -e "  ${GREEN}${BOLD}Spyglass (Plex Server) is live.${NC}"
    echo ""
    echo -e "  ${BOLD}Still needs your eyeballs:${NC}"
    echo ""
    echo -e "    ${BOLD}Plex${NC}  →  http://localhost:32400/web"
    echo -e "    ${DIM}Complete setup wizard, add libraries, claim server${NC}"
    echo ""
    echo -e "    ${BOLD}Tdarr${NC}  →  http://localhost:8265"
    echo -e "    ${DIM}Add libraries, then plugins in order:${NC}"
    echo -e "    ${DIM}  1. Migz5ConvertContainer → MKV${NC}"
    echo -e "    ${DIM}  2. Migz1FFMPEG → H.265/QSV${NC}"
    echo -e "    ${DIM}  3. Migz3CleanAudio → keep English + original${NC}"
    echo -e "    ${DIM}  4. Migz4CleanSubs → keep English + ${BOLD}FORCED${NC}${DIM} ⚠️${NC}"
    echo ""
    echo -e "    ${BOLD}Overseerr${NC}  →  http://localhost:5055"
    if [ "$ROLE" = "both" ] && [ "${OVERSEERR_CONFIGURED:-false}" = true ]; then
        echo -e "    ${DIM}Sign in with Plex (Radarr + Sonarr auto-configured)${NC}"
    elif [ "$ROLE" = "both" ]; then
        echo -e "    ${DIM}Sign in with Plex, then connect Radarr + Sonarr at localhost${NC}"
    else
        echo -e "    ${DIM}Sign in with Plex, connect Radarr + Sonarr on Privateer${NC}"
    fi
    echo ""
    if [ "${KOMETA_TRIGGERED:-false}" = true ]; then
        echo -e "    ${BOLD}Kometa${NC}  →  First run started in background"
        echo -e "    ${DIM}Check progress: docker logs -f kometa${NC}"
    else
        echo -e "    ${BOLD}Kometa${NC}  →  Auto-starts when Plex libraries are detected"
    fi
    echo ""
fi

if [ "$ROLE" = "arr" ] || [ "$ROLE" = "both" ]; then
    echo -e "  ${GREEN}${BOLD}Privateer (*arr Stack) is live.${NC}"
    echo ""
    echo -e "  ${BOLD}Verify VPN:${NC}"
    echo -e "    docker exec gluetun wget -qO- https://ipinfo.io"
    echo -e "    ${DIM}(should show NordVPN IP, not yours)${NC}"
    echo ""
    echo -e "  ${BOLD}Still needs your eyeballs:${NC}"
    echo ""
    echo -e "    ${BOLD}Prowlarr${NC}  →  http://localhost:9696"
    echo -e "    ${DIM}Add your indexers (this requires your credentials)${NC}"
    echo ""
    echo -e "    ${BOLD}SABnzbd${NC}  →  http://localhost:8085"
    echo -e "    ${DIM}Run setup wizard, add Usenet server credentials${NC}"
    echo ""
    echo -e "    ${BOLD}Bazarr${NC}  →  http://localhost:6767"
    echo -e "    ${DIM}Verify: Languages → English → Forced = Both${NC}"
    echo -e "    ${DIM}Add providers: OpenSubtitles.com (free account)${NC}"
    echo ""
    echo -e "    ${BOLD}Radarr Lists${NC}  →  http://localhost:7878/settings/importlists"
    echo -e "    ${DIM}The CouchPotato replacement:${NC}"
    echo -e "    ${DIM}  1. Create filters at mdblist.com (RT > 85%, etc.)${NC}"
    echo -e "    ${DIM}  2. Add as MDBList import in Radarr${NC}"
    echo -e "    ${DIM}  3. Auto-downloads matching movies forever${NC}"
fi

echo ""
echo -e "  ${DIM}This script is re-run safe. Run it again any time to${NC}"
echo -e "  ${DIM}update config or finish setup after adding credentials.${NC}"
echo ""

# ── Post-deploy polling (Overseerr + Kometa) ──────────────────────────────────
NEED_OVERSEERR_POLL=false
NEED_KOMETA_POLL=false

if [ "$ROLE" = "both" ] && [ "${OVERSEERR_CONFIGURED:-false}" != true ]; then
    NEED_OVERSEERR_POLL=true
fi

POLL_PLEX_APPDATA=""
if [ "$ROLE" = "both" ]; then
    POLL_PLEX_APPDATA="$PLEX_APPDATA"
elif [ "$ROLE" = "plex" ]; then
    POLL_PLEX_APPDATA="$APPDATA"
fi

if [ -n "$POLL_PLEX_APPDATA" ] && [ "${KOMETA_TRIGGERED:-false}" != true ]; then
    NEED_KOMETA_POLL=true
fi

if [ "$NEED_OVERSEERR_POLL" = true ] || [ "$NEED_KOMETA_POLL" = true ]; then
    header "Waiting for Manual Steps"

    if [ "$NEED_OVERSEERR_POLL" = true ]; then
        echo -e "  ${BOLD}Overseerr:${NC}"
        echo -e "    1. Open ${BOLD}http://localhost:5055${NC}"
        echo -e "    2. Sign in with your Plex account"
        echo -e "    3. Complete the setup wizard"
        echo -e "    ${DIM}→ Radarr/Sonarr will be auto-configured${NC}"
        echo ""
    fi

    if [ "$NEED_KOMETA_POLL" = true ]; then
        echo -e "  ${BOLD}Plex Libraries:${NC}"
        echo -e "    1. Open ${BOLD}http://localhost:32400/web${NC}"
        echo -e "    2. Complete setup wizard + add media libraries"
        echo -e "    ${DIM}→ Kometa first run will auto-start${NC}"
        echo ""
    fi

    info "Checking every 60 seconds... (Ctrl+C to skip)"
    echo ""

    POLL_ELAPSED=0
    POLL_MAX=7200
    POLL_INTERVAL=60

    while [ $POLL_ELAPSED -lt $POLL_MAX ]; do
        sleep $POLL_INTERVAL
        POLL_ELAPSED=$((POLL_ELAPSED + POLL_INTERVAL))
        POLL_MINS=$((POLL_ELAPSED / 60))

        # Check Overseerr
        if [ "$NEED_OVERSEERR_POLL" = true ] && check_overseerr_ready "$PLEX_APPDATA"; then
            log "Overseerr is ready! Configuring Radarr/Sonarr..."
            if configure_overseerr "$MACHINE_IP" "${RADARR_API_KEY:-}" "${SONARR_API_KEY:-}" "$PLEX_APPDATA"; then
                OVERSEERR_CONFIGURED=true
                NEED_OVERSEERR_POLL=false
                log "Overseerr → Radarr + Sonarr configured!"
            fi
        fi

        # Check Plex libraries → Kometa
        if [ "$NEED_KOMETA_POLL" = true ] && check_plex_has_libraries "${PLEX_TOKEN:-}"; then
            if trigger_kometa_first_run "$POLL_PLEX_APPDATA"; then
                KOMETA_TRIGGERED=true
                NEED_KOMETA_POLL=false
            fi
        fi

        # All done?
        if [ "$NEED_OVERSEERR_POLL" = false ] && [ "$NEED_KOMETA_POLL" = false ]; then
            echo ""
            log "All post-deploy automation complete!"
            break
        fi

        # Status
        WAITING_FOR=""
        [ "$NEED_OVERSEERR_POLL" = true ] && WAITING_FOR="Overseerr wizard"
        if [ "$NEED_KOMETA_POLL" = true ]; then
            [ -n "$WAITING_FOR" ] && WAITING_FOR="$WAITING_FOR + "
            WAITING_FOR="${WAITING_FOR}Plex libraries"
        fi
        info "Waiting for ${WAITING_FOR}... (${POLL_MINS}m elapsed)"
    done

    if [ $POLL_ELAPSED -ge $POLL_MAX ]; then
        [ "$NEED_OVERSEERR_POLL" = true ] && warn "Overseerr: timed out. Re-run to configure."
        [ "$NEED_KOMETA_POLL" = true ] && warn "Kometa: timed out. Run manually: docker exec kometa python kometa.py --run"
    fi
fi
