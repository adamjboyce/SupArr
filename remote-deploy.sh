#!/usr/bin/env bash
# =============================================================================
# SupArr — Remote Deploy
# =============================================================================
# Run from a desktop (WSL2/Linux/macOS). Collects all config interactively,
# then deploys to both machines in parallel over SSH.
#
# Usage:
#   chmod +x remote-deploy.sh
#   ./remote-deploy.sh
#
# Prerequisites on desktop:
#   ssh, sshpass, ssh-keygen, rsync
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

# Prompt with default value
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

# ── Trakt Device Auth Flow ────────────────────────────────────────────────
trakt_device_auth() {
    local client_id="$1" client_secret="$2"

    info "Starting Trakt device authorization..."
    local device_response
    device_response=$(curl -sf -X POST "https://api.trakt.tv/oauth/device/code" \
        -H "Content-Type: application/json" \
        -d "{\"client_id\": \"${client_id}\"}")

    if [ -z "$device_response" ]; then
        warn "Could not reach Trakt API — skipping device auth"
        return 1
    fi

    local user_code device_code verification_url expires_in interval
    user_code=$(echo "$device_response" | jq -r '.user_code')
    device_code=$(echo "$device_response" | jq -r '.device_code')
    verification_url=$(echo "$device_response" | jq -r '.verification_url')
    expires_in=$(echo "$device_response" | jq -r '.expires_in')
    interval=$(echo "$device_response" | jq -r '.interval')

    echo ""
    echo "  ┌──────────────────────────────────────────────┐"
    echo "  │  Go to: ${verification_url}"
    echo "  │  Enter code: ${user_code}"
    echo "  │  Expires in: $((expires_in / 60)) minutes"
    echo "  └──────────────────────────────────────────────┘"
    echo ""

    local elapsed=0
    while [ "$elapsed" -lt "$expires_in" ]; do
        sleep "$interval"
        elapsed=$((elapsed + interval))

        local token_response
        token_response=$(curl -sf -X POST "https://api.trakt.tv/oauth/device/token" \
            -H "Content-Type: application/json" \
            -d "{\"code\": \"${device_code}\", \"client_id\": \"${client_id}\", \"client_secret\": \"${client_secret}\"}" 2>/dev/null || echo "")

        if echo "$token_response" | jq -e '.access_token' &>/dev/null; then
            TRAKT_ACCESS_TOKEN=$(echo "$token_response" | jq -r '.access_token')
            TRAKT_REFRESH_TOKEN=$(echo "$token_response" | jq -r '.refresh_token')
            TRAKT_EXPIRES=$(echo "$token_response" | jq -r '.expires_in')
            TRAKT_CREATED_AT=$(echo "$token_response" | jq -r '.created_at')
            log "Trakt authorized successfully!"
            return 0
        fi
    done

    warn "Trakt authorization timed out — you can set tokens manually later"
    return 1
}

REMOTE_PROJECT_PATH="/opt/suparr"
SSH_KEY="$HOME/.ssh/suparr_deploy_key"

# ===========================================================================
header "SupArr — Remote Deploy"
# ===========================================================================

echo -e "  ${BOLD}Deploy from your desktop via SSH.${NC}"
echo -e "  ${DIM}All prompts happen here. No interactive SSH sessions.${NC}\n"

echo -e "  ${BOLD}Deploy mode?${NC}"
echo -e "    ${BOLD}1)${NC} Two Machines — Spyglass (Plex) + Privateer (*arr)"
echo -e "    ${BOLD}2)${NC} Single Machine — everything on one box"
echo ""
echo -en "${CYAN}  Choose [1/2] [1]: ${NC}"
read -r DEPLOY_MODE
DEPLOY_MODE="${DEPLOY_MODE:-1}"

case "$DEPLOY_MODE" in
    1) SINGLE_MACHINE=false ;;
    2) SINGLE_MACHINE=true ;;
    *) err "Invalid choice."; exit 1 ;;
esac

# ===========================================================================
header "Phase 0: Prerequisites"
# ===========================================================================

MISSING=""
for cmd in ssh sshpass ssh-keygen rsync; do
    if ! command -v "$cmd" &>/dev/null; then
        MISSING="$MISSING $cmd"
    fi
done

if [ -n "$MISSING" ]; then
    err "Missing required tools:${MISSING}"
    echo ""
    echo -e "  Install them first:"
    echo -e "    ${DIM}Debian/Ubuntu:${NC} sudo apt install openssh-client sshpass rsync"
    echo -e "    ${DIM}macOS:${NC}         brew install sshpass rsync"
    echo ""
    exit 1
fi

log "All prerequisites found"

# ===========================================================================
header "Phase 1: Target Machines"
# ===========================================================================

if [ "$SINGLE_MACHINE" = true ]; then
    echo -e "  ${DIM}Enter the IP and SSH credentials for your machine.${NC}\n"

    ask PLEX_IP_ADDR "Target machine IP" ""
    [ -z "$PLEX_IP_ADDR" ] && { err "Machine IP is required"; exit 1; }
    validate_ip "$PLEX_IP_ADDR" || { err "Invalid IP: $PLEX_IP_ADDR"; exit 1; }
    ARR_IP_ADDR="$PLEX_IP_ADDR"
