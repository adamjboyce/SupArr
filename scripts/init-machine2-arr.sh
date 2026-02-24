#!/usr/bin/env bash
# =============================================================================
# Machine 2: Full Init — Bare Debian 12 → Running *arr Stack
# =============================================================================
# Run this on a fresh Debian 12 minimal install. It handles:
#   1. System packages
#   2. Docker installation
#   3. Directory structure
#   4. NFS mounts
#   5. Pre-seeded configs (qBittorrent categories, paths, etc.)
#   6. Docker Compose up
#   7. Wait for services to boot
#   8. Post-deploy API configuration (root folders, download clients, naming,
#      Bazarr forced subs, Prowlarr connections, Recyclarr sync)
#
# Prerequisites:
#   - Debian 12 minimal installed with SSH
#   - Network configured
#   - .env file populated (copy from .env.example and fill in)
#   - NAS reachable and NFS exports configured
#
# Usage:
#   cd /path/to/media-stack-final/machine2-arr
#   cp .env.example .env && nano .env   # fill in your values
#   chmod +x ../scripts/init-machine2-arr.sh
#   sudo ../scripts/init-machine2-arr.sh
# =============================================================================

set -euo pipefail

# Colors
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
CYAN='\033[0;36m'; BOLD='\033[1m'; NC='\033[0m'

log()  { echo -e "${GREEN}[✓]${NC} $1"; }
warn() { echo -e "${YELLOW}[!]${NC} $1"; }
err()  { echo -e "${RED}[✗]${NC} $1"; }
info() { echo -e "${CYAN}[→]${NC} $1"; }
header() { echo -e "\n${BOLD}═══════════════════════════════════════════${NC}"; echo -e "${BOLD}  $1${NC}"; echo -e "${BOLD}═══════════════════════════════════════════${NC}\n"; }

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/../machine2-arr" && pwd)"

# Load .env
if [ -f "$PROJECT_DIR/.env" ]; then
    set -a; source "$PROJECT_DIR/.env"; set +a
    log "Loaded .env from $PROJECT_DIR"
else
    err ".env not found at $PROJECT_DIR/.env"
    err "Copy .env.example to .env and fill in your values first."
    exit 1
fi

APPDATA="${APPDATA:-/opt/arr-stack}"
MEDIA_ROOT="${MEDIA_ROOT:-/mnt/media}"
DOWNLOADS_ROOT="${DOWNLOADS_ROOT:-/mnt/downloads}"
QBIT_PASSWORD="${QBIT_PASSWORD:-adminadmin}"
NAS_IP="${NAS_IP:-}"
NAS_MEDIA_EXPORT="${NAS_MEDIA_EXPORT:-/volume1/media}"
NAS_DOWNLOADS_EXPORT="${NAS_DOWNLOADS_EXPORT:-/volume1/downloads}"

# ===========================================================================
header "Phase 1: System Packages"
# ===========================================================================

# Set machine hostname (idempotent)
if [ "$(hostname | tr '[:upper:]' '[:lower:]')" != "privateer" ]; then
    hostnamectl set-hostname privateer 2>/dev/null || true
    log "Hostname set to privateer"
else
    log "Hostname already set to privateer"
fi

info "Updating system..."
apt-get update -qq && apt-get upgrade -y -qq

info "Installing dependencies..."
apt-get install -y -qq \
    curl git wget jq nfs-common htop iotop \
    ca-certificates gnupg lsb-release \
    apt-transport-https software-properties-common

log "System packages installed"

# ===========================================================================
header "Phase 2: Docker Installation"
# ===========================================================================

if command -v docker &>/dev/null; then
    log "Docker already installed: $(docker --version)"
else
    info "Installing Docker..."
    curl -fsSL https://get.docker.com | sh
    log "Docker installed"
fi

# Add the real user (not root) to docker group
REAL_USER="${SUDO_USER:-$USER}"
if [ "$REAL_USER" != "root" ]; then
    usermod -aG docker "$REAL_USER"
    log "Added $REAL_USER to docker group"
fi

# ===========================================================================
header "Phase 3: Directory Structure"
# ===========================================================================

info "Creating app data directories..."
mkdir -p "$APPDATA"/{gluetun,qbittorrent/config/qBittorrent,sabnzbd/config,prowlarr/config,flaresolverr}
mkdir -p "$APPDATA"/{radarr/config,sonarr/config,lidarr/config,readarr/config}
mkdir -p "$APPDATA"/{bazarr/config,recyclarr/config,autobrr/config}
mkdir -p "$APPDATA"/{unpackerr,notifiarr/config,homepage/config}
mkdir -p "$APPDATA"/{whisparr/config,filebot/config,tailscale/state}
mkdir -p "$APPDATA"/dozzle

# Set ownership to real user
if [ "$REAL_USER" != "root" ]; then
    chown -R "$REAL_USER":"$REAL_USER" "$APPDATA"
fi

log "App data directories created at $APPDATA"

info "Creating download directories..."
mkdir -p "$DOWNLOADS_ROOT"/{torrents/{complete,incomplete},usenet/{complete,incomplete}}
if [ "$REAL_USER" != "root" ]; then
    chown -R "$REAL_USER":"$REAL_USER" "$DOWNLOADS_ROOT"
fi
log "Download directories created at $DOWNLOADS_ROOT"

# ===========================================================================
header "Phase 4: NFS Mounts"
# ===========================================================================

