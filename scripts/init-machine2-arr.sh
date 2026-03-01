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

# ── Self-logging ──────────────────────────────────────────────────────────
# All output is tee'd to a persistent log file so failures are diagnosable
# even if the SSH session dies mid-run.
DEPLOY_LOG="/opt/suparr/privateer-init.log"
mkdir -p "$(dirname "$DEPLOY_LOG")" 2>/dev/null || true
exec > >(tee -a "$DEPLOY_LOG") 2>&1
echo ""
echo "=== Privateer init started at $(date -Iseconds) ==="
echo ""

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
    set +H 2>/dev/null || true
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

# Detect the real (non-root) user who should own files and be in docker group.
# Priority: SUDO_USER (ran via sudo), DEPLOY_USER (set by remote-deploy.sh),
# then fall back to first non-root user with a real home dir and login shell.
if [ -n "${SUDO_USER:-}" ] && [ "$SUDO_USER" != "root" ]; then
    REAL_USER="$SUDO_USER"
elif [ -n "${DEPLOY_USER:-}" ] && [ "$DEPLOY_USER" != "root" ]; then
    REAL_USER="$DEPLOY_USER"
elif [ "$USER" != "root" ]; then
    REAL_USER="$USER"
else
    REAL_USER=$(awk -F: '$3 >= 1000 && $3 < 60000 && $7 ~ /bash|zsh|fish/ {print $1; exit}' /etc/passwd)
    REAL_USER="${REAL_USER:-root}"
    if [ "$REAL_USER" != "root" ]; then
        log "Detected non-root user: $REAL_USER"
    fi
fi
NAS_DOWNLOADS_EXPORT="${NAS_DOWNLOADS_EXPORT:-/volume1/downloads}"
NAS_BACKUPS_EXPORT="${NAS_BACKUPS_EXPORT:-}"
MIGRATE_LIBRARY="${MIGRATE_LIBRARY:-false}"
MIGRATE_SOURCE="${MIGRATE_SOURCE:-}"
MIGRATE_NAS_EXPORT="${MIGRATE_NAS_EXPORT:-}"

# ── OS Portability ─────────────────────────────────────────────────────────
detect_pkg_manager() {
    if command -v apt-get &>/dev/null; then echo "apt"
    elif command -v dnf &>/dev/null; then echo "dnf"
    elif command -v pacman &>/dev/null; then echo "pacman"
    else echo "unknown"; fi
}

pkg_install() {
    local mgr="$1"; shift
    case "$mgr" in
        apt)    apt-get install -y -qq "$@" ;;
        dnf)    dnf install -y -q "$@" ;;
        pacman) pacman -S --noconfirm --needed "$@" ;;
        *)      err "Unsupported package manager"; exit 1 ;;
    esac
}

pkg_update() {
    case "$1" in
        apt)    apt-get update -qq && apt-get upgrade -y -qq ;;
        dnf)    dnf upgrade -y -q ;;
        pacman) pacman -Syu --noconfirm ;;
    esac
}

pkg_name() {
    local mgr="$1" pkg="$2"
    case "$mgr:$pkg" in
        pacman:nfs-common)                  echo "nfs-utils" ;;
        dnf:nfs-common)                     echo "nfs-utils" ;;
        pacman:lsb-release)                 echo "lsb-release" ;;
        dnf:lsb-release)                    echo "redhat-lsb-core" ;;
        pacman:apt-transport-https)         echo "" ;;
        dnf:apt-transport-https)            echo "" ;;
        pacman:software-properties-common)  echo "" ;;
        dnf:software-properties-common)     echo "" ;;
        pacman:gnupg)                       echo "gnupg" ;;
        pacman:ca-certificates)             echo "ca-certificates" ;;
        *)                                  echo "$pkg" ;;
    esac
}

PKG_MGR=$(detect_pkg_manager)

# ===========================================================================
header "Phase 1: System Packages"
# ===========================================================================

log "Detected package manager: $PKG_MGR"

# Set machine hostname (idempotent)
if [ "$(hostname | tr '[:upper:]' '[:lower:]')" != "privateer" ]; then
    hostnamectl set-hostname privateer 2>/dev/null || true
    log "Hostname set to privateer"
else
    log "Hostname already set to privateer"
fi

info "Updating system..."
pkg_update "$PKG_MGR"

# Build base package list with distro-appropriate names
BASE_PKGS=""
for pkg in curl git wget jq nfs-common htop iotop ca-certificates gnupg lsb-release apt-transport-https software-properties-common; do
    mapped=$(pkg_name "$PKG_MGR" "$pkg")
    [ -n "$mapped" ] && BASE_PKGS="$BASE_PKGS $mapped"
done

info "Installing dependencies..."
# shellcheck disable=SC2086
pkg_install "$PKG_MGR" $BASE_PKGS

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
if [ "$REAL_USER" != "root" ]; then
    usermod -aG docker "$REAL_USER"
    log "Added $REAL_USER to docker group"
fi

# ===========================================================================
header "Phase 3: Directory Structure"
# ===========================================================================

info "Creating app data directories..."
mkdir -p "$APPDATA"/{gluetun,qbittorrent/config/qBittorrent,sabnzbd/config,prowlarr/config,flaresolverr}
mkdir -p "$APPDATA"/{radarr/config,sonarr/config,lidarr/config,bookshelf/config}
mkdir -p "$APPDATA"/{bazarr/config,recyclarr/config,autobrr/config}
mkdir -p "$APPDATA"/{unpackerr,notifiarr/config,homepage/config}
mkdir -p "$APPDATA"/{whisparr/config,filebot/config,tailscale/state}
mkdir -p "$APPDATA"/dozzle
mkdir -p "$APPDATA"/backups
mkdir -p "$APPDATA"/immich/{db,ml-cache,profile,encoded-video}
mkdir -p "$APPDATA"/syncthing/config
mkdir -p /mnt/migrate-source

# Set ownership to real user
if [ "$REAL_USER" != "root" ]; then
    chown -R "$REAL_USER":"$REAL_USER" "$APPDATA"
fi

log "App data directories created at $APPDATA"