else
    echo -e "  ${DIM}Enter the IPs and SSH credentials for both machines.${NC}"
    echo -e "  ${DIM}Same SSH user/password for both? Just enter once.${NC}\n"

    ask PLEX_IP_ADDR "Spyglass (Plex) machine IP" ""
    [ -z "$PLEX_IP_ADDR" ] && { err "Spyglass IP is required"; exit 1; }
    validate_ip "$PLEX_IP_ADDR" || { err "Invalid Spyglass IP: $PLEX_IP_ADDR"; exit 1; }

    ask ARR_IP_ADDR "Privateer (*arr) machine IP" ""
    [ -z "$ARR_IP_ADDR" ] && { err "Privateer IP is required"; exit 1; }
    validate_ip "$ARR_IP_ADDR" || { err "Invalid Privateer IP: $ARR_IP_ADDR"; exit 1; }
fi

ask NAS_IP "NAS IP (for NFS mounts, or blank to skip)" ""
if [ -n "$NAS_IP" ] && ! validate_ip "$NAS_IP"; then
    err "Invalid NAS IP: $NAS_IP"; exit 1
fi

echo ""
ask SSH_USER "SSH username" "root"
ask SSH_PASS "SSH password" "" "secret"

if [ "$SINGLE_MACHINE" = true ]; then
    log "Target: ${PLEX_IP_ADDR} (single machine)"
else
    log "Targets: Spyglass=${PLEX_IP_ADDR}  Privateer=${ARR_IP_ADDR}"
fi

# ===========================================================================
header "Phase 2: Configuration"
# ===========================================================================

# ── Common ──
echo -e "  ${BOLD}Common settings (both machines):${NC}\n"

ask PUID "User ID" "1000"
ask PGID "Group ID" "1000"
ask TZ "Timezone" "America/Chicago"

if [ -n "$NAS_IP" ]; then
    ask NAS_MEDIA_EXPORT "NAS media export path" "/volume1/media"
    ask NAS_DOWNLOADS_EXPORT "NAS downloads export path" "/volume1/downloads"
else
    NAS_MEDIA_EXPORT=""
    NAS_DOWNLOADS_EXPORT=""
fi

ask LOCAL_SUBNET "Local network subnet" "192.168.1.0/24"

echo ""
echo -e "  ${DIM}Tailscale — remote access without port forwarding${NC}"
echo -e "  ${DIM}Generate keys at: https://login.tailscale.com/admin/settings/keys${NC}\n"

ask TAILSCALE_AUTH_KEY "Tailscale auth key (or 'skip')" "skip"
[ "$TAILSCALE_AUTH_KEY" = "skip" ] && TAILSCALE_AUTH_KEY=""

# ── Plex-specific ──
echo ""
echo -e "  ${BOLD}Spyglass (Plex) settings:${NC}\n"

ask PLEX_MEDIA_ROOT "Spyglass media mount point" "/mnt/media"
validate_path "$PLEX_MEDIA_ROOT" || { err "Spyglass media root must be an absolute path"; exit 1; }
ask PLEX_APPDATA "Spyglass app data directory" "/opt/media-stack"
validate_path "$PLEX_APPDATA" || { err "Spyglass app data must be an absolute path"; exit 1; }

echo -e "\n  ${DIM}Get a claim token at: https://plex.tv/claim (valid ~4 minutes)${NC}\n"
ask PLEX_CLAIM_TOKEN "Plex claim token (or 'skip')" "skip"
[ "$PLEX_CLAIM_TOKEN" = "skip" ] && PLEX_CLAIM_TOKEN=""

echo -e "\n  ${DIM}Plex token for Kometa integration.${NC}"
echo -e "  ${DIM}Find it: https://support.plex.tv/articles/204059436${NC}\n"
ask PLEX_TOKEN "Plex token (or 'skip')" "skip"
[ "$PLEX_TOKEN" = "skip" ] && PLEX_TOKEN=""

ask PLEX_IP_FOR_KOMETA "Plex server IP for Kometa config" "$PLEX_IP_ADDR"

echo -e "\n  ${BOLD}Kometa — Library Aesthetics${NC}"
echo -e "  ${DIM}Free API keys. Skip any you don't have yet.${NC}\n"

ask TMDB_API_KEY "TMDb API key" "skip"
ask MDBLIST_API_KEY "MDBList API key" "skip"
ask TRAKT_CLIENT_ID "Trakt client ID" "skip"
ask TRAKT_CLIENT_SECRET "Trakt client secret" "skip"

[ "$TMDB_API_KEY" = "skip" ] && TMDB_API_KEY=""
[ "$MDBLIST_API_KEY" = "skip" ] && MDBLIST_API_KEY=""
[ "$TRAKT_CLIENT_ID" = "skip" ] && TRAKT_CLIENT_ID=""
[ "$TRAKT_CLIENT_SECRET" = "skip" ] && TRAKT_CLIENT_SECRET=""

# ── Trakt Device Auth ────────────────────────────────────────────────────
TRAKT_ACCESS_TOKEN="${TRAKT_ACCESS_TOKEN:-}"
TRAKT_REFRESH_TOKEN="${TRAKT_REFRESH_TOKEN:-}"
TRAKT_EXPIRES="${TRAKT_EXPIRES:-}"
TRAKT_CREATED_AT="${TRAKT_CREATED_AT:-}"

