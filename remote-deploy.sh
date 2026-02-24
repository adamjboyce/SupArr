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
    eval "$var_name=\"$value\""
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
REMOTE_PROJECT_PATH="/opt/suparr"
SSH_KEY="$HOME/.ssh/suparr_deploy_key"

# ===========================================================================
header "SupArr — Remote Deploy"
# ===========================================================================

echo -e "  ${BOLD}Deploy both machines from your desktop.${NC}"
echo -e "  ${DIM}All prompts happen here. No interactive SSH sessions.${NC}\n"

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

echo -e "  ${DIM}Enter the IPs and SSH credentials for both machines.${NC}"
echo -e "  ${DIM}Same SSH user/password for both? Just enter once.${NC}\n"

ask PLEX_IP_ADDR "Plex machine IP" ""
ask ARR_IP_ADDR "*arr machine IP" ""
ask NAS_IP "NAS IP (for NFS mounts, or blank to skip)" ""

echo ""
ask SSH_USER "SSH username (same for both machines)" "root"
ask SSH_PASS "SSH password" "" "secret"

log "Targets: Plex=${PLEX_IP_ADDR}  Arr=${ARR_IP_ADDR}"

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
echo -e "  ${BOLD}Plex machine settings:${NC}\n"

ask PLEX_MEDIA_ROOT "Plex media mount point" "/mnt/media"
ask PLEX_APPDATA "Plex app data directory" "/opt/media-stack"

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

# ── Arr-specific ──
echo ""
echo -e "  ${BOLD}*arr machine settings:${NC}\n"

ask ARR_MEDIA_ROOT "*arr media mount point" "/mnt/media"
ask ARR_DOWNLOADS_ROOT "*arr download scratch directory" "/mnt/downloads"
ask ARR_APPDATA "*arr app data directory" "/opt/arr-stack"

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
ask PLEX_WATCHTOWER_URL "Plex Watchtower notification URL (or 'skip')" "skip"
ask ARR_WATCHTOWER_URL "*arr Watchtower notification URL (or 'skip')" "skip"

[ "$NOTIFIARR_API_KEY" = "skip" ] && NOTIFIARR_API_KEY=""
[ "$PLEX_WATCHTOWER_URL" = "skip" ] && PLEX_WATCHTOWER_URL=""
[ "$ARR_WATCHTOWER_URL" = "skip" ] && ARR_WATCHTOWER_URL=""

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

push_key "$PLEX_IP_ADDR" "Plex"
push_key "$ARR_IP_ADDR" "Arr"

# From now on, use key auth
SSH_CMD="ssh $SSH_OPTS -i $SSH_KEY"
RSYNC_SSH="ssh $SSH_OPTS -i $SSH_KEY"

# Test connectivity
for target in "$PLEX_IP_ADDR" "$ARR_IP_ADDR"; do
    label="Plex"
    [ "$target" = "$ARR_IP_ADDR" ] && label="Arr"
    # shellcheck disable=SC2086
    if $SSH_CMD "${SSH_USER}@${target}" "echo ok" &>/dev/null; then
        log "SSH connection verified: ${label}"
    else
        err "Cannot connect to ${label} (${target}) — check credentials and try again"
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
# Machine 1: Plex Server — Generated by SupArr remote-deploy.sh
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
WATCHTOWER_NOTIFICATION_URL=${PLEX_WATCHTOWER_URL}
ENVEOF

cat > "$ARR_ENV_FILE" <<ENVEOF
# =============================================================================
# Machine 2: *arr Stack — Generated by SupArr remote-deploy.sh
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
WATCHTOWER_NOTIFICATION_URL=${ARR_WATCHTOWER_URL}
ENVEOF

log "Plex .env generated"
log "Arr .env generated"

# ===========================================================================
header "Phase 5: Sync Project Files"
# ===========================================================================