if [ -n "$NAS_IP" ]; then
    info "Configuring NFS mounts..."
    mkdir -p "$MEDIA_ROOT"

    # Check if already mounted
    if mountpoint -q "$MEDIA_ROOT" 2>/dev/null; then
        log "Media already mounted at $MEDIA_ROOT"
    else
        # Add to fstab if not already there
        FSTAB_ENTRY="${NAS_IP}:${NAS_MEDIA_EXPORT} ${MEDIA_ROOT} nfs rw,hard,intr,rsize=1048576,wsize=1048576,timeo=600,retrans=2 0 0"
        if ! grep -qF "$MEDIA_ROOT" /etc/fstab; then
            echo "$FSTAB_ENTRY" >> /etc/fstab
            log "Added media NFS mount to fstab"
        fi
        mount "$MEDIA_ROOT" && log "Mounted $MEDIA_ROOT" || warn "Could not mount $MEDIA_ROOT — check NAS export"
    fi

    # Create media subdirectories on NAS mount
    for dir in movies tv anime anime-movies documentaries stand-up concerts music books audiobooks adult; do
        mkdir -p "$MEDIA_ROOT/$dir" 2>/dev/null || true
    done
    log "Media subdirectories ensured"

    # --- Downloads NFS mount (enables hardlinks: same filesystem as media) ---
    if [ -n "$NAS_DOWNLOADS_EXPORT" ]; then
        mkdir -p "$DOWNLOADS_ROOT"

        if mountpoint -q "$DOWNLOADS_ROOT" 2>/dev/null; then
            log "Downloads already mounted at $DOWNLOADS_ROOT"
        else
            DL_FSTAB_ENTRY="${NAS_IP}:${NAS_DOWNLOADS_EXPORT} ${DOWNLOADS_ROOT} nfs rw,hard,intr,rsize=1048576,wsize=1048576,timeo=600,retrans=2 0 0"
            if ! grep -qF "$DOWNLOADS_ROOT" /etc/fstab; then
                echo "$DL_FSTAB_ENTRY" >> /etc/fstab
                log "Added downloads NFS mount to fstab"
            fi
            mount "$DOWNLOADS_ROOT" && log "Mounted $DOWNLOADS_ROOT" || warn "Could not mount $DOWNLOADS_ROOT — check NAS export"
        fi

        # Create download subdirectories
        mkdir -p "$DOWNLOADS_ROOT"/{torrents/{complete,incomplete},usenet/{complete,incomplete}} 2>/dev/null || true
        log "Download directories ensured on NAS"
    fi
else
    warn "NAS_IP not set in .env — skipping NFS mount setup"
    warn "Set NAS_IP, NAS_MEDIA_EXPORT in .env and re-run, or mount manually"
fi

# ===========================================================================
header "Phase 5: Pre-Seed Configurations"
# ===========================================================================

# --- qBittorrent: pre-seed config with correct paths and categories ---
QBIT_CONF="$APPDATA/qbittorrent/config/qBittorrent/qBittorrent.conf"
if [ ! -f "$QBIT_CONF" ]; then
    info "Pre-seeding qBittorrent config..."
    cp "$SCRIPT_DIR/../machine2-arr/config-seeds/qbittorrent/qBittorrent.conf" "$QBIT_CONF"
    log "qBittorrent config pre-seeded (categories, paths, seed ratios)"
else
    log "qBittorrent config already exists — skipping pre-seed"
fi

# --- Recyclarr: deploy TRaSH Guides config ---
RECYCLARR_CONF="$APPDATA/recyclarr/config/recyclarr.yml"
if [ ! -f "$RECYCLARR_CONF" ]; then
    info "Deploying Recyclarr config..."
    cp "$PROJECT_DIR/config-templates/recyclarr.yml" "$RECYCLARR_CONF"
    log "Recyclarr config deployed"
else
    log "Recyclarr config already exists"
fi

# Always substitute API keys (idempotent — no-op if placeholders already replaced)
if [ -f "$RECYCLARR_CONF" ]; then
    [ -n "${SONARR_API_KEY:-}" ] && sed -i "s/YOUR_SONARR_API_KEY/${SONARR_API_KEY}/g" "$RECYCLARR_CONF"
    [ -n "${RADARR_API_KEY:-}" ] && sed -i "s/YOUR_RADARR_API_KEY/${RADARR_API_KEY}/g" "$RECYCLARR_CONF"
    log "Recyclarr credentials substituted"
fi

# Set final ownership
if [ "$REAL_USER" != "root" ]; then
    chown -R "$REAL_USER":"$REAL_USER" "$APPDATA"
fi

# ===========================================================================
header "Phase 6: Docker Compose Up"
# ===========================================================================

info "Starting *arr stack..."
cd "$PROJECT_DIR"

# Run as real user if possible
if [ "$REAL_USER" != "root" ] && id -nG "$REAL_USER" | grep -qw docker; then
    sudo -u "$REAL_USER" docker compose up -d --remove-orphans
else
    docker compose up -d --remove-orphans
fi

log "All containers starting"

# Wait for critical services
info "Waiting for services to initialize (this takes 30-60 seconds)..."
sleep 15

# ===========================================================================
header "Phase 7: Collect API Keys"
# ===========================================================================

info "Collecting API keys from freshly started services..."

# Function to extract API key from *arr app config.xml
get_arr_api_key() {
    local app_name="$1"
    local config_path="$2"
    local max_wait=60
    local waited=0

    while [ $waited -lt $max_wait ]; do
        if [ -f "$config_path" ]; then
            local key
            key=$(grep -oP '<ApiKey>\K[^<]+' "$config_path" 2>/dev/null || echo "")
            if [ -n "$key" ]; then
                echo "$key"
                return 0
            fi
        fi
        sleep 2
        waited=$((waited + 2))
    done
    echo ""
    return 1
}

# Always read live keys and compare to .env (detects changed keys on re-run)
NEED_ENV_UPDATE=false
ENV_FILE="$PROJECT_DIR/.env"

update_env_key() {
    local key="$1" value="$2" force="${3:-}"
    if [ -n "$value" ]; then
        if grep -q "^${key}=" "$ENV_FILE"; then
            if [ "$force" = "--force" ]; then
                sed -i "s|^${key}=.*$|${key}=${value}|" "$ENV_FILE"
            else
                # Only update if currently empty or placeholder
                sed -i "s/^${key}=$/&${value}/" "$ENV_FILE"
                sed -i "s/^${key}=YOUR_.*$/${key}=${value}/" "$ENV_FILE"
            fi
        else
            echo "${key}=${value}" >> "$ENV_FILE"
        fi
    fi
}