if [ -n "${TRAKT_CLIENT_ID:-}" ] && [ -n "${TRAKT_CLIENT_SECRET:-}" ] && [ -z "${TRAKT_ACCESS_TOKEN:-}" ]; then
    if command -v jq &>/dev/null; then
        trakt_device_auth "$TRAKT_CLIENT_ID" "$TRAKT_CLIENT_SECRET" || true
    else
        warn "jq not installed — skipping Trakt device auth (set tokens manually)"
    fi
fi

# ── Arr-specific ──
echo ""
echo -e "  ${BOLD}Privateer (*arr) settings:${NC}\n"

ask ARR_MEDIA_ROOT "Privateer media mount point" "/mnt/media"
validate_path "$ARR_MEDIA_ROOT" || { err "Privateer media root must be an absolute path"; exit 1; }
ask ARR_DOWNLOADS_ROOT "Privateer download scratch directory" "/mnt/downloads"
validate_path "$ARR_DOWNLOADS_ROOT" || { err "Privateer downloads root must be an absolute path"; exit 1; }
ask ARR_APPDATA "Privateer app data directory" "/opt/arr-stack"
validate_path "$ARR_APPDATA" || { err "Privateer app data must be an absolute path"; exit 1; }

echo ""
echo -e "  ${BOLD}NordVPN (all downloads tunnel through this):${NC}\n"

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
    NORD_USER=""
    NORD_PASS=""
else
    NORD_VPN_TYPE="openvpn"
    echo -e "\n  ${DIM}Nord service credentials (NOT your login).${NC}"
    echo -e "  ${DIM}Find at: https://my.nordaccount.com/dashboard/nordvpn/manual-configuration/${NC}\n"
    ask NORD_USER "Nord service username" ""
    ask NORD_PASS "Nord service password" "" "secret"
    NORD_WIREGUARD_KEY=""
fi

ask NORD_COUNTRY "VPN server country" "United States"
ask NORD_CITY "VPN server city (blank for auto)" ""

echo ""
echo -e "  ${BOLD}qBittorrent${NC}\n"
ask QBIT_PASSWORD "qBittorrent web UI password" "SupArr2026!" "secret"

echo ""
ask NOTIFIARR_API_KEY "Notifiarr API key (or 'skip')" "skip"
[ "$NOTIFIARR_API_KEY" = "skip" ] && NOTIFIARR_API_KEY=""

echo ""
echo -e "  ${BOLD}Immich — Phone Photo Backup${NC}"
echo -e "  ${DIM}Self-hosted Google Photos. ML on this machine, photos on NAS.${NC}\n"
ask IMMICH_DB_PASSWORD "Immich database password" "$(openssl rand -hex 12)" "secret"

echo ""
echo -e "  ${BOLD}Discord Notifications${NC}"
echo -e "  ${DIM}Get webhook URL: Server Settings → Integrations → Webhooks${NC}\n"
ask DISCORD_WEBHOOK_URL "Discord webhook URL (or 'skip')" "skip"
[ "$DISCORD_WEBHOOK_URL" = "skip" ] && DISCORD_WEBHOOK_URL=""

# Derive Watchtower shoutrrr URL from Discord webhook
# https://discord.com/api/webhooks/ID/TOKEN → discord://TOKEN@ID
WATCHTOWER_NOTIFICATION_URL=""
if [ -n "$DISCORD_WEBHOOK_URL" ]; then
    WEBHOOK_PATH="${DISCORD_WEBHOOK_URL##*/webhooks/}"
    WEBHOOK_ID="${WEBHOOK_PATH%%/*}"
    WEBHOOK_TOKEN="${WEBHOOK_PATH##*/}"
    if [ -n "$WEBHOOK_ID" ] && [ -n "$WEBHOOK_TOKEN" ]; then
        WATCHTOWER_NOTIFICATION_URL="discord://${WEBHOOK_TOKEN}@${WEBHOOK_ID}"
    fi
fi

# ===========================================================================
header "Phase 3: SSH Key Setup"
# ===========================================================================

if [ ! -f "$SSH_KEY" ]; then
    info "Generating SSH key pair..."
    ssh-keygen -t ed25519 -f "$SSH_KEY" -N "" -C "suparr-deploy" -q
    log "SSH key generated: $SSH_KEY"
else
    log "SSH key already exists: $SSH_KEY"
fi

SSH_OPTS="-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR"

push_key() {
    local host="$1" label="$2"
    info "Pushing SSH key to ${label} (${host})..."
    # shellcheck disable=SC2086
    sshpass -p "$SSH_PASS" ssh-copy-id $SSH_OPTS -i "$SSH_KEY" "${SSH_USER}@${host}" 2>/dev/null && \
        log "SSH key deployed to ${label}" || \
        warn "Could not push key to ${label} — will use password fallback"
}

push_key "$PLEX_IP_ADDR" "Spyglass"
if [ "$SINGLE_MACHINE" = false ]; then
    push_key "$ARR_IP_ADDR" "Privateer"
fi

# From now on, use key auth
SSH_CMD="ssh $SSH_OPTS -i $SSH_KEY"
RSYNC_SSH="ssh $SSH_OPTS -i $SSH_KEY"