sync_to_target() {
    local host="$1" label="$2" env_file="$3"
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

    # Copy the machine-specific .env
    if [ "$label" = "Plex" ]; then
        rsync -az -e "$RSYNC_SSH" "$env_file" "${SSH_USER}@${host}:${REMOTE_PROJECT_PATH}/machine1-plex/.env"
    else
        rsync -az -e "$RSYNC_SSH" "$env_file" "${SSH_USER}@${host}:${REMOTE_PROJECT_PATH}/machine2-arr/.env"
    fi

    # Set permissions
    # shellcheck disable=SC2086
    $SSH_CMD "${SSH_USER}@${host}" "chmod +x ${REMOTE_PROJECT_PATH}/scripts/*.sh && chmod 600 ${REMOTE_PROJECT_PATH}/machine*-*/.env 2>/dev/null || true"

    log "${label}: files synced"
}

sync_to_target "$PLEX_IP_ADDR" "Plex" "$PLEX_ENV_FILE"
sync_to_target "$ARR_IP_ADDR" "Arr" "$ARR_ENV_FILE"

# ===========================================================================
header "Phase 6: Deploy (Parallel)"
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

PLEX_LOG=$(mktemp)
ARR_LOG=$(mktemp)
trap 'rm -f "$PLEX_ENV_FILE" "$ARR_ENV_FILE" "$PLEX_LOG" "$ARR_LOG"' EXIT

echo -e "  ${BOLD}Launching both init scripts in parallel...${NC}"
echo -e "  ${DIM}This takes 2-5 minutes per machine. Streaming output below.${NC}\n"

# Launch both in background
run_init "$PLEX_IP_ADDR" "Plex" "init-machine1-plex.sh" > "$PLEX_LOG" 2>&1 &
PLEX_PID=$!

run_init "$ARR_IP_ADDR" "Arr" "init-machine2-arr.sh" > "$ARR_LOG" 2>&1 &
ARR_PID=$!

# ===========================================================================
header "Phase 7: Live Output"
# ===========================================================================

# Stream labeled output from both logs
tail_with_label() {
    local file="$1" label="$2" pid="$3"
    while kill -0 "$pid" 2>/dev/null || [ -s "$file" ]; do
        if [ -f "$file" ]; then
            while IFS= read -r line; do
                echo -e "${BOLD}[${label}]${NC} $line"
            done < <(tail -f "$file" 2>/dev/null &
                TAIL_PID=$!
                # Wait for the main process to finish, then kill tail
                while kill -0 "$pid" 2>/dev/null; do sleep 1; done
                sleep 2
                kill "$TAIL_PID" 2>/dev/null || true
            )
            break
        fi
        sleep 1
    done
}

# Simpler approach: wait and dump labeled output
(
    wait "$PLEX_PID" 2>/dev/null
    PLEX_EXIT=$?
    echo ""
    echo -e "${BOLD}━━━ PLEX OUTPUT ━━━${NC}"
    if [ -f "$PLEX_LOG" ]; then
        while IFS= read -r line; do
            echo -e "${BOLD}[PLEX]${NC} $line"
        done < "$PLEX_LOG"
    fi
    if [ "$PLEX_EXIT" -eq 0 ]; then
        echo -e "${BOLD}[PLEX]${NC} ${GREEN}Deploy complete ✓${NC}"
    else
        echo -e "${BOLD}[PLEX]${NC} ${RED}Deploy failed (exit $PLEX_EXIT)${NC}"
    fi
) &
PLEX_OUTPUT_PID=$!

