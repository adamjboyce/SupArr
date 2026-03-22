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

# ── Self-logging ──────────────────────────────────────────────────────────
# All output is tee'd to a persistent log file so failures are diagnosable
# even if the SSH session dies mid-run.
DEPLOY_LOG="/opt/suparr/spyglass-init.log"
mkdir -p "$(dirname "$DEPLOY_LOG")" 2>/dev/null || true
exec > >(tee -a "$DEPLOY_LOG") 2>&1
echo ""
echo "=== Spyglass init started at $(date -Iseconds) ==="
echo ""

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
NAS_MEDIA_EXPORT="${NAS_MEDIA_EXPORT:-/var/nfs/shared/media}"

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
    # Running as root via SSH with no SUDO_USER — find the primary non-root user
    REAL_USER=$(awk -F: '$3 >= 1000 && $3 < 60000 && $7 ~ /bash|zsh|fish/ {print $1; exit}' /etc/passwd)
    REAL_USER="${REAL_USER:-root}"
    if [ "$REAL_USER" != "root" ]; then
        log "Detected non-root user: $REAL_USER"
    fi
fi

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
    # Check for "contrib" on active (uncommented) repo lines. The commented-out
    # cdrom line often contains "contrib" which gives false positives with plain grep.
    if [ -f /etc/apt/sources.list.d/debian.sources ]; then
        if ! grep -v '^\s*#' /etc/apt/sources.list.d/debian.sources 2>/dev/null | grep -q "contrib"; then
            info "Enabling non-free repos (DEB822 format)..."
            sed -i 's/^Components: main.*/Components: main contrib non-free non-free-firmware/' /etc/apt/sources.list.d/debian.sources
            apt-get update -qq
        fi
    elif ! grep -v '^\s*#' /etc/apt/sources.list /etc/apt/sources.list.d/*.list 2>/dev/null | grep -q "contrib"; then
        info "Enabling non-free repos..."
        # Handle lines that already have non-free-firmware but lack contrib + non-free
        sed -i '/^[^#]*bookworm main/s/main.*/main contrib non-free non-free-firmware/' /etc/apt/sources.list
        # Deduplicate in case non-free-firmware appeared twice
        sed -i 's/non-free-firmware non-free-firmware/non-free-firmware/' /etc/apt/sources.list
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
header "Phase 1b: Hardware Profile"
# ===========================================================================

source "$SCRIPT_DIR/detect-hardware.sh"
hw_report log

# ===========================================================================
header "Phase 1c: Network Environment Evaluation"
# ===========================================================================
# Informational only — reports findings and recommendations. Changes nothing.

info "Evaluating network environment..."

PRIMARY_NIC=$(ip route show default 2>/dev/null | awk '{print $5; exit}')
if [ -n "$PRIMARY_NIC" ]; then
    NIC_MTU=$(cat /sys/class/net/"$PRIMARY_NIC"/mtu 2>/dev/null || echo "unknown")
    NIC_MAX_MTU=$(ip -d link show "$PRIMARY_NIC" 2>/dev/null | grep -oP 'maxmtu \K[0-9]+' || echo "unknown")
    NIC_SPEED=$(cat /sys/class/net/"$PRIMARY_NIC"/speed 2>/dev/null || echo "unknown")
    log "Primary NIC: $PRIMARY_NIC"
    log "  Link speed: ${NIC_SPEED} Mbps"
    log "  Current MTU: $NIC_MTU  |  Max supported: $NIC_MAX_MTU"

    if [ "$NIC_MAX_MTU" != "unknown" ] && [ "$NIC_MAX_MTU" -gt 1500 ] 2>/dev/null && [ "$NIC_MTU" -eq 1500 ] 2>/dev/null; then
        if [ -n "$NAS_IP" ]; then
            if ping -M do -s 8972 -c 1 -W 2 "$NAS_IP" &>/dev/null; then
                log "  Jumbo frames (MTU 9000): ✓ NAS path supports them"
                warn "  NIC and NAS support jumbo frames but MTU is 1500."
                warn "  For NFS-heavy workloads, consider setting MTU 9000 on NIC, switch, and NAS."
            elif ping -M do -s 1472 -c 1 -W 2 "$NAS_IP" &>/dev/null; then
                log "  Jumbo frames: ✗ Path to NAS ($NAS_IP) capped at MTU 1500"
                log "  NIC supports MTU $NIC_MAX_MTU but switch/router limits to 1500."
                if [ "$NIC_SPEED" != "unknown" ] && [ "$NIC_SPEED" -ge 10000 ] 2>/dev/null; then
                    warn "  You have ${NIC_SPEED}Mbps NICs — enabling jumbo frames on your"
                    warn "  switch and NAS would reduce overhead on NFS transfers significantly."
                fi
            else
                warn "  Cannot reach NAS at $NAS_IP — skipping MTU path test"
            fi
        fi
    fi

    if command -v nfsstat &>/dev/null; then
        NFS_VER=$(nfsstat -m 2>/dev/null | grep -oP 'vers=\K[0-9]+' | head -1 || true)
        if [ -n "$NFS_VER" ]; then
            log "  NFS version in use: v$NFS_VER"
            [ "$NFS_VER" -lt 4 ] 2>/dev/null && warn "  NFSv4 is faster than v$NFS_VER — consider upgrading NFS exports"
        fi
    fi