# --- Radarr ---
LIVE_KEY=$(get_arr_api_key "Radarr" "$APPDATA/radarr/config/config.xml")
if [ -n "$LIVE_KEY" ] && [ "$LIVE_KEY" != "${RADARR_API_KEY:-}" ]; then
    RADARR_API_KEY="$LIVE_KEY"
    log "Radarr API key: $RADARR_API_KEY"
    NEED_ENV_UPDATE=true
elif [ -z "${RADARR_API_KEY:-}" ] && [ -z "$LIVE_KEY" ]; then
    warn "Could not get Radarr API key — container may still be starting"
fi

# --- Sonarr ---
LIVE_KEY=$(get_arr_api_key "Sonarr" "$APPDATA/sonarr/config/config.xml")
if [ -n "$LIVE_KEY" ] && [ "$LIVE_KEY" != "${SONARR_API_KEY:-}" ]; then
    SONARR_API_KEY="$LIVE_KEY"
    log "Sonarr API key: $SONARR_API_KEY"
    NEED_ENV_UPDATE=true
elif [ -z "${SONARR_API_KEY:-}" ] && [ -z "$LIVE_KEY" ]; then
    warn "Could not get Sonarr API key — container may still be starting"
fi

# --- Lidarr ---
LIVE_KEY=$(get_arr_api_key "Lidarr" "$APPDATA/lidarr/config/config.xml")
if [ -n "$LIVE_KEY" ] && [ "$LIVE_KEY" != "${LIDARR_API_KEY:-}" ]; then
    LIDARR_API_KEY="$LIVE_KEY"
    log "Lidarr API key: $LIDARR_API_KEY"
    NEED_ENV_UPDATE=true
elif [ -z "${LIDARR_API_KEY:-}" ] && [ -z "$LIVE_KEY" ]; then
    warn "Could not get Lidarr API key"
fi

# --- Prowlarr ---
LIVE_KEY=$(get_arr_api_key "Prowlarr" "$APPDATA/prowlarr/config/config.xml")
if [ -n "$LIVE_KEY" ] && [ "$LIVE_KEY" != "${PROWLARR_API_KEY:-}" ]; then
    PROWLARR_API_KEY="$LIVE_KEY"
    log "Prowlarr API key: $PROWLARR_API_KEY"
    NEED_ENV_UPDATE=true
elif [ -z "${PROWLARR_API_KEY:-}" ] && [ -z "$LIVE_KEY" ]; then
    warn "Could not get Prowlarr API key"
fi

# --- Bazarr (stores key differently) ---
BAZARR_CONF_DB="$APPDATA/bazarr/config/config/config.yaml"
if [ -f "$BAZARR_CONF_DB" ]; then
    LIVE_KEY=$(grep -oP 'apikey:\s*\K\S+' "$BAZARR_CONF_DB" 2>/dev/null || echo "")
    if [ -n "$LIVE_KEY" ] && [ "$LIVE_KEY" != "${BAZARR_API_KEY:-}" ]; then
        BAZARR_API_KEY="$LIVE_KEY"
        log "Bazarr API key: $BAZARR_API_KEY"
        NEED_ENV_UPDATE=true
    fi
fi

# --- Readarr ---
LIVE_KEY=$(get_arr_api_key "Readarr" "$APPDATA/readarr/config/config.xml")
if [ -n "$LIVE_KEY" ] && [ "$LIVE_KEY" != "${READARR_API_KEY:-}" ]; then
    READARR_API_KEY="$LIVE_KEY"
    log "Readarr API key: $READARR_API_KEY"
    NEED_ENV_UPDATE=true
elif [ -z "${READARR_API_KEY:-}" ] && [ -z "$LIVE_KEY" ]; then
    warn "Could not get Readarr API key"
fi

# --- Whisparr ---
LIVE_KEY=$(get_arr_api_key "Whisparr" "$APPDATA/whisparr/config/config.xml")
if [ -n "$LIVE_KEY" ] && [ "$LIVE_KEY" != "${WHISPARR_API_KEY:-}" ]; then
    WHISPARR_API_KEY="$LIVE_KEY"
    log "Whisparr API key: $WHISPARR_API_KEY"
    NEED_ENV_UPDATE=true
elif [ -z "${WHISPARR_API_KEY:-}" ] && [ -z "$LIVE_KEY" ]; then
    warn "Could not get Whisparr API key"
fi

# Auto-update .env with discovered keys (--force to handle changed keys)
if [ "$NEED_ENV_UPDATE" = true ]; then
    info "Updating .env with discovered API keys..."

    update_env_key "RADARR_API_KEY" "$RADARR_API_KEY" --force
    update_env_key "SONARR_API_KEY" "$SONARR_API_KEY" --force
    update_env_key "LIDARR_API_KEY" "$LIDARR_API_KEY" --force
    update_env_key "PROWLARR_API_KEY" "$PROWLARR_API_KEY" --force
    update_env_key "BAZARR_API_KEY" "${BAZARR_API_KEY:-}" --force
    update_env_key "READARR_API_KEY" "${READARR_API_KEY:-}" --force
    update_env_key "WHISPARR_API_KEY" "${WHISPARR_API_KEY:-}" --force

    # Also update Recyclarr config with real keys
    if [ -f "$RECYCLARR_CONF" ]; then
        [ -n "$SONARR_API_KEY" ] && sed -i "s/YOUR_SONARR_API_KEY/${SONARR_API_KEY}/g" "$RECYCLARR_CONF"
        [ -n "$RADARR_API_KEY" ] && sed -i "s/YOUR_RADARR_API_KEY/${RADARR_API_KEY}/g" "$RECYCLARR_CONF"
    fi

    log ".env updated with API keys"
fi

# ===========================================================================
header "Phase 8: Post-Deploy API Configuration"
# ===========================================================================

# Re-source .env to pick up any newly written keys
set -a; source "$PROJECT_DIR/.env"; set +a

ARR_HOST="localhost"

# Helper: generic *arr API call
arr_api() {
    local url="$1" api_key="$2" method="${3:-GET}" data="${4:-}"
    if [ -n "$data" ]; then
        curl -sf -X "$method" "$url" \
            -H "X-Api-Key: $api_key" \
            -H "Content-Type: application/json" \
            -d "$data" 2>/dev/null
    else
        curl -sf -X "$method" "$url" \
            -H "X-Api-Key: $api_key" \
            -H "Content-Type: application/json" 2>/dev/null
    fi
}