(
    wait "$ARR_PID" 2>/dev/null
    ARR_EXIT=$?
    echo ""
    echo -e "${BOLD}━━━ ARR OUTPUT ━━━${NC}"
    if [ -f "$ARR_LOG" ]; then
        while IFS= read -r line; do
            echo -e "${BOLD}[ARR]${NC}  $line"
        done < "$ARR_LOG"
    fi
    if [ "$ARR_EXIT" -eq 0 ]; then
        echo -e "${BOLD}[ARR]${NC}  ${GREEN}Deploy complete ✓${NC}"
    else
        echo -e "${BOLD}[ARR]${NC}  ${RED}Deploy failed (exit $ARR_EXIT)${NC}"
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

# ===========================================================================
header "Phase 8: Post-Deploy Summary"
# ===========================================================================

# Try to fetch API keys from arr machine's .env for display
ARR_API_KEYS=""
# shellcheck disable=SC2086
ARR_API_KEYS=$($SSH_CMD "${SSH_USER}@${ARR_IP_ADDR}" "cat ${REMOTE_PROJECT_PATH}/machine2-arr/.env 2>/dev/null" || echo "")

echo ""
if [ "$PLEX_RESULT" -eq 0 ] && [ "$ARR_RESULT" -eq 0 ]; then
    log "Both machines deployed successfully!"
elif [ "$PLEX_RESULT" -eq 0 ]; then
    log "Plex deployed successfully"
    err "*arr deploy failed — check output above"
elif [ "$ARR_RESULT" -eq 0 ]; then
    err "Plex deploy failed — check output above"
    log "*arr deployed successfully"
else
    err "Both deploys failed — check output above"
fi

echo ""
echo -e "  ${BOLD}═══ Service URLs ═══${NC}"
echo ""
echo -e "  ${BOLD}Plex Machine (${PLEX_IP_ADDR}):${NC}"
echo -e "    Plex        → http://${PLEX_IP_ADDR}:32400/web"
echo -e "    Tdarr       → http://${PLEX_IP_ADDR}:8265"
echo -e "    Overseerr   → http://${PLEX_IP_ADDR}:5055"
echo -e "    Tautulli    → http://${PLEX_IP_ADDR}:8181"
echo -e "    Homepage    → http://${PLEX_IP_ADDR}:3100"
echo ""
echo -e "  ${BOLD}*arr Machine (${ARR_IP_ADDR}):${NC}"
echo -e "    Radarr      → http://${ARR_IP_ADDR}:7878"
echo -e "    Sonarr      → http://${ARR_IP_ADDR}:8989"
echo -e "    Lidarr      → http://${ARR_IP_ADDR}:8686"
echo -e "    Readarr     → http://${ARR_IP_ADDR}:8787"
echo -e "    Whisparr    → http://${ARR_IP_ADDR}:6969"
echo -e "    Prowlarr    → http://${ARR_IP_ADDR}:9696"
echo -e "    Bazarr      → http://${ARR_IP_ADDR}:6767"
echo -e "    qBittorrent → http://${ARR_IP_ADDR}:8080"
echo -e "    SABnzbd     → http://${ARR_IP_ADDR}:8085"
echo -e "    Homepage    → http://${ARR_IP_ADDR}:3100"
echo -e "    Dozzle      → http://${ARR_IP_ADDR}:8888"

echo ""
echo -e "  ${BOLD}═══ Cross-Machine Config ═══${NC}"
echo ""
echo -e "  ${DIM}Overseerr (on Plex) needs to connect to the *arr machine:${NC}"
echo -e "    Radarr URL: http://${ARR_IP_ADDR}:7878"
echo -e "    Sonarr URL: http://${ARR_IP_ADDR}:8989"

# Show API keys if we got them
if [ -n "$ARR_API_KEYS" ]; then
    RADARR_KEY=$(echo "$ARR_API_KEYS" | grep '^RADARR_API_KEY=' | cut -d= -f2)
    SONARR_KEY=$(echo "$ARR_API_KEYS" | grep '^SONARR_API_KEY=' | cut -d= -f2)
    if [ -n "$RADARR_KEY" ] && [ -n "$SONARR_KEY" ]; then
        echo -e "    Radarr API Key: ${RADARR_KEY}"
        echo -e "    Sonarr API Key: ${SONARR_KEY}"
    fi
fi

echo ""
echo -e "  ${BOLD}═══ Still Needs Your Eyeballs ═══${NC}"
echo ""
echo -e "  ${BOLD}Plex:${NC}"
echo -e "    → Complete setup wizard at http://${PLEX_IP_ADDR}:32400/web"
echo -e "    → Add media libraries"
echo -e "    → Configure Tdarr plugins (see init output above)"
echo ""
echo -e "  ${BOLD}*arr:${NC}"
echo -e "    → Prowlarr: add your indexers (credentials required)"
echo -e "    → SABnzbd: run setup wizard, add Usenet servers"
echo -e "    → Bazarr: add subtitle providers (OpenSubtitles.com)"
echo -e "    → Overseerr: connect to Plex + Radarr/Sonarr"
echo ""
echo -e "  ${DIM}Project files synced to ${REMOTE_PROJECT_PATH} on both machines.${NC}"
echo -e "  ${DIM}To re-run on a specific machine, SSH in and run the init script directly.${NC}"
echo ""