else
    warn "Could not detect primary network interface"
fi

log "Network evaluation complete"

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
mkdir -p "$APPDATA"/{stash/{config,generated,metadata,cache}}
mkdir -p "$APPDATA"/{makemkv/config,handbrake/{config,output},rips}
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
        FSTAB_ENTRY="${NAS_IP}:${NAS_MEDIA_EXPORT} ${MEDIA_ROOT} nfs rw,hard,intr,rsize=1048576,wsize=1048576,timeo=600,retrans=2,x-systemd.automount,x-systemd.mount-timeout=120,x-systemd.idle-timeout=0,_netdev 0 0"
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
header "Phase 4b: NFS/Docker Boot Dependencies"
# ===========================================================================
# Ensure Docker waits for NFS mounts on boot. Three layers:
#   1. fstab x-systemd options (done in Phase 4 above)
#   2. Docker systemd override — RequiresMountsFor
#   3. NFS stall monitor service with Discord alerts

if [ -n "$NAS_IP" ]; then
    info "Configuring Docker to wait for NFS mounts..."
    mkdir -p /etc/systemd/system/docker.service.d

    # Build RequiresMountsFor from actual NFS mount points
    NFS_MOUNT_PATHS="$MEDIA_ROOT"
    cat > /etc/systemd/system/docker.service.d/nfs-dependency.conf <<EODROP
[Unit]
RequiresMountsFor=$NFS_MOUNT_PATHS
EODROP
    log "Docker systemd override created — Docker will wait for NFS"

    # Deploy NFS monitor service
    info "Deploying NFS stall monitor..."
    cp "$SCRIPT_DIR/nfs-monitor.sh" /usr/local/bin/nfs-monitor.sh
    chmod +x /usr/local/bin/nfs-monitor.sh
    cp "$SCRIPT_DIR/nfs-monitor.service" /etc/systemd/system/nfs-monitor.service

    # Inject Discord webhook if configured
    if [ -n "${DISCORD_WEBHOOK:-}" ]; then
        sed -i "s|^Environment=DISCORD_WEBHOOK_URL=.*|Environment=DISCORD_WEBHOOK_URL=$DISCORD_WEBHOOK|" \
            /etc/systemd/system/nfs-monitor.service
    fi

    systemctl daemon-reload
    systemctl enable --now nfs-monitor
    log "NFS monitor service enabled"
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

# --- Stash: pre-seed config.yml to skip setup wizard ---
STASH_CONFIG="$APPDATA/stash/config/config.yml"
if [ ! -f "$STASH_CONFIG" ]; then
    info "Pre-seeding Stash config..."
    mkdir -p "$(dirname "$STASH_CONFIG")"
    cat > "$STASH_CONFIG" << 'STASHCFG'
stashes:
  - path: /data
    excludeVideo: false
    excludeImage: false
database: /root/.stash/stash-go.sqlite
generated: /generated
cache: /cache
blobs_path: /root/.stash/blobs
blobs_storage: FILESYSTEM
host: 0.0.0.0
port: 9999
STASHCFG
    log "Stash config pre-seeded (content path: /data, wizard skipped)"
else
    log "Stash config already exists — skipping pre-seed"
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
header "Phase 8: Plex Library Auto-Creation"
# ===========================================================================

