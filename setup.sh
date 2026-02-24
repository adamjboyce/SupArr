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
    eval "$var_name=\"$value\""
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
    info "Detected: Intel iGPU + ${TOTAL_RAM_GB}GB RAM → looks like the Plex box"
elif [ "$TOTAL_RAM_GB" -ge 64 ]; then
    DETECTED_ROLE="arr"
    info "Detected: ${TOTAL_RAM_GB}GB RAM, no iGPU → looks like the *arr box"
else
    DETECTED_ROLE=""
fi

echo ""
echo -e "  ${BOLD}Which machine is this?${NC}"
echo -e "    ${BOLD}1)${NC} Machine 1 — Plex Server (i5-8500 / 32GB / Quick Sync)"
echo -e "    ${BOLD}2)${NC} Machine 2 — *arr Stack  (Xeon E-2334 / 128GB)"
echo ""

if [ "$DETECTED_ROLE" = "plex" ]; then
    default_choice="1"
elif [ "$DETECTED_ROLE" = "arr" ]; then
    default_choice="2"
else
    default_choice=""
fi

echo -en "${CYAN}  Choose [1/2]${default_choice:+ [${default_choice}]}: ${NC}"
read -r MACHINE_CHOICE
MACHINE_CHOICE="${MACHINE_CHOICE:-$default_choice}"

case "$MACHINE_CHOICE" in
    1) ROLE="plex" ;;
    2) ROLE="arr" ;;
    *) err "Invalid choice. Run again and pick 1 or 2."; exit 1 ;;
esac

# ── Load existing .env if present ────────────────────────────────────────────
if [ "$ROLE" = "plex" ]; then
    PROJECT_DIR="$SCRIPT_DIR/machine1-plex"
    INIT_SCRIPT="$SCRIPT_DIR/scripts/init-machine1-plex.sh"
else
    PROJECT_DIR="$SCRIPT_DIR/machine2-arr"
    INIT_SCRIPT="$SCRIPT_DIR/scripts/init-machine2-arr.sh"
fi

ENV_FILE="$PROJECT_DIR/.env"
if [ -f "$ENV_FILE" ]; then
    set -a; source "$ENV_FILE"; set +a
    log "Loaded existing .env — will skip already-answered questions"
fi

# ── Common Questions ─────────────────────────────────────────────────────────
header "Basic Configuration"

ask PUID "User ID (run 'id -u' to check)" "1000"
ask PGID "Group ID (run 'id -g' to check)" "1000"
ask TZ "Timezone" "America/Chicago"

header "NAS Configuration"

ask NAS_IP "NAS IP address (leave blank to skip NFS setup)" ""
if [ -n "$NAS_IP" ]; then
    ask NAS_MEDIA_EXPORT "NAS media export path" "/volume1/media"
    if [ "$ROLE" = "arr" ]; then
        ask NAS_DOWNLOADS_EXPORT "NAS downloads export path" "/volume1/downloads"
    fi
fi

ask MEDIA_ROOT "Local media mount point" "/mnt/media"

if [ "$ROLE" = "plex" ]; then
    ask APPDATA "App data directory (local SSD)" "/opt/media-stack"
else
    ask APPDATA "App data directory (local SSD)" "/opt/arr-stack"
    ask DOWNLOADS_ROOT "Download scratch directory (local NVMe ideal)" "/mnt/downloads"
fi

header "Tailscale — Remote Access"
echo -e "  ${DIM}Tailscale lets you access everything remotely with zero ports exposed.${NC}"
echo -e "  ${DIM}Generate a key at: https://login.tailscale.com/admin/settings/keys${NC}\n"

ask TAILSCALE_AUTH_KEY "Tailscale auth key (or 'skip')" "skip"
ask LOCAL_SUBNET "Local network subnet" "192.168.1.0/24"

# ── Role-Specific Questions ──────────────────────────────────────────────────

if [ "$ROLE" = "plex" ]; then
    # ── Plex Machine ──
    header "Plex Configuration"
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

    ask WATCHTOWER_NOTIFICATION_URL "Notification URL for updates (or 'skip')" "skip"

    # Clean up "skip" values
    [ "$PLEX_CLAIM_TOKEN" = "skip" ] && PLEX_CLAIM_TOKEN=""
    [ "$PLEX_TOKEN" = "skip" ] && PLEX_TOKEN=""
    [ "$TMDB_API_KEY" = "skip" ] && TMDB_API_KEY=""
    [ "$MDBLIST_API_KEY" = "skip" ] && MDBLIST_API_KEY=""
    [ "$TRAKT_CLIENT_ID" = "skip" ] && TRAKT_CLIENT_ID=""
    [ "$TRAKT_CLIENT_SECRET" = "skip" ] && TRAKT_CLIENT_SECRET=""
    [ "$TAILSCALE_AUTH_KEY" = "skip" ] && TAILSCALE_AUTH_KEY=""
    [ "$WATCHTOWER_NOTIFICATION_URL" = "skip" ] && WATCHTOWER_NOTIFICATION_URL=""