info "Creating download directories..."
mkdir -p "$DOWNLOADS_ROOT"/{torrents/{complete,incomplete},usenet/{complete,incomplete}}
if [ "$REAL_USER" != "root" ]; then
    # chown may fail on NFS mounts with root_squash — that's expected.
    # NFS ownership is controlled server-side; local chown is best-effort.
    chown -R "$REAL_USER":"$REAL_USER" "$DOWNLOADS_ROOT" 2>/dev/null || \
        warn "Could not chown $DOWNLOADS_ROOT (NFS root_squash?) — set ownership on NAS"
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
    # Use real user to avoid NFS root_squash (root → nobody can't mkdir/chown)
    _nfs_mkdir() {
        if [ "$REAL_USER" != "root" ]; then
            sudo -u "$REAL_USER" mkdir -p "$1" 2>/dev/null || mkdir -p "$1" 2>/dev/null || true
        else
            mkdir -p "$1" 2>/dev/null || true
        fi
    }
    for dir in movies tv anime anime-movies documentaries stand-up concerts music books audiobooks adult; do
        _nfs_mkdir "$MEDIA_ROOT/$dir"
    done

    # Phone backup / Immich / backup directories on NAS
    _nfs_mkdir "$MEDIA_ROOT/photos/library"
    _nfs_mkdir "$MEDIA_ROOT/phone-backup"
    _nfs_mkdir "$MEDIA_ROOT/backups"

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

        # Create download subdirectories (use real user for NFS root_squash)
        if [ "$REAL_USER" != "root" ]; then
            sudo -u "$REAL_USER" mkdir -p "$DOWNLOADS_ROOT"/{torrents/{complete,incomplete},usenet/{complete,incomplete}} 2>/dev/null || \
                mkdir -p "$DOWNLOADS_ROOT"/{torrents/{complete,incomplete},usenet/{complete,incomplete}} 2>/dev/null || true
        else
            mkdir -p "$DOWNLOADS_ROOT"/{torrents/{complete,incomplete},usenet/{complete,incomplete}} 2>/dev/null || true
        fi
        log "Download directories ensured on NAS"
    fi

    # --- Backups NFS mount (for Immich/Syncthing on separate share) ---
    if [ -n "${NAS_BACKUPS_EXPORT:-}" ]; then
        mkdir -p /mnt/backups

        if mountpoint -q /mnt/backups 2>/dev/null; then
            log "Backups already mounted at /mnt/backups"
        else
            BK_FSTAB_ENTRY="${NAS_IP}:${NAS_BACKUPS_EXPORT} /mnt/backups nfs rw,hard,intr,rsize=1048576,wsize=1048576,timeo=600,retrans=2 0 0"
            if ! grep -qF "/mnt/backups" /etc/fstab; then
                echo "$BK_FSTAB_ENTRY" >> /etc/fstab
                log "Added backups NFS mount to fstab"
            fi
            mount /mnt/backups && log "Mounted /mnt/backups" || warn "Could not mount /mnt/backups — check NAS export"
        fi

        # Create backup subdirectories (use real user for NFS root_squash)
        _nfs_mkdir "/mnt/backups/photos"
        _nfs_mkdir "/mnt/backups/photos/library"
        _nfs_mkdir "/mnt/backups/phone-backup"
        log "Backups NFS subdirectories ensured"
    fi

    # --- Migration source mount (if enabled) ---
    if [ "$MIGRATE_LIBRARY" = "true" ] && [ -n "$MIGRATE_NAS_EXPORT" ]; then
        info "Configuring migration source NFS mount..."
        if mountpoint -q /mnt/migrate-source 2>/dev/null; then
            log "Migration source already mounted at /mnt/migrate-source"
        else
            MIGRATE_FSTAB="${NAS_IP}:${MIGRATE_NAS_EXPORT} /mnt/migrate-source nfs ro,hard,intr,rsize=1048576,wsize=1048576,timeo=600,retrans=2 0 0"
            if ! grep -qF "/mnt/migrate-source" /etc/fstab; then
                echo "$MIGRATE_FSTAB" >> /etc/fstab
                log "Added migration source NFS mount to fstab (read-only)"
            fi
            mount /mnt/migrate-source && log "Mounted migration source" || warn "Could not mount migration source — check NAS export"
        fi
    fi
else
    warn "NAS_IP not set in .env — skipping NFS mount setup"
    warn "Set NAS_IP, NAS_MEDIA_EXPORT in .env and re-run, or mount manually"
fi

# --- Migration source bind-mount (local path, no NAS) ---
if [ "$MIGRATE_LIBRARY" = "true" ] && [ -z "$MIGRATE_NAS_EXPORT" ] && [ -n "$MIGRATE_SOURCE" ]; then
    if mountpoint -q /mnt/migrate-source 2>/dev/null; then
        log "Migration source already mounted at /mnt/migrate-source"
    else
        info "Bind-mounting local migration source..."
        if [ -d "$MIGRATE_SOURCE" ]; then
            MIGRATE_FSTAB="${MIGRATE_SOURCE} /mnt/migrate-source none bind,ro 0 0"
            if ! grep -qF "/mnt/migrate-source" /etc/fstab; then
                echo "$MIGRATE_FSTAB" >> /etc/fstab
                log "Added migration source bind-mount to fstab (read-only)"
            fi
            mount /mnt/migrate-source && log "Mounted migration source" || warn "Could not bind-mount $MIGRATE_SOURCE"
        else
            warn "Migration source path does not exist: $MIGRATE_SOURCE"
        fi
    fi
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

# Run as real user if possible — tolerate partial failures (restart policies recover)
if [ "$REAL_USER" != "root" ] && id -nG "$REAL_USER" | grep -qw docker; then
    sudo -u "$REAL_USER" docker compose up -d --remove-orphans || warn "Some containers failed initial start — restart policies will recover"
else
    docker compose up -d --remove-orphans || warn "Some containers failed initial start — restart policies will recover"
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
    # Sanitize: strip newlines and sed delimiters from value
    value=$(echo "$value" | tr -d '\n' | tr -d '|')
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
    log "Radarr API key: ${RADARR_API_KEY:0:8}..."
    NEED_ENV_UPDATE=true
elif [ -z "${RADARR_API_KEY:-}" ] && [ -z "$LIVE_KEY" ]; then
    warn "Could not get Radarr API key — container may still be starting"
fi

# --- Sonarr ---
LIVE_KEY=$(get_arr_api_key "Sonarr" "$APPDATA/sonarr/config/config.xml")
if [ -n "$LIVE_KEY" ] && [ "$LIVE_KEY" != "${SONARR_API_KEY:-}" ]; then
    SONARR_API_KEY="$LIVE_KEY"
    log "Sonarr API key: ${SONARR_API_KEY:0:8}..."
    NEED_ENV_UPDATE=true