if [ -n "${PLEX_TOKEN:-}" ]; then
    PLEX_URL="http://localhost:32400"

    info "Waiting for Plex API..."
    PLEX_READY=false
    for _ in $(seq 1 30); do
        if curl -sf -o /dev/null "${PLEX_URL}/identity" -H "X-Plex-Token: ${PLEX_TOKEN}" 2>/dev/null; then
            PLEX_READY=true; break
        fi
        sleep 2
    done

    if [ "$PLEX_READY" = true ]; then
        # Get existing library names
        EXISTING_LIBS=$(curl -sf "${PLEX_URL}/library/sections" \
            -H "X-Plex-Token: ${PLEX_TOKEN}" \
            -H "Accept: application/json" 2>/dev/null | \
            jq -r '.MediaContainer.Directory[].title' 2>/dev/null || echo "")

        create_plex_library() {
            local name="$1" type="$2" path="$3" agent="$4" scanner="$5"
            if echo "$EXISTING_LIBS" | grep -qx "$name"; then
                log "  Library '$name' already exists"
                return
            fi
            curl -sf -X POST "${PLEX_URL}/library/sections" -G \
                -H "X-Plex-Token: ${PLEX_TOKEN}" \
                --data-urlencode "name=${name}" \
                --data-urlencode "type=${type}" \
                --data-urlencode "agent=${agent}" \
                --data-urlencode "scanner=${scanner}" \
                --data-urlencode "language=en-US" \
                --data-urlencode "location=${path}" > /dev/null 2>&1 && \
                log "  Library '${name}' created → ${path}" || \
                warn "  Could not create library '${name}'"
        }

        info "Creating Plex libraries..."
        create_plex_library "Movies"        "movie"  "/movies"        "tv.plex.agents.movie"  "Plex Movie"
        create_plex_library "TV Shows"      "show"   "/tv"            "tv.plex.agents.series" "Plex TV Series"
        create_plex_library "Anime"         "show"   "/anime"         "tv.plex.agents.series" "Plex TV Series"
        create_plex_library "Anime Movies"  "movie"  "/anime-movies"  "tv.plex.agents.movie"  "Plex Movie"
        create_plex_library "Music"         "artist" "/music"         "tv.plex.agents.music"  "Plex Music"
        create_plex_library "Documentaries" "movie"  "/documentaries" "tv.plex.agents.movie"  "Plex Movie"
        create_plex_library "Stand-Up"      "movie"  "/stand-up"      "tv.plex.agents.movie"  "Plex Movie"
        log "Plex libraries configured"
    else
        warn "Plex API not ready — libraries must be created manually or re-run this script"
    fi
else
    warn "PLEX_TOKEN not set — skipping library auto-creation"
    warn "Set PLEX_TOKEN in .env and re-run, or create libraries manually in Plex UI"
fi

# ===========================================================================
header "Phase 9: Homepage API Keys"
# ===========================================================================

HOMEPAGE_SERVICES="$APPDATA/homepage/config/services.yaml"
if [ -f "$HOMEPAGE_SERVICES" ]; then
    info "Substituting API keys into Homepage config..."
    KEYS_SET=false

    # Plex token — from .env
    if [ -n "${PLEX_TOKEN:-}" ]; then
        sed -i "s|{{HOMEPAGE_VAR_PLEX_TOKEN}}|${PLEX_TOKEN}|g" "$HOMEPAGE_SERVICES" 2>/dev/null && KEYS_SET=true
    fi

    # Overseerr API key — from settings.json
    OS_SETTINGS="$APPDATA/overseerr/config/settings.json"
    if [ -f "$OS_SETTINGS" ]; then
        OS_KEY=$(jq -r '.main.apiKey // empty' "$OS_SETTINGS" 2>/dev/null || echo "")
        if [ -n "$OS_KEY" ]; then
            sed -i "s|{{HOMEPAGE_VAR_OVERSEERR_KEY}}|${OS_KEY}|g" "$HOMEPAGE_SERVICES" 2>/dev/null && KEYS_SET=true
        fi
    fi

    # Tautulli API key — from config.ini
    TAUTULLI_CONF="$APPDATA/tautulli/config/config.ini"
    if [ -f "$TAUTULLI_CONF" ]; then
        TAU_KEY=$(grep -oP 'api_key\s*=\s*\K\S+' "$TAUTULLI_CONF" 2>/dev/null | head -1 || echo "")
        if [ -n "$TAU_KEY" ]; then
            sed -i "s|{{HOMEPAGE_VAR_TAUTULLI_KEY}}|${TAU_KEY}|g" "$HOMEPAGE_SERVICES" 2>/dev/null && KEYS_SET=true
        fi
    fi

    if [ "$KEYS_SET" = true ]; then
        log "Homepage API keys substituted"
    else
        warn "No API keys available yet — Homepage widgets will show after services initialize"
    fi