# Test connectivity
TARGETS=("$PLEX_IP_ADDR")
TARGET_LABELS=("Spyglass")
if [ "$SINGLE_MACHINE" = false ]; then
    TARGETS+=("$ARR_IP_ADDR")
    TARGET_LABELS+=("Privateer")
fi

for i in "${!TARGETS[@]}"; do
    # shellcheck disable=SC2086
    if $SSH_CMD "${SSH_USER}@${TARGETS[$i]}" "echo ok" &>/dev/null; then
        log "SSH connection verified: ${TARGET_LABELS[$i]}"
    else
        err "Cannot connect to ${TARGET_LABELS[$i]} (${TARGETS[$i]}) — check credentials and try again"
        exit 1
    fi
done

# ===========================================================================
header "Phase 4: Generate .env Files"
# ===========================================================================

PLEX_ENV_FILE=$(mktemp)
ARR_ENV_FILE=$(mktemp)
trap 'rm -f "$PLEX_ENV_FILE" "$ARR_ENV_FILE"' EXIT

cat > "$PLEX_ENV_FILE" <<ENVEOF
# =============================================================================
# Spyglass (Plex Server) — Generated by SupArr remote-deploy.sh
# =============================================================================
PUID=${PUID}
PGID=${PGID}
TZ=${TZ}
MEDIA_ROOT=${PLEX_MEDIA_ROOT}
APPDATA=${PLEX_APPDATA}
NAS_IP=${NAS_IP}
NAS_MEDIA_EXPORT=${NAS_MEDIA_EXPORT}
PLEX_CLAIM_TOKEN=${PLEX_CLAIM_TOKEN}
PLEX_TOKEN=${PLEX_TOKEN}
PLEX_IP=${PLEX_IP_FOR_KOMETA}
TAILSCALE_AUTH_KEY=${TAILSCALE_AUTH_KEY}
LOCAL_SUBNET=${LOCAL_SUBNET}
TMDB_API_KEY=${TMDB_API_KEY}
MDBLIST_API_KEY=${MDBLIST_API_KEY}
TRAKT_CLIENT_ID=${TRAKT_CLIENT_ID}
TRAKT_CLIENT_SECRET=${TRAKT_CLIENT_SECRET}
TRAKT_ACCESS_TOKEN=${TRAKT_ACCESS_TOKEN}
TRAKT_REFRESH_TOKEN=${TRAKT_REFRESH_TOKEN}
TRAKT_EXPIRES=${TRAKT_EXPIRES}
TRAKT_CREATED_AT=${TRAKT_CREATED_AT}
DISCORD_WEBHOOK_URL=${DISCORD_WEBHOOK_URL}
WATCHTOWER_NOTIFICATION_URL=${WATCHTOWER_NOTIFICATION_URL}
ENVEOF

cat > "$ARR_ENV_FILE" <<ENVEOF
# =============================================================================
# Privateer (*arr Stack) — Generated by SupArr remote-deploy.sh
# =============================================================================
PUID=${PUID}
PGID=${PGID}
TZ=${TZ}
MEDIA_ROOT=${ARR_MEDIA_ROOT}
DOWNLOADS_ROOT=${ARR_DOWNLOADS_ROOT}
APPDATA=${ARR_APPDATA}
NAS_IP=${NAS_IP}
NAS_MEDIA_EXPORT=${NAS_MEDIA_EXPORT}
NAS_DOWNLOADS_EXPORT=${NAS_DOWNLOADS_EXPORT}
NORD_VPN_TYPE=${NORD_VPN_TYPE}
NORD_USER=${NORD_USER}
NORD_PASS=${NORD_PASS}
NORD_WIREGUARD_KEY=${NORD_WIREGUARD_KEY}
NORD_COUNTRY=${NORD_COUNTRY}
NORD_CITY=${NORD_CITY}
LOCAL_SUBNET=${LOCAL_SUBNET}
TAILSCALE_AUTH_KEY=${TAILSCALE_AUTH_KEY}
QBIT_PASSWORD=${QBIT_PASSWORD}
RADARR_API_KEY=
SONARR_API_KEY=
LIDARR_API_KEY=
PROWLARR_API_KEY=
BAZARR_API_KEY=
READARR_API_KEY=
WHISPARR_API_KEY=
SABNZBD_API_KEY=
NOTIFIARR_API_KEY=${NOTIFIARR_API_KEY}
TRAKT_ACCESS_TOKEN=${TRAKT_ACCESS_TOKEN}
PLEX_TOKEN=${PLEX_TOKEN}
PLEX_IP=${PLEX_IP_FOR_KOMETA}
TMDB_API_KEY=${TMDB_API_KEY}
IMMICH_DB_PASSWORD=${IMMICH_DB_PASSWORD:-}
DISCORD_WEBHOOK_URL=${DISCORD_WEBHOOK_URL}
WATCHTOWER_NOTIFICATION_URL=${WATCHTOWER_NOTIFICATION_URL}
ENVEOF

log "Spyglass .env generated"
log "Privateer .env generated"

# ===========================================================================
header "Phase 5: Sync Project Files"
# ===========================================================================