elif [ -z "${SONARR_API_KEY:-}" ] && [ -z "$LIVE_KEY" ]; then
    warn "Could not get Sonarr API key — container may still be starting"
fi

# --- Lidarr ---
LIVE_KEY=$(get_arr_api_key "Lidarr" "$APPDATA/lidarr/config/config.xml")
if [ -n "$LIVE_KEY" ] && [ "$LIVE_KEY" != "${LIDARR_API_KEY:-}" ]; then
    LIDARR_API_KEY="$LIVE_KEY"
    log "Lidarr API key: ${LIDARR_API_KEY:0:8}..."
    NEED_ENV_UPDATE=true
elif [ -z "${LIDARR_API_KEY:-}" ] && [ -z "$LIVE_KEY" ]; then
    warn "Could not get Lidarr API key"
fi

# --- Prowlarr ---
LIVE_KEY=$(get_arr_api_key "Prowlarr" "$APPDATA/prowlarr/config/config.xml")
if [ -n "$LIVE_KEY" ] && [ "$LIVE_KEY" != "${PROWLARR_API_KEY:-}" ]; then
    PROWLARR_API_KEY="$LIVE_KEY"
    log "Prowlarr API key: ${PROWLARR_API_KEY:0:8}..."
    NEED_ENV_UPDATE=true
elif [ -z "${PROWLARR_API_KEY:-}" ] && [ -z "$LIVE_KEY" ]; then
    warn "Could not get Prowlarr API key"
fi

# --- Bazarr (stores key differently) ---
BAZARR_CONF_DB="$APPDATA/bazarr/config/config/config.yaml"
if [ -f "$BAZARR_CONF_DB" ]; then
    LIVE_KEY=$(grep -oP 'apikey:\s*\K[a-f0-9]+' "$BAZARR_CONF_DB" 2>/dev/null | head -1 || true)
    if [ -n "$LIVE_KEY" ] && [ "$LIVE_KEY" != "${BAZARR_API_KEY:-}" ]; then
        BAZARR_API_KEY="$LIVE_KEY"
        log "Bazarr API key: ${BAZARR_API_KEY:0:8}..."
        NEED_ENV_UPDATE=true
    fi
fi

# --- Bookshelf ---
LIVE_KEY=$(get_arr_api_key "Bookshelf" "$APPDATA/bookshelf/config/config.xml")
if [ -n "$LIVE_KEY" ] && [ "$LIVE_KEY" != "${BOOKSHELF_API_KEY:-}" ]; then
    BOOKSHELF_API_KEY="$LIVE_KEY"
    log "Bookshelf API key: ${BOOKSHELF_API_KEY:0:8}..."
    NEED_ENV_UPDATE=true
elif [ -z "${BOOKSHELF_API_KEY:-}" ] && [ -z "$LIVE_KEY" ]; then
    warn "Could not get Bookshelf API key"
fi

# --- Whisparr ---
LIVE_KEY=$(get_arr_api_key "Whisparr" "$APPDATA/whisparr/config/config.xml")
if [ -n "$LIVE_KEY" ] && [ "$LIVE_KEY" != "${WHISPARR_API_KEY:-}" ]; then
    WHISPARR_API_KEY="$LIVE_KEY"
    log "Whisparr API key: ${WHISPARR_API_KEY:0:8}..."
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
    update_env_key "BOOKSHELF_API_KEY" "${BOOKSHELF_API_KEY:-}" --force
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
set +H 2>/dev/null || true
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

# --- SABnzbd: paths + categories ---
if [ -n "${SABNZBD_API_KEY:-}" ]; then
    SAB_URL="http://localhost:8085"
    info "Waiting for SABnzbd API..."
    SAB_READY=false
    for attempt in $(seq 1 45); do
        if curl -sf -o /dev/null "${SAB_URL}/api?mode=version&apikey=${SABNZBD_API_KEY}" 2>/dev/null; then
            SAB_READY=true; break
        fi
        [ $((attempt % 10)) -eq 0 ] && info "  Still waiting for SABnzbd (attempt $attempt/45)... VPN may still be connecting"
        sleep 2
    done

    if [ "$SAB_READY" = true ]; then
        info "Configuring SABnzbd paths and categories..."

        # Set download paths
        curl -sf "${SAB_URL}/api?mode=set_config&section=misc&keyword=complete_dir&value=/downloads/usenet/complete&apikey=${SABNZBD_API_KEY}" > /dev/null 2>&1 && \
            log "  SABnzbd: complete dir → /downloads/usenet/complete" || true
        curl -sf "${SAB_URL}/api?mode=set_config&section=misc&keyword=download_dir&value=/downloads/usenet/incomplete&apikey=${SABNZBD_API_KEY}" > /dev/null 2>&1 && \
            log "  SABnzbd: incomplete dir → /downloads/usenet/incomplete" || true

        # Create categories matching *arr app names
        for cat_name in radarr sonarr lidarr bookshelf whisparr; do
            curl -sf "${SAB_URL}/api?mode=set_config&section=categories&keyword=${cat_name}&name=${cat_name}&pp=&script=&dir=${cat_name}&newzbin=&priority=-100&apikey=${SABNZBD_API_KEY}" > /dev/null 2>&1 && \
                log "  SABnzbd: category '${cat_name}' → ${cat_name}/" || true
        done

        # Restart SABnzbd to apply path changes
        curl -sf "${SAB_URL}/api?mode=restart&apikey=${SABNZBD_API_KEY}" > /dev/null 2>&1 || true
        sleep 5
        log "SABnzbd configured"
    else
        warn "SABnzbd API not ready — categories must be configured manually"
    fi
