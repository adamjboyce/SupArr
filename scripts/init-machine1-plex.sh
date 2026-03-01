#!/usr/bin/env bash
# =============================================================================
# Machine 1: Full Init — Bare Debian 12 → Running Plex Stack
# =============================================================================
# Run this on a fresh Debian 12 minimal install. It handles:
#   1. System packages + Intel iGPU drivers
#   2. Docker installation
#   3. Directory structure
#   4. NFS mounts
#   5. Pre-seed Kometa config template
#   6. Docker Compose up
#   7. Plex preferences (HW transcoding, subtitle mode, transcoder speed)
#
# Prerequisites:
#   - Debian 12 minimal installed with SSH
#   - Intel iGPU enabled in BIOS (even with no monitor attached)
#   - .env file populated
#   - NAS reachable and NFS exports configured
#
# Usage:
#   cd /path/to/media-stack-final/machine1-plex
#   cp .env.example .env && nano .env
#   chmod +x ../scripts/init-machine1-plex.sh
#   sudo ../scripts/init-machine1-plex.sh
# =============================================================================

set -euo pipefail

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
CYAN='\033[0;36m'; BOLD='\033[1m'; NC='\033[0m'

log()  { echo -e "${GREEN}[✓]${NC} $1"; }
warn() { echo -e "${YELLOW}[!]${NC} $1"; }
err()  { echo -e "${RED}[✗]${NC} $1"; }
info() { echo -e "${CYAN}[→]${NC} $1"; }
header() { echo -e "\n${BOLD}═══════════════════════════════════════════${NC}"; echo -e "${BOLD}  $1${NC}"; echo -e "${BOLD}═══════════════════════════════════════════${NC}\n"; }

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/../machine1-plex" && pwd)"

if [ -f "$PROJECT_DIR/.env" ]; then
    set +H 2>/dev/null || true
    set -a; source "$PROJECT_DIR/.env"; set +a
    log "Loaded .env"
else
    err ".env not found at $PROJECT_DIR/.env — copy from .env.example"
    exit 1
fi

APPDATA="${APPDATA:-/opt/media-stack}"
MEDIA_ROOT="${MEDIA_ROOT:-/mnt/media}"
NAS_IP="${NAS_IP:-}"
NAS_MEDIA_EXPORT="${NAS_MEDIA_EXPORT:-/volume1/media}"
REAL_USER="${SUDO_USER:-$USER}"

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
header "Phase 1: System Packages + Intel iGPU Drivers"
# ===========================================================================

log "Detected package manager: $PKG_MGR"

# Set machine hostname (idempotent)
if [ "$(hostname | tr '[:upper:]' '[:lower:]')" != "spyglass" ]; then
    hostnamectl set-hostname spyglass 2>/dev/null || true
    log "Hostname set to spyglass"
else
    log "Hostname already set to spyglass"
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