sync_to_target() {
    local host="$1" label="$2"
    info "Syncing project files to ${label} (${host}:${REMOTE_PROJECT_PATH})..."

    # Create remote directory
    # shellcheck disable=SC2086
    $SSH_CMD "${SSH_USER}@${host}" "mkdir -p ${REMOTE_PROJECT_PATH}"

    # Rsync project files
    rsync -az --delete \
        -e "$RSYNC_SSH" \
        --exclude '.env' \
        --exclude '*.swp' \
        --exclude '.git' \
        "$SCRIPT_DIR/" "${SSH_USER}@${host}:${REMOTE_PROJECT_PATH}/"

    # Copy both .env files
    rsync -az -e "$RSYNC_SSH" "$PLEX_ENV_FILE" "${SSH_USER}@${host}:${REMOTE_PROJECT_PATH}/machine1-plex/.env"
    rsync -az -e "$RSYNC_SSH" "$ARR_ENV_FILE" "${SSH_USER}@${host}:${REMOTE_PROJECT_PATH}/machine2-arr/.env"

    # Set permissions
    # shellcheck disable=SC2086
    $SSH_CMD "${SSH_USER}@${host}" "chmod +x ${REMOTE_PROJECT_PATH}/scripts/*.sh && chmod 600 ${REMOTE_PROJECT_PATH}/machine*-*/.env 2>/dev/null || true"

    log "${label}: files synced"
}

if [ "$SINGLE_MACHINE" = true ]; then
    sync_to_target "$PLEX_IP_ADDR" "Target"
else
    sync_to_target "$PLEX_IP_ADDR" "Spyglass"
    sync_to_target "$ARR_IP_ADDR" "Privateer"
fi

# ===========================================================================
header "Phase 6: Deploy"
# ===========================================================================

# Test if we can sudo without password, or if we're root
can_sudo() {
    local host="$1"
    # shellcheck disable=SC2086
    $SSH_CMD "${SSH_USER}@${host}" "sudo -n true 2>/dev/null && echo yes || echo no"
}

run_init() {
    local host="$1" label="$2" script="$3"
    local sudo_prefix=""

    if [ "$SSH_USER" != "root" ]; then
        local can=$(can_sudo "$host")
        if [ "$can" = "yes" ]; then
            sudo_prefix="sudo"
        else
            warn "${label}: passwordless sudo not available. Trying with password..."
            sudo_prefix="sudo"
        fi
    fi

    # shellcheck disable=SC2086
    $SSH_CMD "${SSH_USER}@${host}" "${sudo_prefix} bash ${REMOTE_PROJECT_PATH}/scripts/${script}" 2>&1
}

# ── Overseerr readiness check (remote, quiet) ─────────────────────────────────
check_overseerr_ready_remote() {
    local plex_host="$1" plex_appdata="$2"
    local os_key
    # shellcheck disable=SC2086
    os_key=$($SSH_CMD "${SSH_USER}@${plex_host}" \
        "jq -r '.main.apiKey // empty' '${plex_appdata}/overseerr/config/settings.json' 2>/dev/null" || echo "")
    [ -z "$os_key" ] && return 1
    curl -sf -o /dev/null "http://${plex_host}:5055/api/v1/settings/public" 2>/dev/null || return 1
    local initialized
    initialized=$(curl -sf "http://${plex_host}:5055/api/v1/settings/public" 2>/dev/null | jq -r '.initialized // false' 2>/dev/null || echo "false")
    [ "$initialized" = "true" ]
}

# ── Plex library check (remote, quiet) ─────────────────────────────────────────
check_plex_has_libraries_remote() {
    local plex_host="$1" plex_token="${2:-}"
    local url="http://${plex_host}:32400/library/sections"
    [ -n "$plex_token" ] && url="${url}?X-Plex-Token=${plex_token}"
    local count
    count=$(curl -sf -H "Accept: application/json" "$url" 2>/dev/null | jq '.MediaContainer.size // 0' 2>/dev/null || echo "0")
    [ "${count:-0}" -gt 0 ]
}

# ── Kometa first-run trigger (remote) ─────────────────────────────────────────
trigger_kometa_first_run_remote() {
    local plex_host="$1" plex_appdata="$2"
    # shellcheck disable=SC2086
    local result
    result=$($SSH_CMD "${SSH_USER}@${plex_host}" "
        if [ -f '${plex_appdata}/kometa/.first-run-triggered' ]; then
            echo 'already_done'
        elif ! docker ps --format '{{.Names}}' | grep -q '^kometa\$'; then
            echo 'not_running'
        else
            docker exec -d kometa python kometa.py --run
            touch '${plex_appdata}/kometa/.first-run-triggered'
            echo 'triggered'
        fi
    " 2>/dev/null || echo "failed")
    case "$result" in
        already_done) log "Kometa first run already triggered previously"; return 0 ;;
        triggered)
            log "Kometa first run started in background"
            echo -e "  ${DIM}Takes hours. Check: ssh ${SSH_USER}@${plex_host} docker logs -f kometa${NC}"
            return 0 ;;
        not_running) warn "Kometa container not running"; return 1 ;;
        *) warn "Could not trigger Kometa"; return 1 ;;
    esac
}