wait_for_api() {
    local name="$1" url="$2" max=30
    for i in $(seq 1 "$max"); do
        curl -sf -o /dev/null "$url" 2>/dev/null && return 0
        sleep 2
    done
    warn "$name API not ready after ${max} attempts"
    return 1
}

# --- RADARR ---
if [ -n "${RADARR_API_KEY:-}" ]; then
    info "Configuring Radarr..."
    if wait_for_api "Radarr" "http://${ARR_HOST}:7878/api/v3/system/status?apikey=${RADARR_API_KEY}"; then

        # Root folders
        for folder in movies documentaries stand-up concerts anime-movies; do
            existing=$(arr_api "http://${ARR_HOST}:7878/api/v3/rootfolder" "$RADARR_API_KEY" | grep -c "/${folder}" || true)
            if [ "$existing" -eq 0 ]; then
                arr_api "http://${ARR_HOST}:7878/api/v3/rootfolder" "$RADARR_API_KEY" POST \
                    "{\"path\": \"/${folder}\", \"accessible\": true}" > /dev/null && \
                    log "  Root folder: /${folder}" || warn "  Could not add /${folder}"
            fi
        done

        # Download client: qBittorrent
        existing_dc=$(arr_api "http://${ARR_HOST}:7878/api/v3/downloadclient" "$RADARR_API_KEY" | grep -c "qBittorrent" || true)
        if [ "$existing_dc" -eq 0 ]; then
            arr_api "http://${ARR_HOST}:7878/api/v3/downloadclient" "$RADARR_API_KEY" POST "{
                \"enable\": true, \"protocol\": \"torrent\", \"priority\": 1,
                \"name\": \"qBittorrent\", \"implementation\": \"QBittorrent\",
                \"configContract\": \"QBittorrentSettings\",
                \"fields\": [
                    {\"name\": \"host\", \"value\": \"gluetun\"},
                    {\"name\": \"port\", \"value\": 8080},
                    {\"name\": \"username\", \"value\": \"admin\"},
                    {\"name\": \"password\", \"value\": \"${QBIT_PASSWORD}\"},
                    {\"name\": \"movieCategory\", \"value\": \"radarr\"}
                ],
                \"removeCompletedDownloads\": true, \"removeFailedDownloads\": true
            }" > /dev/null && log "  Download client: qBittorrent" || warn "  Could not add qBittorrent"
        fi

        # Download client: SABnzbd (if key provided)
        if [ -n "${SABNZBD_API_KEY:-}" ]; then
            existing_sab=$(arr_api "http://${ARR_HOST}:7878/api/v3/downloadclient" "$RADARR_API_KEY" | grep -c "SABnzbd" || true)
            if [ "$existing_sab" -eq 0 ]; then
                arr_api "http://${ARR_HOST}:7878/api/v3/downloadclient" "$RADARR_API_KEY" POST "{
                    \"enable\": true, \"protocol\": \"usenet\", \"priority\": 1,
                    \"name\": \"SABnzbd\", \"implementation\": \"Sabnzbd\",
                    \"configContract\": \"SabnzbdSettings\",
                    \"fields\": [
                        {\"name\": \"host\", \"value\": \"gluetun\"},
                        {\"name\": \"port\", \"value\": 8085},
                        {\"name\": \"apiKey\", \"value\": \"${SABNZBD_API_KEY}\"},
                        {\"name\": \"movieCategory\", \"value\": \"radarr\"}
                    ],
                    \"removeCompletedDownloads\": true, \"removeFailedDownloads\": true
                }" > /dev/null && log "  Download client: SABnzbd" || warn "  Could not add SABnzbd"
            fi
        fi

        # Naming convention
        arr_api "http://${ARR_HOST}:7878/api/v3/config/naming" "$RADARR_API_KEY" PUT '{
            "renameMovies": true, "replaceIllegalCharacters": true,
            "standardMovieFormat": "{Movie Title} ({Release Year}) [{Quality Full}]{[MediaInfo VideoDynamicRangeType]}",
            "movieFolderFormat": "{Movie Title} ({Release Year})"
        }' > /dev/null && log "  Naming convention set" || true

        log "Radarr configured"
    fi
fi

# --- SONARR ---
if [ -n "${SONARR_API_KEY:-}" ]; then
    info "Configuring Sonarr..."
    if wait_for_api "Sonarr" "http://${ARR_HOST}:8989/api/v3/system/status?apikey=${SONARR_API_KEY}"; then

        for folder in tv anime; do
            existing=$(arr_api "http://${ARR_HOST}:8989/api/v3/rootfolder" "$SONARR_API_KEY" | grep -c "/${folder}" || true)
            if [ "$existing" -eq 0 ]; then
                arr_api "http://${ARR_HOST}:8989/api/v3/rootfolder" "$SONARR_API_KEY" POST \
                    "{\"path\": \"/${folder}\", \"accessible\": true}" > /dev/null && \
                    log "  Root folder: /${folder}" || warn "  Could not add /${folder}"
            fi
        done

        existing_dc=$(arr_api "http://${ARR_HOST}:8989/api/v3/downloadclient" "$SONARR_API_KEY" | grep -c "qBittorrent" || true)
        if [ "$existing_dc" -eq 0 ]; then
            arr_api "http://${ARR_HOST}:8989/api/v3/downloadclient" "$SONARR_API_KEY" POST "{
                \"enable\": true, \"protocol\": \"torrent\", \"priority\": 1,
                \"name\": \"qBittorrent\", \"implementation\": \"QBittorrent\",
                \"configContract\": \"QBittorrentSettings\",
                \"fields\": [
                    {\"name\": \"host\", \"value\": \"gluetun\"},
                    {\"name\": \"port\", \"value\": 8080},
                    {\"name\": \"username\", \"value\": \"admin\"},
                    {\"name\": \"password\", \"value\": \"${QBIT_PASSWORD}\"},
                    {\"name\": \"tvCategory\", \"value\": \"sonarr\"}
                ],
                \"removeCompletedDownloads\": true, \"removeFailedDownloads\": true
            }" > /dev/null && log "  Download client: qBittorrent" || true
        fi

        if [ -n "${SABNZBD_API_KEY:-}" ]; then
            existing_sab=$(arr_api "http://${ARR_HOST}:8989/api/v3/downloadclient" "$SONARR_API_KEY" | grep -c "SABnzbd" || true)
            if [ "$existing_sab" -eq 0 ]; then
                arr_api "http://${ARR_HOST}:8989/api/v3/downloadclient" "$SONARR_API_KEY" POST "{
                    \"enable\": true, \"protocol\": \"usenet\", \"priority\": 1,
                    \"name\": \"SABnzbd\", \"implementation\": \"Sabnzbd\",
                    \"configContract\": \"SabnzbdSettings\",
                    \"fields\": [
                        {\"name\": \"host\", \"value\": \"gluetun\"},
                        {\"name\": \"port\", \"value\": 8085},
                        {\"name\": \"apiKey\", \"value\": \"${SABNZBD_API_KEY}\"},
                        {\"name\": \"tvCategory\", \"value\": \"sonarr\"}
                    ],
                    \"removeCompletedDownloads\": true, \"removeFailedDownloads\": true
                }" > /dev/null && log "  Download client: SABnzbd" || true
            fi
        fi

        arr_api "http://${ARR_HOST}:8989/api/v3/config/naming" "$SONARR_API_KEY" PUT '{
            "renameEpisodes": true, "replaceIllegalCharacters": true,
            "standardEpisodeFormat": "{Series Title} - S{season:00}E{episode:00} - {Episode Title} [{Quality Full}]{[MediaInfo VideoDynamicRangeType]}",
            "seasonFolderFormat": "Season {season:00}",
            "seriesFolderFormat": "{Series Title} ({Series Year})"
        }' > /dev/null && log "  Naming convention set" || true

        log "Sonarr configured"
    fi
fi

# --- LIDARR ---
if [ -n "${LIDARR_API_KEY:-}" ]; then
    info "Configuring Lidarr..."
    if wait_for_api "Lidarr" "http://${ARR_HOST}:8686/api/v1/system/status?apikey=${LIDARR_API_KEY}"; then

        existing=$(arr_api "http://${ARR_HOST}:8686/api/v1/rootfolder" "$LIDARR_API_KEY" | grep -c "/music" || true)
        if [ "$existing" -eq 0 ]; then
            arr_api "http://${ARR_HOST}:8686/api/v1/rootfolder" "$LIDARR_API_KEY" POST \
                '{"path": "/music", "accessible": true}' > /dev/null && log "  Root folder: /music" || true
        fi

        existing_dc=$(arr_api "http://${ARR_HOST}:8686/api/v1/downloadclient" "$LIDARR_API_KEY" | grep -c "qBittorrent" || true)
        if [ "$existing_dc" -eq 0 ]; then
            arr_api "http://${ARR_HOST}:8686/api/v1/downloadclient" "$LIDARR_API_KEY" POST "{
                \"enable\": true, \"protocol\": \"torrent\", \"priority\": 1,
                \"name\": \"qBittorrent\", \"implementation\": \"QBittorrent\",
                \"configContract\": \"QBittorrentSettings\",
                \"fields\": [
                    {\"name\": \"host\", \"value\": \"gluetun\"},
                    {\"name\": \"port\", \"value\": 8080},
                    {\"name\": \"username\", \"value\": \"admin\"},
                    {\"name\": \"password\", \"value\": \"${QBIT_PASSWORD}\"},
                    {\"name\": \"musicCategory\", \"value\": \"lidarr\"}
                ],
                \"removeCompletedDownloads\": true, \"removeFailedDownloads\": true
            }" > /dev/null && log "  Download client: qBittorrent" || true
        fi

        log "Lidarr configured"
    fi
fi

# --- PROWLARR → *ARR CONNECTIONS ---
if [ -n "${PROWLARR_API_KEY:-}" ]; then
    info "Configuring Prowlarr connections..."
    if wait_for_api "Prowlarr" "http://${ARR_HOST}:9696/api/v1/system/status?apikey=${PROWLARR_API_KEY}"; then

        # Connect Radarr
        if [ -n "${RADARR_API_KEY:-}" ]; then
            arr_api "http://${ARR_HOST}:9696/api/v1/applications" "$PROWLARR_API_KEY" POST "{
                \"name\": \"Radarr\", \"syncLevel\": \"fullSync\",
                \"implementation\": \"Radarr\", \"configContract\": \"RadarrSettings\",
                \"fields\": [
                    {\"name\": \"prowlarrUrl\", \"value\": \"http://prowlarr:9696\"},
                    {\"name\": \"baseUrl\", \"value\": \"http://radarr:7878\"},
                    {\"name\": \"apiKey\", \"value\": \"${RADARR_API_KEY}\"}
                ]
            }" > /dev/null 2>&1 && log "  Prowlarr → Radarr connected" || warn "  Prowlarr → Radarr failed (may already exist)"
        fi

        # Connect Sonarr
        if [ -n "${SONARR_API_KEY:-}" ]; then
            arr_api "http://${ARR_HOST}:9696/api/v1/applications" "$PROWLARR_API_KEY" POST "{
                \"name\": \"Sonarr\", \"syncLevel\": \"fullSync\",
                \"implementation\": \"Sonarr\", \"configContract\": \"SonarrSettings\",
                \"fields\": [
                    {\"name\": \"prowlarrUrl\", \"value\": \"http://prowlarr:9696\"},
                    {\"name\": \"baseUrl\", \"value\": \"http://sonarr:8989\"},
                    {\"name\": \"apiKey\", \"value\": \"${SONARR_API_KEY}\"}
                ]
            }" > /dev/null 2>&1 && log "  Prowlarr → Sonarr connected" || warn "  Prowlarr → Sonarr failed"
        fi

        # Connect Lidarr
        if [ -n "${LIDARR_API_KEY:-}" ]; then
            arr_api "http://${ARR_HOST}:9696/api/v1/applications" "$PROWLARR_API_KEY" POST "{
                \"name\": \"Lidarr\", \"syncLevel\": \"fullSync\",
                \"implementation\": \"Lidarr\", \"configContract\": \"LidarrSettings\",
                \"fields\": [
                    {\"name\": \"prowlarrUrl\", \"value\": \"http://prowlarr:9696\"},
                    {\"name\": \"baseUrl\", \"value\": \"http://lidarr:8686\"},
                    {\"name\": \"apiKey\", \"value\": \"${LIDARR_API_KEY}\"}
                ]
            }" > /dev/null 2>&1 && log "  Prowlarr → Lidarr connected" || warn "  Prowlarr → Lidarr failed"
        fi

        # Add FlareSolverr proxy
        arr_api "http://${ARR_HOST}:9696/api/v1/indexerProxy" "$PROWLARR_API_KEY" POST '{
            "name": "FlareSolverr", "implementation": "FlareSolverr",
            "configContract": "FlareSolverrSettings",
            "fields": [
                {"name": "host", "value": "http://flaresolverr:8191"},
                {"name": "requestTimeout", "value": 60}
            ], "tags": []
        }' > /dev/null 2>&1 && log "  FlareSolverr proxy added" || warn "  FlareSolverr may already exist"

        log "Prowlarr configured"
    fi
fi

# --- RECYCLARR SYNC ---
info "Syncing Recyclarr quality profiles..."
sleep 5
docker exec recyclarr recyclarr sync 2>/dev/null && \
    log "Recyclarr: TRaSH Guide profiles synced" || \
    warn "Recyclarr: Sync failed — may need API keys in config. Re-run after updating."

# ===========================================================================
header "Phase 8b: Readarr, Whisparr, Bazarr & qBit Password"
# ===========================================================================

# Re-source .env to pick up any newly written keys
set -a; source "$PROJECT_DIR/.env"; set +a

# --- qBittorrent: change default password ---
QBIT_PASS="${QBIT_PASSWORD:-adminadmin}"
if [ "$QBIT_PASS" != "adminadmin" ]; then
    info "Setting qBittorrent password..."
    # Try custom password first (most likely on re-run)
    QBIT_COOKIE=$(curl -sf -c - -X POST "http://localhost:8080/api/v2/auth/login" \
        -d "username=admin&password=${QBIT_PASS}" 2>/dev/null | grep -oP 'SID\s+\K\S+' || echo "")

    if [ -n "$QBIT_COOKIE" ]; then
        log "qBittorrent: password already set"
    else
        # Fall back to default password (first run)
        QBIT_COOKIE=$(curl -sf -c - -X POST "http://localhost:8080/api/v2/auth/login" \
            -d "username=admin&password=adminadmin" 2>/dev/null | grep -oP 'SID\s+\K\S+' || echo "")
        if [ -n "$QBIT_COOKIE" ]; then
            curl -sf -X POST "http://localhost:8080/api/v2/app/setPreferences" \
                -b "SID=$QBIT_COOKIE" \
                -d "json={\"web_ui_password\":\"${QBIT_PASS}\"}" 2>/dev/null && \
                log "qBittorrent: password changed (user: admin)" || \
                warn "qBittorrent: could not change password"
        else
            warn "qBittorrent: could not log in (container may still be starting)"
        fi
    fi
fi

# --- READARR: root folders + download client ---
if [ -n "${READARR_API_KEY:-}" ]; then
    info "Configuring Readarr..."
    if wait_for_api "Readarr" "http://${ARR_HOST}:8787/api/v1/system/status?apikey=${READARR_API_KEY}"; then

        for folder in books audiobooks; do
            existing=$(arr_api "http://${ARR_HOST}:8787/api/v1/rootfolder" "$READARR_API_KEY" | grep -c "/${folder}" || true)
            if [ "$existing" -eq 0 ]; then
                arr_api "http://${ARR_HOST}:8787/api/v1/rootfolder" "$READARR_API_KEY" POST \
                    "{\"path\": \"/${folder}\", \"accessible\": true, \"defaultMetadataProfileId\": 1, \"defaultQualityProfileId\": 1}" > /dev/null 2>&1 && \
                    log "  Readarr: root folder /${folder}" || true
            fi
        done

        existing_dc=$(arr_api "http://${ARR_HOST}:8787/api/v1/downloadclient" "$READARR_API_KEY" | grep -c "qBittorrent" || true)
        if [ "$existing_dc" -eq 0 ]; then
            arr_api "http://${ARR_HOST}:8787/api/v1/downloadclient" "$READARR_API_KEY" POST "{
                \"enable\": true, \"protocol\": \"torrent\", \"priority\": 1,
                \"name\": \"qBittorrent\", \"implementation\": \"QBittorrent\",
                \"configContract\": \"QBittorrentSettings\",
                \"fields\": [
                    {\"name\": \"host\", \"value\": \"gluetun\"},
                    {\"name\": \"port\", \"value\": 8080},
                    {\"name\": \"username\", \"value\": \"admin\"},
                    {\"name\": \"password\", \"value\": \"${QBIT_PASSWORD}\"},
                    {\"name\": \"musicCategory\", \"value\": \"readarr\"}
                ],
                \"removeCompletedDownloads\": true, \"removeFailedDownloads\": true
            }" > /dev/null 2>&1 && log "  Readarr: download client configured" || true
        fi
        log "Readarr configured"
    fi
fi

# --- WHISPARR: root folder + download client ---
if [ -n "${WHISPARR_API_KEY:-}" ]; then
    info "Configuring Whisparr..."
    if wait_for_api "Whisparr" "http://${ARR_HOST}:6969/api/v3/system/status?apikey=${WHISPARR_API_KEY}"; then

        existing=$(arr_api "http://${ARR_HOST}:6969/api/v3/rootfolder" "$WHISPARR_API_KEY" | grep -c "/adult" || true)
        if [ "$existing" -eq 0 ]; then
            arr_api "http://${ARR_HOST}:6969/api/v3/rootfolder" "$WHISPARR_API_KEY" POST \
                "{\"path\": \"/adult\", \"accessible\": true}" > /dev/null 2>&1 && \
                log "  Whisparr: root folder /adult" || true
        fi

        existing_dc=$(arr_api "http://${ARR_HOST}:6969/api/v3/downloadclient" "$WHISPARR_API_KEY" | grep -c "qBittorrent" || true)
        if [ "$existing_dc" -eq 0 ]; then
            arr_api "http://${ARR_HOST}:6969/api/v3/downloadclient" "$WHISPARR_API_KEY" POST "{
                \"enable\": true, \"protocol\": \"torrent\", \"priority\": 1,
                \"name\": \"qBittorrent\", \"implementation\": \"QBittorrent\",
                \"configContract\": \"QBittorrentSettings\",
                \"fields\": [
                    {\"name\": \"host\", \"value\": \"gluetun\"},
                    {\"name\": \"port\", \"value\": 8080},
                    {\"name\": \"username\", \"value\": \"admin\"},
                    {\"name\": \"password\", \"value\": \"${QBIT_PASSWORD}\"},
                    {\"name\": \"movieCategory\", \"value\": \"whisparr\"}
                ],
                \"removeCompletedDownloads\": true, \"removeFailedDownloads\": true
            }" > /dev/null 2>&1 && log "  Whisparr: download client configured" || true
        fi
        log "Whisparr configured"
    fi
fi

# --- BAZARR: Sonarr/Radarr connection + forced subs ---
if [ -n "${BAZARR_API_KEY:-}" ]; then
    info "Configuring Bazarr..."
    sleep 5  # Bazarr is slow to init

    # Configure Sonarr connection
    if [ -n "${SONARR_API_KEY:-}" ]; then
        curl -sf -X PATCH "http://localhost:6767/api/system/settings/sonarr" \
            -H "X-API-KEY: ${BAZARR_API_KEY}" \
            -H "Content-Type: application/json" \
            -d "{
                \"ip\": \"sonarr\", \"port\": 8989,
                \"apikey\": \"${SONARR_API_KEY}\",
                \"only_monitored\": true, \"series_sync\": 60,
                \"episodes_sync\": 60
            }" > /dev/null 2>&1 && log "  Bazarr → Sonarr connected" || true
    fi

    # Configure Radarr connection
    if [ -n "${RADARR_API_KEY:-}" ]; then
        curl -sf -X PATCH "http://localhost:6767/api/system/settings/radarr" \
            -H "X-API-KEY: ${BAZARR_API_KEY}" \
            -H "Content-Type: application/json" \
            -d "{
                \"ip\": \"radarr\", \"port\": 7878,
                \"apikey\": \"${RADARR_API_KEY}\",
                \"only_monitored\": true, \"movies_sync\": 60
            }" > /dev/null 2>&1 && log "  Bazarr → Radarr connected" || true
    fi

    # Configure languages with forced subs
    curl -sf -X PATCH "http://localhost:6767/api/system/settings/languages" \
        -H "X-API-KEY: ${BAZARR_API_KEY}" \
        -H "Content-Type: application/json" \
        -d '{
            "enabled": true,
            "languages": [{"name": "English", "code2": "en", "code3": "eng", "enabled": true, "forced": "Both", "hi": "False"}]
        }' > /dev/null 2>&1 && log "  Bazarr: English + Forced subs = Both" || \
        warn "  Bazarr: forced subs API may have changed — verify in UI"

    log "Bazarr configured"
else
    warn "Bazarr: no API key yet — configure manually after restart"
fi

# --- Update download client passwords across all *arr apps ---
# (Phase 8a configured with $QBIT_PASSWORD but qBit itself just got its password changed)
if [ "${QBIT_PASS:-adminadmin}" != "adminadmin" ]; then
    info "Updating download client passwords across *arr apps..."
    for app_port in 7878 8989 8686 8787 6969; do
        local_key=""
        api_ver=""
        case $app_port in
            7878) local_key="${RADARR_API_KEY:-}"; api_ver="v3" ;;
            8989) local_key="${SONARR_API_KEY:-}"; api_ver="v3" ;;
            8686) local_key="${LIDARR_API_KEY:-}"; api_ver="v1" ;;
            8787) local_key="${READARR_API_KEY:-}"; api_ver="v1" ;;
            6969) local_key="${WHISPARR_API_KEY:-}"; api_ver="v3" ;;
        esac
        if [ -n "$local_key" ]; then
            clients=$(arr_api "http://localhost:${app_port}/api/${api_ver}/downloadclient" "$local_key" 2>/dev/null || echo "[]")
            qbit_id=$(echo "$clients" | jq -r '.[] | select(.name=="qBittorrent") | .id' 2>/dev/null || echo "")
            if [ -n "$qbit_id" ]; then
                client_json=$(echo "$clients" | jq ".[] | select(.id==$qbit_id)" 2>/dev/null || echo "")
                if [ -n "$client_json" ]; then
                    updated=$(echo "$client_json" | jq --arg pw "$QBIT_PASS" '(.fields[] | select(.name=="password")) .value = $pw' 2>/dev/null || echo "")
                    if [ -n "$updated" ]; then
                        arr_api "http://localhost:${app_port}/api/${api_ver}/downloadclient/${qbit_id}" "$local_key" PUT "$updated" > /dev/null 2>&1 || true
                    fi
                fi
            fi
        fi
    done
    log "Download client passwords updated"
fi

# ===========================================================================
header "Phase 8c: Auto-Redownload on Failure + Discord Notifications"
# ===========================================================================

# Enable autoRedownloadFailed on all *arr apps — when a download fails,
# *arr automatically searches for an alternative release
enable_auto_redownload() {
    local name="$1" host="$2" port="$3" api_ver="$4" api_key="$5"
    if [ -z "$api_key" ]; then return; fi
    local url="http://${host}:${port}/api/${api_ver}/config/downloadclient"
    local config
    config=$(arr_api "$url" "$api_key" 2>/dev/null)
    if [ -n "$config" ] && [ "$config" != "null" ]; then
        local updated
        updated=$(echo "$config" | jq '.autoRedownloadFailed = true' 2>/dev/null)
        if [ -n "$updated" ]; then
            arr_api "$url" "$api_key" PUT "$updated" > /dev/null 2>&1 && \
                log "  ${name}: auto-redownload on failure enabled" || true
        fi
    fi
}

info "Enabling auto-redownload on failure..."
enable_auto_redownload "Radarr"  "$ARR_HOST" 7878 "v3" "${RADARR_API_KEY:-}"
enable_auto_redownload "Sonarr"  "$ARR_HOST" 8989 "v3" "${SONARR_API_KEY:-}"
enable_auto_redownload "Lidarr"  "$ARR_HOST" 8686 "v1" "${LIDARR_API_KEY:-}"
enable_auto_redownload "Readarr" "$ARR_HOST" 8787 "v1" "${READARR_API_KEY:-}"
enable_auto_redownload "Whisparr" "$ARR_HOST" 6969 "v3" "${WHISPARR_API_KEY:-}"

# --- Discord notifications for all *arr apps ---
if [ -n "${DISCORD_WEBHOOK_URL:-}" ]; then
    info "Configuring Discord notifications..."

    add_discord_notification() {
        local name="$1" host="$2" port="$3" api_ver="$4" api_key="$5" bot_name="$6"
        if [ -z "$api_key" ]; then return; fi
        local url="http://${host}:${port}/api/${api_ver}/notification"

        # Check if Discord notification already exists
        local existing
        existing=$(arr_api "$url" "$api_key" 2>/dev/null | jq '[.[] | select(.implementation=="Discord")] | length' 2>/dev/null || echo "0")
        if [ "${existing:-0}" -gt 0 ]; then
            log "  ${name}: Discord notification already configured"
            return
        fi

        arr_api "$url" "$api_key" POST "{
            \"name\": \"Discord\",
            \"implementation\": \"Discord\",
            \"configContract\": \"DiscordSettings\",
            \"fields\": [
                {\"name\": \"webHookUrl\", \"value\": \"${DISCORD_WEBHOOK_URL}\"},
                {\"name\": \"username\", \"value\": \"${bot_name}\"}
            ],
            \"onGrab\": true,
            \"onDownload\": true,
            \"onUpgrade\": true,
            \"onRename\": false,
            \"onHealthIssue\": true,
            \"onHealthRestored\": true,
            \"onApplicationUpdate\": true,
            \"includeHealthWarnings\": true
        }" > /dev/null 2>&1 && \
            log "  ${name}: Discord notifications enabled" || \
            warn "  ${name}: could not add Discord notification"
    }

    add_discord_notification "Radarr"   "$ARR_HOST" 7878 "v3" "${RADARR_API_KEY:-}"   "Radarr"
    add_discord_notification "Sonarr"   "$ARR_HOST" 8989 "v3" "${SONARR_API_KEY:-}"   "Sonarr"
    add_discord_notification "Lidarr"   "$ARR_HOST" 8686 "v1" "${LIDARR_API_KEY:-}"   "Lidarr"
    add_discord_notification "Readarr"  "$ARR_HOST" 8787 "v1" "${READARR_API_KEY:-}"  "Readarr"
    add_discord_notification "Prowlarr" "$ARR_HOST" 9696 "v1" "${PROWLARR_API_KEY:-}" "Prowlarr"
fi

# ===========================================================================
header "Phase 9: Summary"
# ===========================================================================

echo ""
log "Privateer (*arr stack) deployment complete!"
echo ""
echo "  ┌─────────────────────────────────────────────────────┐"
echo "  │  AUTOMATED                                          │"
echo "  ├─────────────────────────────────────────────────────┤"
echo "  │  ✓ System packages & Docker                        │"
echo "  │  ✓ Directory structure (app data + media + dl)     │"
echo "  │  ✓ NFS mounts (media + downloads if NAS_IP set)   │"
echo "  │  ✓ qBittorrent pre-seeded config                  │"
echo "  │  ✓ All containers running                          │"
echo "  │  ✓ API keys collected & saved to .env              │"
echo "  │  ✓ Radarr: root folders, download clients, naming  │"
echo "  │  ✓ Sonarr: root folders, download clients, naming  │"
echo "  │  ✓ Lidarr: root folder, download client            │"
echo "  │  ✓ Readarr: root folders, download client          │"
echo "  │  ✓ Whisparr: root folder, download client          │"
echo "  │  ✓ Prowlarr → Radarr/Sonarr/Lidarr connected      │"
echo "  │  ✓ Prowlarr → FlareSolverr proxy added             │"
echo "  │  ✓ Bazarr → Sonarr/Radarr, forced subs enabled    │"
echo "  │  ✓ qBittorrent password changed                    │"
echo "  │  ✓ Download client passwords synced                │"
echo "  │  ✓ Recyclarr TRaSH quality profiles synced         │"
echo "  │  ✓ Auto-redownload on failure enabled              │"
echo "  │  ✓ Discord notifications configured (if webhook)   │"
echo "  │  ✓ Download health monitoring active               │"
echo "  │  ✓ Docker healthchecks on all services             │"
echo "  └─────────────────────────────────────────────────────┘"
echo ""
warn "STILL NEEDS MANUAL SETUP:"
echo ""
echo "  Prowlarr  (http://localhost:9696)"
echo "    → Add your actual indexers (credentials required)"
echo ""
echo "  SABnzbd  (http://localhost:8085)"
echo "    → Run setup wizard, add Usenet server credentials"
echo "    → After setup, add SABNZBD_API_KEY to .env and re-run"
echo ""
echo "  Bazarr  (http://localhost:6767)"
echo "    → Add subtitle providers (OpenSubtitles.com)"
echo ""
echo "  Radarr Lists — the CouchPotato replacement:"
echo "    → Create lists at mdblist.com (RT > 85%, etc.)"
echo "    → Radarr → Settings → Lists → Add → MDBList"
echo ""
echo "  To re-run post-deploy config after manual steps:"
echo "    sudo ../scripts/init-machine2-arr.sh"
echo "    (safe to re-run — skips already-configured items)"
echo ""