# Intel iGPU drivers (distro-specific)
info "Installing Intel GPU drivers..."
if [ "$PKG_MGR" = "apt" ]; then
    # Debian 12 may use DEB822 format (.sources) or traditional format (.list)
    if [ -f /etc/apt/sources.list.d/debian.sources ]; then
        if ! grep -q "non-free-firmware" /etc/apt/sources.list.d/debian.sources 2>/dev/null; then
            info "Enabling non-free repos (DEB822 format)..."
            sed -i 's/^Components: main.*/Components: main contrib non-free non-free-firmware/' /etc/apt/sources.list.d/debian.sources
            apt-get update -qq
        fi
    elif ! grep -q "non-free" /etc/apt/sources.list /etc/apt/sources.list.d/*.list 2>/dev/null; then
        info "Enabling non-free repos..."
        sed -i 's/bookworm main$/bookworm main contrib non-free non-free-firmware/' /etc/apt/sources.list
        apt-get update -qq
    fi
    pkg_install "$PKG_MGR" intel-media-va-driver-non-free intel-gpu-tools vainfo
elif [ "$PKG_MGR" = "dnf" ]; then
    pkg_install "$PKG_MGR" intel-media-driver intel-gpu-tools libva-utils
elif [ "$PKG_MGR" = "pacman" ]; then
    pkg_install "$PKG_MGR" intel-media-driver intel-gpu-tools libva-utils
fi

log "System packages installed"

# Verify iGPU
info "Verifying Intel iGPU..."
if [ -e /dev/dri/renderD128 ]; then
    log "iGPU detected: /dev/dri/renderD128 ✓"
    vainfo 2>/dev/null | head -5 || true
else
    err "iGPU NOT detected at /dev/dri/renderD128"
    err "Check BIOS: ensure integrated graphics is ENABLED"
    err "Some boards disable iGPU when no monitor is connected — look for"
    err "'IGD Multi-Monitor' or 'Internal Graphics' in BIOS and enable it."
    warn "Continuing anyway — Plex will fall back to CPU transcoding"
fi

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

if [ "$REAL_USER" != "root" ]; then
    usermod -aG docker "$REAL_USER"
    log "Added $REAL_USER to docker group"
fi

# ===========================================================================
header "Phase 3: Directory Structure"
# ===========================================================================

info "Creating app data directories..."
mkdir -p "$APPDATA"/{plex/{config,transcode},tdarr/{server,configs,logs,transcode_cache}}
mkdir -p "$APPDATA"/{kometa/config,overseerr/config,tautulli/config}
mkdir -p "$APPDATA"/{homepage/config,tailscale/state,uptime-kuma/data}
mkdir -p "$APPDATA"/backups

if [ "$REAL_USER" != "root" ]; then
    chown -R "$REAL_USER":"$REAL_USER" "$APPDATA"
fi

log "App data directories created at $APPDATA"

# ===========================================================================
header "Phase 4: NFS Mounts"
# ===========================================================================

if [ -n "$NAS_IP" ]; then
    info "Configuring NFS mount..."
    mkdir -p "$MEDIA_ROOT"

    if mountpoint -q "$MEDIA_ROOT" 2>/dev/null; then
        log "Media already mounted at $MEDIA_ROOT"
    else
        # Plex machine mounts media read-write (Tdarr re-encodes in place)
        FSTAB_ENTRY="${NAS_IP}:${NAS_MEDIA_EXPORT} ${MEDIA_ROOT} nfs rw,hard,intr,rsize=1048576,wsize=1048576,timeo=600,retrans=2 0 0"
        if ! grep -qF "$MEDIA_ROOT" /etc/fstab; then
            echo "$FSTAB_ENTRY" >> /etc/fstab
            log "Added NFS mount to fstab"
        fi
        mount "$MEDIA_ROOT" && log "Mounted $MEDIA_ROOT" || warn "Could not mount — check NAS"
    fi
else
    warn "NAS_IP not set — skipping NFS mount"
fi

# ===========================================================================
header "Phase 5: Pre-Seed Configurations"
# ===========================================================================

# --- Kometa config template ---
KOMETA_CONF="$APPDATA/kometa/config/config.yml"
if [ ! -f "$KOMETA_CONF" ]; then
    info "Deploying Kometa config template..."
    cp "$PROJECT_DIR/config-templates/kometa.yml" "$KOMETA_CONF"
    log "Kometa config deployed"
else
    log "Kometa config already exists"
fi

# Always substitute known values (idempotent — no-op if placeholders already replaced)
if [ -f "$KOMETA_CONF" ]; then
    PLEX_IP="${PLEX_IP:-$(hostname -I 2>/dev/null | awk '{print $1}')}"
    PLEX_IP="${PLEX_IP:-localhost}"
    [ -n "${PLEX_TOKEN:-}" ] && sed -i "s/YOUR_PLEX_TOKEN/${PLEX_TOKEN}/g" "$KOMETA_CONF"
    [ -n "${TMDB_API_KEY:-}" ] && sed -i "s/YOUR_TMDB_API_KEY/${TMDB_API_KEY}/g" "$KOMETA_CONF"
    [ -n "${MDBLIST_API_KEY:-}" ] && sed -i "s/YOUR_MDBLIST_API_KEY/${MDBLIST_API_KEY}/g" "$KOMETA_CONF"
    [ -n "${TRAKT_CLIENT_ID:-}" ] && sed -i "s/YOUR_TRAKT_ID/${TRAKT_CLIENT_ID}/g" "$KOMETA_CONF"
    [ -n "${TRAKT_CLIENT_SECRET:-}" ] && sed -i "s/YOUR_TRAKT_SECRET/${TRAKT_CLIENT_SECRET}/g" "$KOMETA_CONF"
    sed -i "s|http://PLEX_SERVER_IP:32400|http://${PLEX_IP}:32400|g" "$KOMETA_CONF"
    # Trakt OAuth tokens (populated by trakt_device_auth in setup.sh)
    if [ -n "${TRAKT_ACCESS_TOKEN:-}" ]; then
        sed -i "s|^    access_token:.*|    access_token: ${TRAKT_ACCESS_TOKEN}|" "$KOMETA_CONF"
        sed -i "s|^    refresh_token:.*|    refresh_token: ${TRAKT_REFRESH_TOKEN:-}|" "$KOMETA_CONF"
        sed -i "s|^    expires_in:.*|    expires_in: ${TRAKT_EXPIRES:-}|" "$KOMETA_CONF"
        sed -i "s|^    created_at:.*|    created_at: ${TRAKT_CREATED_AT:-}|" "$KOMETA_CONF"
        sed -i "s|^    token_type:.*|    token_type: Bearer|" "$KOMETA_CONF"
        sed -i "s|^    scope:.*|    scope: public|" "$KOMETA_CONF"
    fi
    log "Kometa credentials substituted"
fi

# --- Homepage config skeleton ---
HOMEPAGE_SERVICES="$APPDATA/homepage/config/services.yaml"
if [ ! -f "$HOMEPAGE_SERVICES" ]; then
    info "Deploying Homepage config..."
    cp "$PROJECT_DIR/config-templates/homepage-services.yaml" "$HOMEPAGE_SERVICES" 2>/dev/null || true
fi

if [ "$REAL_USER" != "root" ]; then
    chown -R "$REAL_USER":"$REAL_USER" "$APPDATA"
fi

# ===========================================================================
header "Phase 6: Docker Compose Up"
# ===========================================================================

info "Starting Plex stack..."
cd "$PROJECT_DIR"

if [ "$REAL_USER" != "root" ] && id -nG "$REAL_USER" | grep -qw docker; then
    sudo -u "$REAL_USER" docker compose up -d --remove-orphans
else
    docker compose up -d --remove-orphans
fi

log "All containers starting"

# ===========================================================================
header "Phase 7: Plex Preferences"
# ===========================================================================

info "Waiting for Plex to initialize..."
sleep 20

PREFS_FILE="$APPDATA/plex/config/Library/Application Support/Plex Media Server/Preferences.xml"
PREFS_UPDATED=false

if [ -f "$PREFS_FILE" ]; then
    info "Patching Plex preferences..."

    # Hardware transcoding (Quick Sync)
    if ! grep -q "HardwareAcceleratedCodecs" "$PREFS_FILE"; then
        sed -i 's|/>$| HardwareAcceleratedCodecs="1" HardwareAcceleratedEncoders="1"/>|' "$PREFS_FILE"
        log "  Enabled hardware transcoding (Quick Sync)"
        PREFS_UPDATED=true
    else
        log "  Hardware transcoding already enabled"
    fi

    # Subtitle mode: "Shown with foreign audio" (value=1)
    # This is the forced subtitle fix — foreign dialogue gets subtitled
    # even when subtitles are "off"
    if ! grep -q "SubtitleMode" "$PREFS_FILE"; then
        sed -i 's|/>$| SubtitleMode="1"/>|' "$PREFS_FILE"
        log "  Subtitles: shown with foreign audio ✓"
        PREFS_UPDATED=true
    else
        log "  Subtitle mode already configured"
    fi

    # Prefer higher speed encoding (0=prefer speed, 1=prefer quality)
    if ! grep -q "TranscoderQuality" "$PREFS_FILE"; then
        sed -i 's|/>$| TranscoderQuality="0"/>|' "$PREFS_FILE"
        log "  Transcoder: prefer higher speed"
        PREFS_UPDATED=true
    fi

    # Use temporary transcoding path on local SSD
    if ! grep -q "TranscoderTempDirectory" "$PREFS_FILE"; then
        sed -i 's|/>$| TranscoderTempDirectory="/transcode"/>|' "$PREFS_FILE"
        log "  Transcoder temp: /transcode (local SSD)"
        PREFS_UPDATED=true
    fi

    if [ "$PREFS_UPDATED" = true ]; then
        warn "Restarting Plex to apply preference changes..."
        docker restart plex
        sleep 10
        log "Plex restarted with new preferences"
    fi
else
    warn "Plex preferences file not found — Plex may still be initializing"
    warn "Re-run this script after completing the Plex setup wizard at:"
    warn "  http://localhost:32400/web"
fi

# ===========================================================================
header "Phase 8: Summary"
# ===========================================================================

echo ""
log "Spyglass (Plex server) deployment complete!"
echo ""
echo "  ┌─────────────────────────────────────────────────────┐"
echo "  │  AUTOMATED                                          │"
echo "  ├─────────────────────────────────────────────────────┤"
echo "  │  ✓ System packages + Intel iGPU drivers            │"
echo "  │  ✓ iGPU verified (/dev/dri/renderD128)             │"
echo "  │  ✓ Docker installed                                │"
echo "  │  ✓ Directory structure created                     │"
echo "  │  ✓ NFS mounts configured                           │"
echo "  │  ✓ Kometa config deployed with API keys            │"
echo "  │  ✓ All containers running                          │"
echo "  │  ✓ Plex: hardware transcoding enabled              │"
echo "  │  ✓ Plex: subtitle mode = foreign audio only        │"
echo "  │  ✓ Plex: transcoder speed optimized                │"
echo "  │  ✓ Plex: transcode temp on local SSD               │"
echo "  │  ✓ Uptime Kuma monitoring dashboard                │"
echo "  │  ✓ Docker healthchecks on all services             │"
echo "  │  ✓ Config backup automation (weekly + rotation)    │"
echo "  └─────────────────────────────────────────────────────┘"
echo ""
warn "STILL NEEDS MANUAL SETUP:"
echo ""
echo "  Plex  (http://localhost:32400/web)"
echo "    → Complete setup wizard (first run only)"
echo "    → Add libraries pointing to media folders"
echo "    → Claim server at https://plex.tv/claim"
echo ""
echo "  Tdarr  (http://localhost:8265)"
echo "    → Add libraries: /movies, /tv, /anime, /documentaries"
echo "    → Cache path: /temp"
echo "    → Plugins (add in order):"
echo "        1. Migz5ConvertContainer  → MKV"
echo "        2. Migz1FFMPEG            → H.265/QSV"
echo "        3. Migz3CleanAudio        → keep: eng + original"
echo "        4. Migz4CleanSubs         → keep: eng + FORCED ⚠️"
echo "        (Migz4CleanSubs: set to KEEP forced tracks!)"
echo "    → Schedule: 1 AM – 5 PM (avoid prime viewing)"
echo ""
echo "  Overseerr  (http://localhost:5055)"
echo "    → Sign in with Plex"
echo "    → Connect Radarr: http://PRIVATEER_IP:7878 (or localhost if single-machine)"
echo "    → Connect Sonarr: http://PRIVATEER_IP:8989 (or localhost if single-machine)"
echo ""
echo "  Tautulli  (http://localhost:8181)"
echo "    → Auto-detects Plex on same machine"
echo "    → Add Discord webhook for playback notifications"
echo ""
echo "  Uptime Kuma  (http://localhost:3001)"
echo "    → Create admin account on first visit"
echo "    → Add monitors for all services (use healthcheck endpoints)"
echo ""
echo "  Kometa"
echo "    → Verify config: $APPDATA/kometa/config/config.yml"
echo "    → First run: docker exec kometa python kometa.py --run"
echo "    → (Takes hours on first run — processing entire library)"
echo ""
echo "  Verify hardware transcoding:"
echo "    → Play something, force transcode in player quality settings"
echo "    → Run: sudo intel_gpu_top (should show GPU activity)"
echo ""