# ── Overseerr auto-config (remote) ────────────────────────────────────────────
configure_overseerr_remote() {
    local plex_host="$1" arr_host="$2" radarr_key="$3" sonarr_key="$4" plex_appdata="$5"

    if [ -z "$radarr_key" ] && [ -z "$sonarr_key" ]; then
        warn "Overseerr: no *arr API keys discovered — skipping auto-config"
        return 1
    fi

    info "Configuring Overseerr → Radarr/Sonarr..."

    # Read Overseerr API key from target via SSH
    local os_key
    # shellcheck disable=SC2086
    os_key=$($SSH_CMD "${SSH_USER}@${plex_host}" \
        "jq -r '.main.apiKey // empty' '${plex_appdata}/overseerr/config/settings.json' 2>/dev/null" || echo "")
    if [ -z "$os_key" ]; then
        warn "Overseerr not initialized — complete setup wizard at http://${plex_host}:5055 first"
        return 1
    fi

    local os_url="http://${plex_host}:5055/api/v1"

    # Wait for API
    local ready=false
    for _ in $(seq 1 10); do
        if curl -sf -o /dev/null "${os_url}/settings/public" 2>/dev/null; then
            ready=true; break
        fi
        sleep 2
    done
    if [ "$ready" = false ]; then
        warn "Overseerr API not responding at http://${plex_host}:5055"
        return 1
    fi

    # Check if initialized
    local initialized
    initialized=$(curl -sf "${os_url}/settings/public" 2>/dev/null | jq -r '.initialized // false' 2>/dev/null || echo "false")
    if [ "$initialized" != "true" ]; then
        warn "Overseerr not initialized — complete setup wizard first"
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

    # --- Plex Watchlist sync ---
    curl -sf -X POST "${os_url}/settings/plex" \
        -H "X-Api-Key: ${os_key}" \
        -H "Content-Type: application/json" \
        -d '{"watchlistSync": true}' > /dev/null 2>&1 && \
        log "  Overseerr: Plex Watchlist sync enabled" || true
}

PLEX_LOG=$(mktemp)
ARR_LOG=$(mktemp)
trap 'rm -f "$PLEX_ENV_FILE" "$ARR_ENV_FILE" "$PLEX_LOG" "$ARR_LOG"' EXIT

if [ "$SINGLE_MACHINE" = true ]; then
    echo -e "  ${BOLD}Running both init scripts sequentially on ${PLEX_IP_ADDR}...${NC}"
    echo -e "  ${DIM}This takes 5-10 minutes. Streaming output below.${NC}\n"

    echo -e "${BOLD}━━━ SPYGLASS (Plex) ━━━${NC}"
    run_init "$PLEX_IP_ADDR" "Spyglass" "init-machine1-plex.sh" 2>&1 | while IFS= read -r line; do
        echo -e "${BOLD}[SPYGLASS]${NC} $line"
    done
    PLEX_RESULT=${PIPESTATUS[0]}

    echo ""
    echo -e "${BOLD}━━━ PRIVATEER (*arr) ━━━${NC}"
    run_init "$PLEX_IP_ADDR" "Privateer" "init-machine2-arr.sh" 2>&1 | while IFS= read -r line; do
        echo -e "${BOLD}[PRIVATEER]${NC} $line"
    done
    ARR_RESULT=${PIPESTATUS[0]}
else
    echo -e "  ${BOLD}Launching both init scripts in parallel...${NC}"
    echo -e "  ${DIM}This takes 2-5 minutes per machine. Streaming output below.${NC}\n"

    # Launch both in background
    run_init "$PLEX_IP_ADDR" "Spyglass" "init-machine1-plex.sh" > "$PLEX_LOG" 2>&1 &
    PLEX_PID=$!

    run_init "$ARR_IP_ADDR" "Privateer" "init-machine2-arr.sh" > "$ARR_LOG" 2>&1 &
    ARR_PID=$!

    # ===========================================================================
    header "Phase 7: Live Output"
    # ===========================================================================

    # Wait and dump labeled output
    (
        wait "$PLEX_PID" 2>/dev/null
        PLEX_EXIT=$?
        echo ""
        echo -e "${BOLD}━━━ SPYGLASS OUTPUT ━━━${NC}"
        if [ -f "$PLEX_LOG" ]; then
            while IFS= read -r line; do
                echo -e "${BOLD}[SPYGLASS]${NC} $line"
            done < "$PLEX_LOG"
        fi
        if [ "$PLEX_EXIT" -eq 0 ]; then
            echo -e "${BOLD}[SPYGLASS]${NC} ${GREEN}Deploy complete ✓${NC}"
        else
            echo -e "${BOLD}[SPYGLASS]${NC} ${RED}Deploy failed (exit $PLEX_EXIT)${NC}"
        fi
    ) &
    PLEX_OUTPUT_PID=$!

    (
        wait "$ARR_PID" 2>/dev/null
        ARR_EXIT=$?
        echo ""
        echo -e "${BOLD}━━━ PRIVATEER OUTPUT ━━━${NC}"
        if [ -f "$ARR_LOG" ]; then
            while IFS= read -r line; do
                echo -e "${BOLD}[PRIVATEER]${NC} $line"
            done < "$ARR_LOG"
        fi
        if [ "$ARR_EXIT" -eq 0 ]; then
            echo -e "${BOLD}[PRIVATEER]${NC} ${GREEN}Deploy complete ✓${NC}"
        else
            echo -e "${BOLD}[PRIVATEER]${NC} ${RED}Deploy failed (exit $ARR_EXIT)${NC}"
        fi
    ) &
    ARR_OUTPUT_PID=$!

    # Wait for both output processes
    wait "$PLEX_OUTPUT_PID" 2>/dev/null || true
    wait "$ARR_OUTPUT_PID" 2>/dev/null || true

    # Capture exit codes
    wait "$PLEX_PID" 2>/dev/null
    PLEX_RESULT=$?
    wait "$ARR_PID" 2>/dev/null
    ARR_RESULT=$?