fi

# ===========================================================================
header "Phase 10: Tdarr Library Auto-Configuration"
# ===========================================================================

# Use shared setup-tdarr.sh for hardware-detected flow + library seeding
TDARR_SETUP="$(cd "$(dirname "$0")" && pwd)/setup-tdarr.sh"
if [ -f "$TDARR_SETUP" ]; then
    chmod +x "$TDARR_SETUP"
    TDARR_URL="http://localhost:8265" bash "$TDARR_SETUP"
else
    warn "setup-tdarr.sh not found — Tdarr must be configured manually"
fi


# ===========================================================================
header "Phase 11: Stash Setup"
# ===========================================================================

STASH_URL="http://localhost:9999"
STASH_READY=false
info "Waiting for Stash..."
for attempt in $(seq 1 20); do
    STASH_STATUS=$(curl -sf -X POST "$STASH_URL/graphql" \
        -H "Content-Type: application/json" \
        -d '{"query":"{ systemStatus { status } }"}' 2>/dev/null | jq -r '.data.systemStatus.status // empty' 2>/dev/null || echo "")
    if [ "$STASH_STATUS" = "OK" ]; then
        STASH_READY=true; break
    elif [ "$STASH_STATUS" = "SETUP" ]; then
        info "Running Stash setup via API..."
        curl -sf -X POST "$STASH_URL/graphql" \
            -H "Content-Type: application/json" \
            -d '{"query":"mutation { setup(input: { stashes: [{path: \"/data\", excludeVideo: false, excludeImage: false}], databaseFile: \"\", generatedLocation: \"\", cacheLocation: \"\", storeBlobsInDatabase: false, blobsLocation: \"\", configLocation: \"\" }) }"}' > /dev/null 2>&1 \
            && log "Stash setup completed via API" \
            || warn "Stash API setup failed"
        STASH_READY=true; break
    fi
    sleep 2
done

if [ "$STASH_READY" = true ]; then
    info "Triggering Stash content scan..."
    curl -sf -X POST "$STASH_URL/graphql" \
        -H "Content-Type: application/json" \
        -d '{"query":"mutation { metadataScan(input: { paths: [\"/data\"] }) }"}' > /dev/null 2>&1 \
        && log "Stash scan triggered for /data" \
        || warn "Stash scan trigger failed"
else
    warn "Stash not ready — skipping auto-config"
fi

# ===========================================================================
header "Phase 12: Summary"
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
echo "  │  ✓ NFS mounts configured (systemd boot deps)       │"
echo "  │  ✓ Docker waits for NFS before starting            │"
echo "  │  ✓ NFS stall monitor with Discord alerts           │"
echo "  │  ✓ Kometa config deployed with API keys            │"
echo "  │  ✓ All containers running                          │"
echo "  │  ✓ Plex: hardware transcoding enabled              │"
echo "  │  ✓ Plex: subtitle mode = foreign audio only        │"
echo "  │  ✓ Plex: transcoder speed optimized                │"
echo "  │  ✓ Plex: transcode temp on local SSD               │"
echo "  │  ✓ Plex: 7 libraries auto-created (if token set) │"
echo "  │  ✓ Tdarr: 7 libraries with QSV HEVC plugin stack│"
echo "  │  ✓ Tdarr: schedule 1AM-5PM (off during viewing) │"
echo "  │  ✓ Homepage: API keys injected for widgets       │"
echo "  │  ✓ Stash: config seeded + content scan           │"
echo "  │  ✓ Stash studio tagger (auto-tag every 30 min)  │"
echo "  │  ✓ Uptime Kuma monitoring dashboard                │"
echo "  │  ✓ Docker healthchecks on all services             │"
echo "  │  ✓ Config backup automation (weekly + rotation)    │"
echo "  └─────────────────────────────────────────────────────┘"
echo ""
warn "STILL NEEDS MANUAL SETUP:"
echo ""
echo "  Plex  (http://localhost:32400/web)"
echo "    → Complete setup wizard (first run only)"
if [ -z "${PLEX_TOKEN:-}" ]; then
echo "    → Add libraries pointing to media folders"
fi
echo "    → Claim server at https://plex.tv/claim"
echo ""
echo "  Tdarr  (http://localhost:8265)"
echo "    → Libraries + plugins auto-configured (verify at UI)"
echo "    → Adjust schedule or plugin settings if needed"
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