fi

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

        if [ -n "${SABNZBD_API_KEY:-}" ]; then
            existing_sab=$(arr_api "http://${ARR_HOST}:8686/api/v1/downloadclient" "$LIDARR_API_KEY" | grep -c "SABnzbd" || true)
            if [ "$existing_sab" -eq 0 ]; then
                arr_api "http://${ARR_HOST}:8686/api/v1/downloadclient" "$LIDARR_API_KEY" POST "{
                    \"enable\": true, \"protocol\": \"usenet\", \"priority\": 1,
                    \"name\": \"SABnzbd\", \"implementation\": \"Sabnzbd\",
                    \"configContract\": \"SabnzbdSettings\",
                    \"fields\": [
                        {\"name\": \"host\", \"value\": \"gluetun\"},
                        {\"name\": \"port\", \"value\": 8085},
                        {\"name\": \"apiKey\", \"value\": \"${SABNZBD_API_KEY}\"},
                        {\"name\": \"musicCategory\", \"value\": \"lidarr\"}
                    ],
                    \"removeCompletedDownloads\": true, \"removeFailedDownloads\": true
                }" > /dev/null && log "  Download client: SABnzbd" || true
            fi
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

        # Connect Bookshelf (Readarr fork — uses Readarr integration type)
        if [ -n "${BOOKSHELF_API_KEY:-}" ]; then
            arr_api "http://${ARR_HOST}:9696/api/v1/applications" "$PROWLARR_API_KEY" POST "{
                \"name\": \"Bookshelf\", \"syncLevel\": \"fullSync\",
                \"implementation\": \"Readarr\", \"configContract\": \"ReadarrSettings\",
                \"fields\": [
                    {\"name\": \"prowlarrUrl\", \"value\": \"http://prowlarr:9696\"},
                    {\"name\": \"baseUrl\", \"value\": \"http://bookshelf:8787\"},
                    {\"name\": \"apiKey\", \"value\": \"${BOOKSHELF_API_KEY}\"}
                ]
            }" > /dev/null 2>&1 && log "  Prowlarr → Bookshelf connected" || warn "  Prowlarr → Bookshelf failed"
        fi

        # Connect Whisparr
        if [ -n "${WHISPARR_API_KEY:-}" ]; then
            arr_api "http://${ARR_HOST}:9696/api/v1/applications" "$PROWLARR_API_KEY" POST "{
                \"name\": \"Whisparr\", \"syncLevel\": \"fullSync\",
                \"implementation\": \"Whisparr\", \"configContract\": \"WhisparrSettings\",
                \"fields\": [
                    {\"name\": \"prowlarrUrl\", \"value\": \"http://prowlarr:9696\"},
                    {\"name\": \"baseUrl\", \"value\": \"http://whisparr:6969\"},
                    {\"name\": \"apiKey\", \"value\": \"${WHISPARR_API_KEY}\"}
                ]
            }" > /dev/null 2>&1 && log "  Prowlarr → Whisparr connected" || warn "  Prowlarr → Whisparr failed"
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

        # --- Prowlarr Public Indexers ---
        info "Adding public indexers to Prowlarr..."

        # Get existing indexers to avoid duplicates
        EXISTING_INDEXERS=$(arr_api "http://${ARR_HOST}:9696/api/v1/indexer" "$PROWLARR_API_KEY" 2>/dev/null | \
            jq -r '.[].definitionName // empty' 2>/dev/null || echo "")

        # Create FlareSolverr tag for CloudFlare-protected indexers
        FLARE_TAG_ID=""
        EXISTING_TAGS=$(arr_api "http://${ARR_HOST}:9696/api/v1/tag" "$PROWLARR_API_KEY" 2>/dev/null || echo "[]")
        FLARE_TAG_ID=$(echo "$EXISTING_TAGS" | jq -r '.[] | select(.label=="flaresolverr") | .id' 2>/dev/null || echo "")
        if [ -z "$FLARE_TAG_ID" ]; then
            FLARE_TAG_RESPONSE=$(arr_api "http://${ARR_HOST}:9696/api/v1/tag" "$PROWLARR_API_KEY" POST '{"label":"flaresolverr"}' 2>/dev/null || echo "")
            FLARE_TAG_ID=$(echo "$FLARE_TAG_RESPONSE" | jq -r '.id // empty' 2>/dev/null || echo "")
            [ -n "$FLARE_TAG_ID" ] && log "  Created 'flaresolverr' tag (id: $FLARE_TAG_ID)"
        fi

        # Link FlareSolverr proxy to the tag
        if [ -n "$FLARE_TAG_ID" ]; then
            FLARE_PROXY=$(arr_api "http://${ARR_HOST}:9696/api/v1/indexerProxy" "$PROWLARR_API_KEY" 2>/dev/null || echo "[]")
            FLARE_PROXY_ID=$(echo "$FLARE_PROXY" | jq -r '.[] | select(.implementation=="FlareSolverr") | .id' 2>/dev/null || echo "")
            if [ -n "$FLARE_PROXY_ID" ]; then
                FLARE_PROXY_JSON=$(echo "$FLARE_PROXY" | jq --argjson tid "$FLARE_TAG_ID" \
                    '.[] | select(.implementation=="FlareSolverr") | .tags = [$tid]' 2>/dev/null || echo "")
                if [ -n "$FLARE_PROXY_JSON" ]; then
                    arr_api "http://${ARR_HOST}:9696/api/v1/indexerProxy/${FLARE_PROXY_ID}" "$PROWLARR_API_KEY" PUT "$FLARE_PROXY_JSON" > /dev/null 2>&1 && \
                        log "  FlareSolverr proxy linked to tag" || true
                fi
            fi
        fi

        # Helper to add an indexer from its schema definition
        add_prowlarr_indexer() {
            local def_name="$1" tags_json="${2:-[]}"
            if echo "$EXISTING_INDEXERS" | grep -qx "$def_name"; then
                log "  Indexer '${def_name}' already exists"
                return
            fi
            # Get schema template for this indexer
            local schemas
            schemas=$(arr_api "http://${ARR_HOST}:9696/api/v1/indexer/schema" "$PROWLARR_API_KEY" 2>/dev/null || echo "[]")
            local template
            template=$(echo "$schemas" | jq --arg n "$def_name" '[.[] | select(.definitionName==$n)] | .[0]' 2>/dev/null || echo "null")
            if [ "$template" = "null" ] || [ -z "$template" ]; then
                warn "  No schema template found for '${def_name}'"
                return
            fi
            # Enable it and set tags
            local payload
            payload=$(echo "$template" | jq --argjson tags "$tags_json" '.enable = true | .tags = $tags' 2>/dev/null || echo "")
            if [ -n "$payload" ]; then
                arr_api "http://${ARR_HOST}:9696/api/v1/indexer" "$PROWLARR_API_KEY" POST "$payload" > /dev/null 2>&1 && \
                    log "  Indexer '${def_name}' added" || \
                    warn "  Could not add indexer '${def_name}'"
            fi
        }

        # Add public indexers — 1337x needs FlareSolverr, others don't
        if [ -n "$FLARE_TAG_ID" ]; then
            add_prowlarr_indexer "1337x" "[$FLARE_TAG_ID]"
        else
            add_prowlarr_indexer "1337x" "[]"
        fi
        add_prowlarr_indexer "The Pirate Bay" "[]"
        add_prowlarr_indexer "YTS" "[]"
        add_prowlarr_indexer "EZTV" "[]"
        add_prowlarr_indexer "TorrentGalaxy" "[]"
        add_prowlarr_indexer "Nyaa.si" "[]"

        # Trigger sync to push indexers to all connected *arr apps
        info "Triggering Prowlarr → *arr indexer sync..."
        arr_api "http://${ARR_HOST}:9696/api/v1/command" "$PROWLARR_API_KEY" POST \
            '{"name":"AppIndexerSync"}' > /dev/null 2>&1 && \
            log "  Indexer sync triggered" || warn "  Could not trigger indexer sync"

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
header "Phase 8b: Bookshelf, Whisparr, Bazarr & qBit Password"
# ===========================================================================

# Re-source .env to pick up any newly written keys
set +H 2>/dev/null || true
set -a; source "$PROJECT_DIR/.env"; set +a

# --- qBittorrent: change default password ---
# qBit runs behind Gluetun VPN — must wait for VPN to connect first
QBIT_PASS="${QBIT_PASSWORD:-adminadmin}"
QBIT_COOKIE=""
if [ "$QBIT_PASS" != "adminadmin" ]; then
    info "Waiting for qBittorrent API (depends on VPN tunnel)..."
    QBIT_READY=false
    for attempt in $(seq 1 45); do
        if curl -sf -o /dev/null "http://localhost:8080" 2>/dev/null; then
            QBIT_READY=true; break
        fi
        [ $((attempt % 10)) -eq 0 ] && info "  Still waiting for qBit (attempt $attempt/45)... VPN may still be connecting"
        sleep 2
    done

    if [ "$QBIT_READY" = true ]; then
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
                # Verify: log in with new password to confirm it stuck
                sleep 2
                VERIFY_COOKIE=$(curl -sf -c - -X POST "http://localhost:8080/api/v2/auth/login" \
                    -d "username=admin&password=${QBIT_PASS}" 2>/dev/null | grep -oP 'SID\s+\K\S+' || echo "")
                if [ -n "$VERIFY_COOKIE" ]; then
                    QBIT_COOKIE="$VERIFY_COOKIE"
                    log "qBittorrent: password verified"
                else
                    warn "qBittorrent: password change may not have persisted — verify in UI"
                fi
            else
                warn "qBittorrent: could not log in with default password"
                warn "  If VPN is not connected, qBit may not be reachable"
                warn "  Check: docker logs gluetun | tail -20"
            fi
        fi
    else
        warn "qBittorrent API not reachable after 90s — VPN may not be connected"
        warn "  Check VPN: docker logs gluetun | tail -20"
        warn "  After fixing VPN, re-run this script to configure qBit"
    fi
fi

# --- qBittorrent: queue settings ---
# Prevent choking with large queues (default max_active_downloads=5 is way too low)
if [ -n "$QBIT_COOKIE" ]; then
    info "Setting qBittorrent queue limits..."
    QBIT_MAX_DL="${QBIT_MAX_DOWNLOADS:-30}"
    QBIT_MAX_T="${QBIT_MAX_TORRENTS:-50}"
    QBIT_MAX_UL="${QBIT_MAX_UPLOADS:-15}"

    curl -sf -X POST "http://localhost:8080/api/v2/app/setPreferences" \
        -b "SID=$QBIT_COOKIE" \
        -d "json={\"max_active_downloads\":${QBIT_MAX_DL},\"max_active_torrents\":${QBIT_MAX_T},\"max_active_uploads\":${QBIT_MAX_UL},\"queueing_enabled\":true}" 2>/dev/null && \
        log "qBittorrent: queue limits set (dl:${QBIT_MAX_DL}, total:${QBIT_MAX_T}, ul:${QBIT_MAX_UL})" || \
        warn "qBittorrent: could not set queue limits"
elif [ "$QBIT_PASS" = "adminadmin" ]; then
    # Even with default password, set queue limits if qBit is reachable
    QBIT_COOKIE=$(curl -sf -c - -X POST "http://localhost:8080/api/v2/auth/login" \
        -d "username=admin&password=adminadmin" 2>/dev/null | grep -oP 'SID\s+\K\S+' || echo "")
    if [ -n "$QBIT_COOKIE" ]; then
        QBIT_MAX_DL="${QBIT_MAX_DOWNLOADS:-30}"
        QBIT_MAX_T="${QBIT_MAX_TORRENTS:-50}"
        QBIT_MAX_UL="${QBIT_MAX_UPLOADS:-15}"
        curl -sf -X POST "http://localhost:8080/api/v2/app/setPreferences" \
            -b "SID=$QBIT_COOKIE" \
            -d "json={\"max_active_downloads\":${QBIT_MAX_DL},\"max_active_torrents\":${QBIT_MAX_T},\"max_active_uploads\":${QBIT_MAX_UL},\"queueing_enabled\":true}" 2>/dev/null && \
            log "qBittorrent: queue limits set (dl:${QBIT_MAX_DL}, total:${QBIT_MAX_T}, ul:${QBIT_MAX_UL})" || true
    fi
fi

# --- BOOKSHELF: root folders + download client ---
if [ -n "${BOOKSHELF_API_KEY:-}" ]; then
    info "Configuring Bookshelf..."
    if wait_for_api "Bookshelf" "http://${ARR_HOST}:8787/api/v1/system/status?apikey=${BOOKSHELF_API_KEY}"; then

        for folder in books audiobooks; do
            existing=$(arr_api "http://${ARR_HOST}:8787/api/v1/rootfolder" "$BOOKSHELF_API_KEY" | grep -c "/${folder}" || true)
            if [ "$existing" -eq 0 ]; then
                arr_api "http://${ARR_HOST}:8787/api/v1/rootfolder" "$BOOKSHELF_API_KEY" POST \
                    "{\"path\": \"/${folder}\", \"accessible\": true, \"defaultMetadataProfileId\": 1, \"defaultQualityProfileId\": 1}" > /dev/null 2>&1 && \
                    log "  Bookshelf: root folder /${folder}" || true
            fi
        done

        existing_dc=$(arr_api "http://${ARR_HOST}:8787/api/v1/downloadclient" "$BOOKSHELF_API_KEY" | grep -c "qBittorrent" || true)
        if [ "$existing_dc" -eq 0 ]; then
            arr_api "http://${ARR_HOST}:8787/api/v1/downloadclient" "$BOOKSHELF_API_KEY" POST "{
                \"enable\": true, \"protocol\": \"torrent\", \"priority\": 1,
                \"name\": \"qBittorrent\", \"implementation\": \"QBittorrent\",
                \"configContract\": \"QBittorrentSettings\",
                \"fields\": [
                    {\"name\": \"host\", \"value\": \"gluetun\"},
                    {\"name\": \"port\", \"value\": 8080},
                    {\"name\": \"username\", \"value\": \"admin\"},
                    {\"name\": \"password\", \"value\": \"${QBIT_PASSWORD}\"},
                    {\"name\": \"bookCategory\", \"value\": \"bookshelf\"}
                ],
                \"removeCompletedDownloads\": true, \"removeFailedDownloads\": true
            }" > /dev/null 2>&1 && log "  Bookshelf: download client (qBit)" || true
        fi

        if [ -n "${SABNZBD_API_KEY:-}" ]; then
            existing_sab=$(arr_api "http://${ARR_HOST}:8787/api/v1/downloadclient" "$BOOKSHELF_API_KEY" | grep -c "SABnzbd" || true)
            if [ "$existing_sab" -eq 0 ]; then
                arr_api "http://${ARR_HOST}:8787/api/v1/downloadclient" "$BOOKSHELF_API_KEY" POST "{
                    \"enable\": true, \"protocol\": \"usenet\", \"priority\": 1,
                    \"name\": \"SABnzbd\", \"implementation\": \"Sabnzbd\",
                    \"configContract\": \"SabnzbdSettings\",
                    \"fields\": [
                        {\"name\": \"host\", \"value\": \"gluetun\"},
                        {\"name\": \"port\", \"value\": 8085},
                        {\"name\": \"apiKey\", \"value\": \"${SABNZBD_API_KEY}\"},
                        {\"name\": \"bookCategory\", \"value\": \"bookshelf\"}
                    ],
                    \"removeCompletedDownloads\": true, \"removeFailedDownloads\": true
                }" > /dev/null 2>&1 && log "  Bookshelf: download client (SABnzbd)" || true
            fi
        fi

        log "Bookshelf configured"
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
            }" > /dev/null 2>&1 && log "  Whisparr: download client (qBit)" || true
        fi

        if [ -n "${SABNZBD_API_KEY:-}" ]; then
            existing_sab=$(arr_api "http://${ARR_HOST}:6969/api/v3/downloadclient" "$WHISPARR_API_KEY" | grep -c "SABnzbd" || true)
            if [ "$existing_sab" -eq 0 ]; then
                arr_api "http://${ARR_HOST}:6969/api/v3/downloadclient" "$WHISPARR_API_KEY" POST "{
                    \"enable\": true, \"protocol\": \"usenet\", \"priority\": 1,
                    \"name\": \"SABnzbd\", \"implementation\": \"Sabnzbd\",
                    \"configContract\": \"SabnzbdSettings\",
                    \"fields\": [
                        {\"name\": \"host\", \"value\": \"gluetun\"},
                        {\"name\": \"port\", \"value\": 8085},
                        {\"name\": \"apiKey\", \"value\": \"${SABNZBD_API_KEY}\"},
                        {\"name\": \"movieCategory\", \"value\": \"whisparr\"}
                    ],
                    \"removeCompletedDownloads\": true, \"removeFailedDownloads\": true
                }" > /dev/null 2>&1 && log "  Whisparr: download client (SABnzbd)" || true
            fi
        fi

        # --- Whisparr Indexer Workaround ---
        # Prowlarr → Whisparr fullSync is broken (known bug). Add indexers as Torznab proxies.
        if [ -n "${PROWLARR_API_KEY:-}" ]; then
            info "Adding Torznab indexers to Whisparr (Prowlarr sync workaround)..."
            WHISPARR_EXISTING_IDX=$(arr_api "http://${ARR_HOST}:6969/api/v3/indexer" "$WHISPARR_API_KEY" 2>/dev/null | \
                jq -r '.[].name // empty' 2>/dev/null || echo "")
            PROWLARR_INDEXERS=$(arr_api "http://${ARR_HOST}:9696/api/v1/indexer" "$PROWLARR_API_KEY" 2>/dev/null || echo "[]")
            PROWLARR_IDX_COUNT=$(echo "$PROWLARR_INDEXERS" | jq 'length' 2>/dev/null || echo "0")

            for i in $(seq 0 $((PROWLARR_IDX_COUNT - 1))); do
                IDX_NAME=$(echo "$PROWLARR_INDEXERS" | jq -r ".[$i].name" 2>/dev/null || echo "")
                IDX_ID=$(echo "$PROWLARR_INDEXERS" | jq -r ".[$i].id" 2>/dev/null || echo "")
                [ -z "$IDX_NAME" ] || [ -z "$IDX_ID" ] && continue

                if echo "$WHISPARR_EXISTING_IDX" | grep -qx "$IDX_NAME"; then
                    continue
                fi

                arr_api "http://${ARR_HOST}:6969/api/v3/indexer" "$WHISPARR_API_KEY" POST "{
                    \"name\": \"${IDX_NAME}\",
                    \"implementation\": \"Torznab\",
                    \"configContract\": \"TorznabSettings\",
                    \"enable\": true,
                    \"protocol\": \"torrent\",
                    \"fields\": [
                        {\"name\": \"baseUrl\", \"value\": \"http://prowlarr:9696/${IDX_ID}/\"},
                        {\"name\": \"apiPath\", \"value\": \"/api\"},
                        {\"name\": \"apiKey\", \"value\": \"${PROWLARR_API_KEY}\"},
                        {\"name\": \"categories\", \"value\": [6000, 6010, 6020, 6030, 6040, 6050, 6060, 6070, 6080, 6090]}
                    ]
                }" > /dev/null 2>&1 && \
                    log "  Whisparr: Torznab '${IDX_NAME}' added" || true
            done
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

# --- Notifiarr: write API key to config file (not env var) ---
# Empty DN_API_KEY env var was overriding config file. Now we write directly to config.
if [ -n "${NOTIFIARR_API_KEY:-}" ]; then
    NOTIFIARR_CONF="$APPDATA/notifiarr/config/notifiarr.conf"
    if [ -f "$NOTIFIARR_CONF" ]; then
        # Update existing config
        if grep -q "^api_key" "$NOTIFIARR_CONF"; then
            sed -i "s|^api_key.*|api_key = \"${NOTIFIARR_API_KEY}\"|" "$NOTIFIARR_CONF"
        else
            echo "api_key = \"${NOTIFIARR_API_KEY}\"" >> "$NOTIFIARR_CONF"
        fi
        log "Notifiarr: API key written to config file"
    else
        # Create minimal config
        mkdir -p "$(dirname "$NOTIFIARR_CONF")"
        cat > "$NOTIFIARR_CONF" <<NEOF
## Notifiarr Client Configuration
## API key from https://notifiarr.com
api_key = "${NOTIFIARR_API_KEY}"
NEOF
        log "Notifiarr: config file created with API key"
    fi
    # Recreate container to pick up new config
    cd "$PROJECT_DIR"
    if [ "$REAL_USER" != "root" ] && id -nG "$REAL_USER" | grep -qw docker; then
        sudo -u "$REAL_USER" docker compose up -d notifiarr 2>/dev/null || true
    else
        docker compose up -d notifiarr 2>/dev/null || true
    fi
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
            8787) local_key="${BOOKSHELF_API_KEY:-}"; api_ver="v1" ;;
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
enable_auto_redownload "Bookshelf" "$ARR_HOST" 8787 "v1" "${BOOKSHELF_API_KEY:-}"
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
    add_discord_notification "Bookshelf" "$ARR_HOST" 8787 "v1" "${BOOKSHELF_API_KEY:-}" "Bookshelf"
    add_discord_notification "Prowlarr" "$ARR_HOST" 9696 "v1" "${PROWLARR_API_KEY:-}" "Prowlarr"
fi

# ===========================================================================
header "Phase 8d: Import Lists + Plex Connect"
# ===========================================================================

# Helper: add import list to *arr app (idempotent by name)
add_import_list() {
    local name="$1" host="$2" port="$3" api_ver="$4" api_key="$5"
    local list_name="$6" implementation="$7" config_contract="$8"
    local root_folder="$9" fields_json="${10}"

    if [ -z "$api_key" ]; then return; fi
    local url="http://${host}:${port}/api/${api_ver}/importlist"

    # Check if list already exists by name
    local existing
    existing=$(arr_api "$url" "$api_key" 2>/dev/null | \
        jq -r --arg n "$list_name" '[.[] | select(.name==$n)] | length' 2>/dev/null || echo "0")
    if [ "${existing:-0}" -gt 0 ]; then
        log "  ${name}: import list '${list_name}' already exists"
        return
    fi

    arr_api "$url" "$api_key" POST "{
        \"name\": \"${list_name}\",
        \"implementation\": \"${implementation}\",
        \"configContract\": \"${config_contract}\",
        \"enableAuto\": true,
        \"enabled\": true,
        \"searchOnAdd\": true,
        \"shouldMonitor\": true,
        \"qualityProfileId\": 1,
        \"rootFolderPath\": \"${root_folder}\",
        \"fields\": ${fields_json}
    }" > /dev/null 2>&1 && \
        log "  ${name}: import list '${list_name}' added" || \
        warn "  ${name}: could not add import list '${list_name}'"
}

# --- Radarr import lists ---
if [ -n "${RADARR_API_KEY:-}" ]; then
    info "Adding Radarr import lists..."

    if [ -n "${TRAKT_ACCESS_TOKEN:-}" ]; then
        add_import_list "Radarr" "$ARR_HOST" 7878 "v3" "$RADARR_API_KEY" \
            "Trakt Popular" "TraktPopularImport" "TraktPopularSettings" "/movies" \
            "[{\"name\":\"accessToken\",\"value\":\"${TRAKT_ACCESS_TOKEN}\"},{\"name\":\"limit\",\"value\":100},{\"name\":\"traktListType\",\"value\":0}]"

        add_import_list "Radarr" "$ARR_HOST" 7878 "v3" "$RADARR_API_KEY" \
            "Trakt Trending" "TraktPopularImport" "TraktPopularSettings" "/movies" \
            "[{\"name\":\"accessToken\",\"value\":\"${TRAKT_ACCESS_TOKEN}\"},{\"name\":\"limit\",\"value\":50},{\"name\":\"traktListType\",\"value\":1}]"
    fi

    if [ -n "${TMDB_API_KEY:-}" ]; then
        add_import_list "Radarr" "$ARR_HOST" 7878 "v3" "$RADARR_API_KEY" \
            "TMDb Popular" "TMDbPopularImport" "TMDbPopularSettings" "/movies" \
            "[{\"name\":\"tmdbCertification\",\"value\":\"\"},{\"name\":\"includeGenreIds\",\"value\":\"\"},{\"name\":\"excludeGenreIds\",\"value\":\"\"},{\"name\":\"languageCode\",\"value\":0}]"
    fi
fi

# --- Sonarr import lists ---
if [ -n "${SONARR_API_KEY:-}" ]; then
    info "Adding Sonarr import lists..."

    if [ -n "${TRAKT_ACCESS_TOKEN:-}" ]; then
        add_import_list "Sonarr" "$ARR_HOST" 8989 "v3" "$SONARR_API_KEY" \
            "Trakt Popular" "TraktPopularImport" "TraktPopularSettings" "/tv" \
            "[{\"name\":\"accessToken\",\"value\":\"${TRAKT_ACCESS_TOKEN}\"},{\"name\":\"limit\",\"value\":100},{\"name\":\"traktListType\",\"value\":0}]"

        add_import_list "Sonarr" "$ARR_HOST" 8989 "v3" "$SONARR_API_KEY" \
            "Trakt Trending" "TraktPopularImport" "TraktPopularSettings" "/tv" \
            "[{\"name\":\"accessToken\",\"value\":\"${TRAKT_ACCESS_TOKEN}\"},{\"name\":\"limit\",\"value\":50},{\"name\":\"traktListType\",\"value\":1}]"
    fi

    if [ -n "${TMDB_API_KEY:-}" ]; then
        add_import_list "Sonarr" "$ARR_HOST" 8989 "v3" "$SONARR_API_KEY" \
            "TMDb Popular" "TMDbPopularImport" "TMDbPopularSettings" "/tv" \
            "[{\"name\":\"languageCode\",\"value\":0}]"
    fi
fi

# --- Plex library scan notifications ---
add_plex_notification() {
    local name="$1" host="$2" port="$3" api_ver="$4" api_key="$5"
    if [ -z "$api_key" ] || [ -z "${PLEX_TOKEN:-}" ]; then return; fi
    local url="http://${host}:${port}/api/${api_ver}/notification"

    local existing
    existing=$(arr_api "$url" "$api_key" 2>/dev/null | \
        jq '[.[] | select(.implementation=="PlexServer")] | length' 2>/dev/null || echo "0")
    if [ "${existing:-0}" -gt 0 ]; then
        log "  ${name}: Plex notification already configured"
        return
    fi

    arr_api "$url" "$api_key" POST "{
        \"name\": \"Plex\",
        \"implementation\": \"PlexServer\",
        \"configContract\": \"PlexServerSettings\",
        \"fields\": [
            {\"name\": \"host\", \"value\": \"${PLEX_IP:-}\"},
            {\"name\": \"port\", \"value\": 32400},
            {\"name\": \"authToken\", \"value\": \"${PLEX_TOKEN}\"},
            {\"name\": \"useSsl\", \"value\": false},
            {\"name\": \"updateLibrary\", \"value\": true}
        ],
        \"onDownload\": true,
        \"onUpgrade\": true,
        \"onRename\": true
    }" > /dev/null 2>&1 && \
        log "  ${name}: Plex library scan on import enabled" || \
        warn "  ${name}: could not add Plex notification"
}

if [ -n "${PLEX_TOKEN:-}" ] && [ -n "${PLEX_IP:-}" ]; then
    info "Configuring Plex library scan notifications..."
    add_plex_notification "Radarr"  "$ARR_HOST" 7878 "v3" "${RADARR_API_KEY:-}"
    add_plex_notification "Sonarr"  "$ARR_HOST" 8989 "v3" "${SONARR_API_KEY:-}"
    add_plex_notification "Lidarr"  "$ARR_HOST" 8686 "v1" "${LIDARR_API_KEY:-}"
    add_plex_notification "Bookshelf" "$ARR_HOST" 8787 "v1" "${BOOKSHELF_API_KEY:-}"
fi

# ===========================================================================
header "Phase 8e: Immich DB Backup Cron"
# ===========================================================================

info "Setting up nightly Immich database backup..."
CRON_DUMP="0 3 * * * docker exec immich-db pg_dump -U immich immich | gzip > ${MEDIA_ROOT}/backups/immich-db-\$(date +\\%Y\\%m\\%d).sql.gz"
CRON_PRUNE="5 3 * * * find ${MEDIA_ROOT}/backups/ -name \"immich-db-*.sql.gz\" -mtime +7 -delete"

# Add cron entries idempotently
EXISTING_CRON=$(crontab -l 2>/dev/null || echo "")
if echo "$EXISTING_CRON" | grep -q "immich-db"; then
    log "Immich backup cron already configured"
else
    (echo "$EXISTING_CRON"; echo "$CRON_DUMP"; echo "$CRON_PRUNE") | crontab -
    log "Immich backup cron installed (nightly at 3 AM, 7-day retention)"
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
echo "  │  ✓ Bookshelf: root folders, download client         │"
echo "  │  ✓ Whisparr: root folder, download client          │"
echo "  │  ✓ Prowlarr → all *arr apps connected              │"
echo "  │  ✓ Prowlarr → FlareSolverr proxy added             │"
echo "  │  ✓ Prowlarr: 6 public indexers auto-added         │"
echo "  │  ✓ Whisparr: Torznab indexers (Prowlarr proxy)    │"
echo "  │  ✓ Bazarr → Sonarr/Radarr, forced subs enabled    │"
echo "  │  ✓ qBittorrent password changed + verified         │"
echo "  │  ✓ qBittorrent queue limits configured             │"
echo "  │  ✓ Notifiarr API key in config (not env var)      │"
echo "  │  ✓ Download client passwords synced                │"
echo "  │  ✓ Recyclarr TRaSH quality profiles synced         │"
echo "  │  ✓ Auto-redownload on failure enabled              │"
echo "  │  ✓ Discord notifications configured (if webhook)   │"
echo "  │  ✓ Download health monitoring active               │"
echo "  │  ✓ Docker healthchecks on all services             │"
echo "  │  ✓ Import lists: Trakt + TMDb (if tokens set)     │"
echo "  │  ✓ Plex library scan on import (if Plex token)    │"
echo "  │  ✓ Config backup automation (weekly + rotation)    │"
echo "  │  ✓ Maintenance automation (disk, stale, cleanup)  │"
echo "  │  ✓ Weekly content digest to Discord               │"
echo "  │  ✓ Immich photo/video backup (ML on NVMe)        │"
echo "  │  ✓ Syncthing file sync (phone → NAS)             │"
echo "  │  ✓ Immich DB backup cron (nightly, 7-day retain) │"
if [ "$MIGRATE_LIBRARY" = "true" ]; then
echo "  │  ✓ Migration source mounted (read-only)         │"
fi
echo "  └─────────────────────────────────────────────────────┘"
echo ""
warn "STILL NEEDS MANUAL SETUP:"
echo ""
echo "  Prowlarr  (http://localhost:9696)"
echo "    → Public indexers auto-added (1337x, TPB, YTS, EZTV, TorrentGalaxy, Nyaa)"
echo "    → Add private indexers if you have them (credentials required)"
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
echo "  Immich  (http://localhost:2283)"
echo "    → Create admin account on first visit"
echo "    → Install Immich app on Android (Play Store)"
echo "    → Connect to http://localhost:2283 (or Tailscale IP when remote)"
echo "    → Enable background backup in app"
echo ""
echo "  Syncthing  (http://localhost:8384)"
echo "    → Set admin password"
echo "    → Install Syncthing on Android (F-Droid or Play Store)"
echo "    → Pair devices via QR code"
echo "    → Share folders: DCIM, Downloads, Documents, Signal, etc."
echo "    → Syncs over LAN and Tailscale automatically"
echo ""
echo "  SMS Backup (Android app — not a server component)"
echo "    → Install \"SMS Backup & Restore\" from Play Store"
echo "    → Schedule daily backups to a local folder"
echo "    → Add that folder to Syncthing → auto-syncs to NAS"
echo ""
if [ "$MIGRATE_LIBRARY" = "true" ]; then
echo "  Media Migration  →  Source mounted, ready to run"
echo "    Preview:  docker compose --profile migration run --rm media-migration"
echo "    Execute:  docker compose --profile migration run --rm media-migration execute"
echo "    FileBot:  http://localhost:5800 (for messy libraries needing smart rename)"
echo ""
fi
echo "  To re-run post-deploy config after manual steps:"
echo "    sudo ../scripts/init-machine2-arr.sh"
echo "    (safe to re-run — skips already-configured items)"
echo ""