else
    # ── *arr Machine ──
    header "NordVPN Configuration"
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
    ask WATCHTOWER_NOTIFICATION_URL "Watchtower notification URL (or 'skip')" "skip"

    [ "$NOTIFIARR_API_KEY" = "skip" ] && NOTIFIARR_API_KEY=""
    [ "$WATCHTOWER_NOTIFICATION_URL" = "skip" ] && WATCHTOWER_NOTIFICATION_URL=""
    [ "$TAILSCALE_AUTH_KEY" = "skip" ] && TAILSCALE_AUTH_KEY=""

    # API keys — init script populates these automatically
    RADARR_API_KEY="${RADARR_API_KEY:-}"
    SONARR_API_KEY="${SONARR_API_KEY:-}"
    LIDARR_API_KEY="${LIDARR_API_KEY:-}"
    PROWLARR_API_KEY="${PROWLARR_API_KEY:-}"
    BAZARR_API_KEY="${BAZARR_API_KEY:-}"
    READARR_API_KEY="${READARR_API_KEY:-}"
    WHISPARR_API_KEY="${WHISPARR_API_KEY:-}"
    SABNZBD_API_KEY="${SABNZBD_API_KEY:-}"
fi

# ── Write .env ───────────────────────────────────────────────────────────────
header "Writing Configuration"

if [ "$ROLE" = "plex" ]; then
    cat > "$ENV_FILE" <<ENVEOF
# =============================================================================
# Machine 1: Plex Server — Generated by SupArr setup.sh
# =============================================================================
PUID=${PUID}
PGID=${PGID}
TZ=${TZ}
MEDIA_ROOT=${MEDIA_ROOT}
APPDATA=${APPDATA}
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
else
    cat > "$ENV_FILE" <<ENVEOF
# =============================================================================
# Machine 2: *arr Stack — Generated by SupArr setup.sh
# =============================================================================
PUID=${PUID}
PGID=${PGID}
TZ=${TZ}
MEDIA_ROOT=${MEDIA_ROOT}
DOWNLOADS_ROOT=${DOWNLOADS_ROOT}
APPDATA=${APPDATA}
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
fi

chmod 600 "$ENV_FILE"
log "Configuration written to $ENV_FILE"

# ── Confirm and Launch ───────────────────────────────────────────────────────
header "Ready to Deploy"

if [ "$ROLE" = "plex" ]; then
    echo -e "  Machine:    ${BOLD}Plex Server${NC}"
else
    echo -e "  Machine:    ${BOLD}*arr Stack${NC}"
fi
echo -e "  App data:   ${APPDATA}"
echo -e "  Media:      ${MEDIA_ROOT}"
[ -n "$NAS_IP" ] && echo -e "  NAS:        ${NAS_IP}"
echo ""

if ! ask_yn "Deploy now?" "y"; then
    log "Config saved to $ENV_FILE — run 'sudo $INIT_SCRIPT' when ready."
    exit 0
fi

# ── Run Init Script ──────────────────────────────────────────────────────────
header "Deploying..."

chmod +x "$INIT_SCRIPT"
bash "$INIT_SCRIPT"

# ── Post-Init Note ────────────────────────────────────────────────────────────
# All post-deploy API configuration (Readarr, Whisparr, Bazarr, qBit password,
# download client password sync) is now handled by the init scripts directly.
# No additional setup.sh work needed beyond running the init script.

# ── Final Report ─────────────────────────────────────────────────────────────
header "SupArr Deployment Complete"

echo ""
if [ "$ROLE" = "plex" ]; then
    echo -e "  ${GREEN}${BOLD}Machine 1 (Plex Server) is live.${NC}"
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
    echo -e "    ${DIM}Sign in with Plex, connect Radarr + Sonarr on Machine 2${NC}"
    echo ""
    echo -e "    ${BOLD}Kometa${NC}  →  First run when ready:"
    echo -e "    ${DIM}docker exec kometa python kometa.py --run${NC}"
else
    echo -e "  ${GREEN}${BOLD}Machine 2 (*arr Stack) is live.${NC}"
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