fi

# ===========================================================================
header "Phase 8: Post-Deploy Summary"
# ===========================================================================

# Try to fetch API keys from arr machine's .env for display
ARR_API_KEYS=""
# shellcheck disable=SC2086
ARR_API_KEYS=$($SSH_CMD "${SSH_USER}@${ARR_IP_ADDR}" "cat ${REMOTE_PROJECT_PATH}/machine2-arr/.env 2>/dev/null" || echo "")

# Extract API keys for Overseerr config and summary display
RADARR_KEY=""
SONARR_KEY=""
if [ -n "$ARR_API_KEYS" ]; then
    RADARR_KEY=$(echo "$ARR_API_KEYS" | grep '^RADARR_API_KEY=' | cut -d= -f2)
    SONARR_KEY=$(echo "$ARR_API_KEYS" | grep '^SONARR_API_KEY=' | cut -d= -f2)
fi

# Overseerr auto-config — wire up Radarr/Sonarr connections
OVERSEERR_CONFIGURED=false
if [ "$PLEX_RESULT" -eq 0 ] && [ "$ARR_RESULT" -eq 0 ]; then
    if command -v jq &>/dev/null && command -v curl &>/dev/null; then
        if [ -n "$RADARR_KEY" ] || [ -n "$SONARR_KEY" ]; then
            header "Overseerr → Radarr/Sonarr"
            configure_overseerr_remote "$PLEX_IP_ADDR" "$ARR_IP_ADDR" "$RADARR_KEY" "$SONARR_KEY" "$PLEX_APPDATA" && \
                OVERSEERR_CONFIGURED=true
        fi
    else
        warn "Overseerr auto-config: install curl + jq on desktop to enable"
    fi
fi

# Kometa first run trigger
KOMETA_TRIGGERED=false
if [ "$PLEX_RESULT" -eq 0 ]; then
    if command -v jq &>/dev/null && command -v curl &>/dev/null; then
        if check_plex_has_libraries_remote "$PLEX_IP_ADDR" "${PLEX_TOKEN:-}"; then
            trigger_kometa_first_run_remote "$PLEX_IP_ADDR" "$PLEX_APPDATA" && KOMETA_TRIGGERED=true
        fi
    fi
fi

echo ""
if [ "$PLEX_RESULT" -eq 0 ] && [ "$ARR_RESULT" -eq 0 ]; then
    if [ "$SINGLE_MACHINE" = true ]; then
        log "Both stacks deployed successfully on single machine!"
    else
        log "Both machines deployed successfully!"
    fi
elif [ "$PLEX_RESULT" -eq 0 ]; then
    log "Spyglass (Plex) deployed successfully"
    err "Privateer (*arr) deploy failed — check output above"
elif [ "$ARR_RESULT" -eq 0 ]; then
    err "Spyglass (Plex) deploy failed — check output above"
    log "Privateer (*arr) deployed successfully"
else
    err "Both deploys failed — check output above"
fi

echo ""
echo -e "  ${BOLD}═══ Service URLs ═══${NC}"
echo ""
echo -e "  ${BOLD}Spyglass — Plex (${PLEX_IP_ADDR}):${NC}"
echo -e "    Plex        → http://${PLEX_IP_ADDR}:32400/web"
echo -e "    Tdarr       → http://${PLEX_IP_ADDR}:8265"
echo -e "    Overseerr   → http://${PLEX_IP_ADDR}:5055"
echo -e "    Tautulli    → http://${PLEX_IP_ADDR}:8181"
echo -e "    Uptime Kuma → http://${PLEX_IP_ADDR}:3001"
echo -e "    Homepage    → http://${PLEX_IP_ADDR}:3100"
echo ""
echo -e "  ${BOLD}Privateer — *arr (${ARR_IP_ADDR}):${NC}"
echo -e "    Radarr      → http://${ARR_IP_ADDR}:7878"
echo -e "    Sonarr      → http://${ARR_IP_ADDR}:8989"
echo -e "    Lidarr      → http://${ARR_IP_ADDR}:8686"
echo -e "    Readarr     → http://${ARR_IP_ADDR}:8787"
echo -e "    Whisparr    → http://${ARR_IP_ADDR}:6969"
echo -e "    Prowlarr    → http://${ARR_IP_ADDR}:9696"
echo -e "    Bazarr      → http://${ARR_IP_ADDR}:6767"
echo -e "    qBittorrent → http://${ARR_IP_ADDR}:8080"
echo -e "    SABnzbd     → http://${ARR_IP_ADDR}:8085"
echo -e "    Homepage    → http://${ARR_IP_ADDR}:3101"
echo -e "    Dozzle      → http://${ARR_IP_ADDR}:8888"
echo -e "    Immich      → http://${ARR_IP_ADDR}:2283"
echo -e "    Syncthing   → http://${ARR_IP_ADDR}:8384"

if [ "$SINGLE_MACHINE" = false ]; then
    echo ""
    echo -e "  ${BOLD}═══ Cross-Machine Config ═══${NC}"
    echo ""
    echo -e "  ${DIM}Overseerr (on Spyglass) needs to connect to Privateer:${NC}"
    echo -e "    Radarr URL: http://${ARR_IP_ADDR}:7878"
    echo -e "    Sonarr URL: http://${ARR_IP_ADDR}:8989"

    # Show API keys if we got them
    if [ -n "$RADARR_KEY" ] && [ -n "$SONARR_KEY" ]; then
        echo -e "    Radarr API Key: ${RADARR_KEY}"
        echo -e "    Sonarr API Key: ${SONARR_KEY}"
    fi
else
    echo ""
    echo -e "  ${DIM}Overseerr → Radarr/Sonarr: use http://localhost:PORT (same machine)${NC}"
fi

echo ""
echo -e "  ${BOLD}═══ Still Needs Your Eyeballs ═══${NC}"
echo ""
echo -e "  ${BOLD}Spyglass (Plex):${NC}"
echo -e "    → Complete setup wizard at http://${PLEX_IP_ADDR}:32400/web"
echo -e "    → Add media libraries"
if [ "$OVERSEERR_CONFIGURED" = true ]; then
    echo -e "    → Overseerr: sign in with Plex (Radarr/Sonarr auto-configured)"
else
    echo -e "    → Overseerr: sign in with Plex, then connect Radarr/Sonarr"
fi
echo -e "    → Configure Tdarr plugins (see init output above)"
echo ""
echo -e "  ${BOLD}Privateer (*arr):${NC}"
echo -e "    → Prowlarr: add your indexers (credentials required)"
echo -e "    → SABnzbd: run setup wizard, add Usenet servers"
echo -e "    → Bazarr: add subtitle providers (OpenSubtitles.com)"
echo -e "    → Immich: create admin account, install Android app"
echo -e "    → Syncthing: set password, pair phone, share folders"
echo -e "    → SMS Backup: install Android app, schedule daily, add to Syncthing"
echo ""
echo -e "  ${DIM}Project files synced to ${REMOTE_PROJECT_PATH}.${NC}"
echo -e "  ${DIM}To re-run, SSH in and run the init script directly.${NC}"
echo ""

# ── Post-deploy polling (Overseerr + Kometa) ──────────────────────────────────
NEED_OVERSEERR_POLL=false
NEED_KOMETA_POLL=false

if [ "${OVERSEERR_CONFIGURED:-false}" != true ] && \
   [ "$PLEX_RESULT" -eq 0 ] && [ "$ARR_RESULT" -eq 0 ] && \
   { [ -n "$RADARR_KEY" ] || [ -n "$SONARR_KEY" ]; } && \
   command -v jq &>/dev/null && command -v curl &>/dev/null; then
    NEED_OVERSEERR_POLL=true
fi

if [ "${KOMETA_TRIGGERED:-false}" != true ] && [ "$PLEX_RESULT" -eq 0 ] && \
   command -v jq &>/dev/null && command -v curl &>/dev/null; then
    NEED_KOMETA_POLL=true
fi

if [ "$NEED_OVERSEERR_POLL" = true ] || [ "$NEED_KOMETA_POLL" = true ]; then
    header "Waiting for Manual Steps"

    if [ "$NEED_OVERSEERR_POLL" = true ]; then
        echo -e "  ${BOLD}Overseerr:${NC}"
        echo -e "    1. Open ${BOLD}http://${PLEX_IP_ADDR}:5055${NC}"
        echo -e "    2. Sign in with your Plex account"
        echo -e "    3. Complete the setup wizard"
        echo -e "    ${DIM}→ Radarr/Sonarr will be auto-configured${NC}"
        echo ""
    fi

    if [ "$NEED_KOMETA_POLL" = true ]; then
        echo -e "  ${BOLD}Plex Libraries:${NC}"
        echo -e "    1. Open ${BOLD}http://${PLEX_IP_ADDR}:32400/web${NC}"
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
        if [ "$NEED_OVERSEERR_POLL" = true ] && check_overseerr_ready_remote "$PLEX_IP_ADDR" "$PLEX_APPDATA"; then
            log "Overseerr is ready! Configuring Radarr/Sonarr..."
            if configure_overseerr_remote "$PLEX_IP_ADDR" "$ARR_IP_ADDR" "$RADARR_KEY" "$SONARR_KEY" "$PLEX_APPDATA"; then
                OVERSEERR_CONFIGURED=true
                NEED_OVERSEERR_POLL=false
                log "Overseerr → Radarr + Sonarr configured!"
            fi
        fi

        # Check Plex libraries → Kometa
        if [ "$NEED_KOMETA_POLL" = true ] && check_plex_has_libraries_remote "$PLEX_IP_ADDR" "${PLEX_TOKEN:-}"; then
            if trigger_kometa_first_run_remote "$PLEX_IP_ADDR" "$PLEX_APPDATA"; then
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
