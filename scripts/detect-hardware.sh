#!/usr/bin/env bash
# =============================================================================
# Hardware Detection — GPU, CPU, RAM, Disk profiling for SupArr
# =============================================================================
# Sources into init scripts. Exports HW_* variables that drive:
#   - Tdarr codec selection (AV1 vs HEVC vs software)
#   - Tdarr worker counts
#   - Container memory limits
#   - Informational logging
#
# Usage (from init scripts):
#   source "$SCRIPT_DIR/detect-hardware.sh"
#   # Now use: HW_GPU_TYPE, HW_CODEC, HW_ENCODER, HW_AV1, HW_CORES, HW_RAM_GB, etc.
# =============================================================================

# ── GPU Detection ────────────────────────────────────────────────────────────
# Detects ALL GPUs and picks the primary encoder. If both an iGPU and a
# discrete GPU exist, both are reported so Tdarr can run dual workers.
#
# Primary GPU: used for the main Tdarr flow and Plex transcoding.
# Secondary GPU: if present, Tdarr gets a second worker for parallel encodes.
#
# Priority for primary: iGPU first (efficient, leaves discrete free for
# dedicated work). On a dedicated transcode box, set TDARR_DEDICATED=true
# in .env to use discrete as primary and run both at full tilt.

HW_GPU_TYPE="none"
HW_GPU_NAME=""
HW_GPU_GEN=""
HW_AV1=false
HW_CODEC="hevc"
HW_ENCODER="libx265"
HW_TDARR_PLUGIN="Community:Tdarr_Plugin_bsh1_Boosh_FFMPEG_CPU_HEVC"

# Secondary GPU (for dual-worker Tdarr)
HW_GPU2_TYPE="none"
HW_GPU2_NAME=""
HW_GPU2_ENCODER=""
HW_GPU2_AV1=false
HW_DUAL_GPU=false

# Internal: detect Intel iGPU capabilities, sets vars passed by name
_detect_intel() {
    local _type="intel"
    local _name
    _name=$(lspci 2>/dev/null | grep -i 'VGA\|Display\|3D' | grep -i intel | head -1 | sed 's/.*: //')
    local _av1=false
    local _gen=""
    local _codec="hevc"
    local _encoder="hevc_qsv"
    local _plugin="Community:Tdarr_Plugin_bsh1_Boosh_FFMPEG_QSV_HEVC"

    # vainfo is the most reliable AV1 check
    if command -v vainfo &>/dev/null; then
        if vainfo 2>/dev/null | grep -qi 'VAEntrypointEncSlice.*AV1\|VAProfileAV1.*VAEntrypointEncSlice'; then
            _av1=true
        fi
    fi

    # Fallback: PCI device ID → generation
    if [ "$_av1" = false ] && [ -f /sys/class/drm/card0/device/device ]; then
        local dev_id
        dev_id=$(cat /sys/class/drm/card0/device/device 2>/dev/null | tr -d '[:space:]')
        case "$dev_id" in
            0x46*)           _gen="12"; _av1=true ;;   # Alder Lake
            0xa7*|0xA7*)     _gen="13"; _av1=true ;;   # Raptor Lake
            0x7d*|0x7D*)     _gen="14"; _av1=true ;;   # Meteor Lake
            0x56*)           _gen="arc"; _av1=true ;;   # Arc discrete
            0x9a*|0x9A*)     _gen="11" ;;               # Tiger/Rocket Lake
            0x8a*|0x8A*)     _gen="10" ;;               # Ice Lake
            0x3e*|0x3E*)     _gen="9" ;;                # Coffee Lake Refresh
            0x9b*|0x9B*)     _gen="8" ;;                # Coffee Lake
            *)               _gen="unknown" ;;
        esac
    fi

    # Name-based fallback for Arc and branded chips
    if [ "$_av1" = false ]; then
        case "$_name" in
            *Arc*|*A380*|*A580*|*A750*|*A770*) _av1=true; _gen="arc" ;;
            *"Core Ultra"*) _av1=true ;;
        esac
    fi

    if [ "$_av1" = true ]; then
        _codec="av1"; _encoder="av1_qsv"
        _plugin="Community:Tdarr_Plugin_bsh1_Boosh_FFMPEG_QSV_AV1"
    fi

    # Export to the variable names passed as arguments
    eval "$1='$_type'"; eval "$2='$_name'"; eval "$3='$_av1'"
    eval "$4='$_codec'"; eval "$5='$_encoder'"; eval "$6='$_plugin'"; eval "$7='$_gen'"
}

# Internal: detect NVIDIA discrete GPU capabilities
_detect_nvidia() {
    local _name
    _name=$(nvidia-smi --query-gpu=name --format=csv,noheader 2>/dev/null | head -1)
    local _av1=false _codec="hevc" _encoder="hevc_nvenc"
    local _plugin="Community:Tdarr_Plugin_bsh1_Boosh_FFMPEG_NVENC_HEVC"

    case "$_name" in
        *"RTX 40"*|*"RTX 50"*|*"L40"*|*"Ada"*)
            _av1=true; _codec="av1"; _encoder="av1_nvenc"
            _plugin="Community:Tdarr_Plugin_bsh1_Boosh_FFMPEG_NVENC_AV1" ;;
    esac

    eval "$1='nvidia'"; eval "$2='$_name'"; eval "$3='$_av1'"
    eval "$4='$_codec'"; eval "$5='$_encoder'"; eval "$6='$_plugin'"
}

detect_gpu() {
    local has_intel=false has_nvidia=false has_amd=false

    # Inventory what's present
    if [ -e /dev/dri/renderD128 ] && lspci 2>/dev/null | grep -qi 'Intel.*Graphics\|Intel.*UHD\|Intel.*Iris\|Intel.*Arc'; then
        has_intel=true
    fi
    if command -v nvidia-smi &>/dev/null && nvidia-smi --query-gpu=name --format=csv,noheader &>/dev/null 2>&1; then
        has_nvidia=true
    fi
    if [ -e /dev/dri/renderD128 ] && lspci 2>/dev/null | grep -qi 'AMD.*Radeon\|AMD.*RDNA'; then
        has_amd=true
    fi

    # --- Dual GPU: Intel iGPU + NVIDIA discrete ---
    if [ "$has_intel" = true ] && [ "$has_nvidia" = true ]; then
        HW_DUAL_GPU=true

        # Detect both
        local i_type i_name i_av1 i_codec i_enc i_plug i_gen
        _detect_intel i_type i_name i_av1 i_codec i_enc i_plug i_gen

        local n_type n_name n_av1 n_codec n_enc n_plug
        _detect_nvidia n_type n_name n_av1 n_codec n_enc n_plug

        # TDARR_DEDICATED=true in .env: use discrete as primary (dedicated transcode box)
        if [ "${TDARR_DEDICATED:-false}" = "true" ]; then
            HW_GPU_TYPE="nvidia"; HW_GPU_NAME="$n_name"; HW_AV1=$n_av1
            HW_CODEC="$n_codec"; HW_ENCODER="$n_enc"; HW_TDARR_PLUGIN="$n_plug"
            HW_GPU2_TYPE="intel"; HW_GPU2_NAME="$i_name"; HW_GPU2_ENCODER="$i_enc"; HW_GPU2_AV1=$i_av1
        else
            # Default: iGPU primary (efficient, Plex uses it), discrete secondary
            HW_GPU_TYPE="intel"; HW_GPU_NAME="$i_name"; HW_AV1=$i_av1; HW_GPU_GEN="$i_gen"
            HW_CODEC="$i_codec"; HW_ENCODER="$i_enc"; HW_TDARR_PLUGIN="$i_plug"
            HW_GPU2_TYPE="nvidia"; HW_GPU2_NAME="$n_name"; HW_GPU2_ENCODER="$n_enc"; HW_GPU2_AV1=$n_av1
        fi
        return
    fi

    # --- Single GPU: Intel iGPU ---
    if [ "$has_intel" = true ]; then
        local i_type i_name i_av1 i_codec i_enc i_plug i_gen
        _detect_intel i_type i_name i_av1 i_codec i_enc i_plug i_gen
        HW_GPU_TYPE="$i_type"; HW_GPU_NAME="$i_name"; HW_AV1=$i_av1; HW_GPU_GEN="$i_gen"
        HW_CODEC="$i_codec"; HW_ENCODER="$i_enc"; HW_TDARR_PLUGIN="$i_plug"
        return
    fi

    # --- Single GPU: NVIDIA ---
    if [ "$has_nvidia" = true ]; then
        local n_type n_name n_av1 n_codec n_enc n_plug
        _detect_nvidia n_type n_name n_av1 n_codec n_enc n_plug
        HW_GPU_TYPE="$n_type"; HW_GPU_NAME="$n_name"; HW_AV1=$n_av1
        HW_CODEC="$n_codec"; HW_ENCODER="$n_enc"; HW_TDARR_PLUGIN="$n_plug"
        return
    fi

    # --- Single GPU: AMD ---
    if [ "$has_amd" = true ]; then
        HW_GPU_TYPE="amd"
        HW_GPU_NAME=$(lspci 2>/dev/null | grep -i 'VGA\|Display\|3D' | grep -i amd | head -1 | sed 's/.*: //')
        case "$HW_GPU_NAME" in
            *"RX 7"*|*"RDNA 3"*|*"RX 8"*)
                HW_AV1=true; HW_CODEC="av1"; HW_ENCODER="av1_amf" ;;
            *)
                HW_CODEC="hevc"; HW_ENCODER="hevc_amf" ;;
        esac
        HW_TDARR_PLUGIN="Community:Tdarr_Plugin_bsh1_Boosh_FFMPEG_CPU_HEVC"  # AMF Tdarr plugins TBD
        return
    fi

    # --- No GPU (software encode) ---
    # On 8+ core CPUs, SVT-AV1 is faster than libx265 at comparable quality
    # and produces smaller files. Below 8 cores, stick with libx265.
    HW_GPU_TYPE="none"
    local cores
    cores=$(nproc 2>/dev/null || echo 1)
    if [ "$cores" -ge 8 ]; then
        HW_CODEC="av1"; HW_ENCODER="libsvtav1"; HW_AV1=true
    else
        HW_CODEC="hevc"; HW_ENCODER="libx265"
    fi
    HW_TDARR_PLUGIN="Community:Tdarr_Plugin_bsh1_Boosh_FFMPEG_CPU_HEVC"
}

# ── CPU Detection ────────────────────────────────────────────────────────────

HW_CPU_MODEL=""
HW_CORES=1
HW_THREADS=1

detect_cpu() {
    HW_CPU_MODEL=$(grep -m1 'model name' /proc/cpuinfo 2>/dev/null | sed 's/.*: //' || echo "unknown")
    HW_CORES=$(nproc 2>/dev/null || echo 1)
    HW_THREADS=$(grep -c ^processor /proc/cpuinfo 2>/dev/null || echo "$HW_CORES")
}

# ── RAM Detection ────────────────────────────────────────────────────────────

HW_RAM_GB=0
HW_RAM_AVAILABLE_GB=0

detect_ram() {
    HW_RAM_GB=$(free -g 2>/dev/null | awk '/Mem:/{print $2}' || echo 0)
    HW_RAM_AVAILABLE_GB=$(free -g 2>/dev/null | awk '/Mem:/{print $7}' || echo 0)
}

# ── Disk Detection ───────────────────────────────────────────────────────────

HW_BOOT_DISK_TYPE="unknown"  # nvme, ssd, hdd
HW_BOOT_DISK_SIZE_GB=0

detect_disk() {
    # Find the root filesystem device
    local root_dev
    root_dev=$(findmnt -n -o SOURCE / 2>/dev/null | sed 's/[0-9]*$//' | sed 's|/dev/||' | sed 's/p$//' || echo "")
    if [ -z "$root_dev" ]; then return; fi

    # Determine type
    if echo "$root_dev" | grep -q "nvme"; then
        HW_BOOT_DISK_TYPE="nvme"
    elif [ -f "/sys/block/${root_dev}/queue/rotational" ]; then
        local rota
        rota=$(cat "/sys/block/${root_dev}/queue/rotational" 2>/dev/null || echo "1")
        [ "$rota" = "0" ] && HW_BOOT_DISK_TYPE="ssd" || HW_BOOT_DISK_TYPE="hdd"
    fi

    # Size in GB
    if [ -f "/sys/block/${root_dev}/size" ]; then
        local sectors
        sectors=$(cat "/sys/block/${root_dev}/size" 2>/dev/null || echo 0)
        HW_BOOT_DISK_SIZE_GB=$(( sectors * 512 / 1073741824 ))
    fi
}

# ── Optical Drive Detection ──────────────────────────────────────────────────

HW_OPTICAL=false
HW_OPTICAL_DEVICE=""
HW_OPTICAL_TYPE=""  # dvd, bluray, or empty

detect_optical() {
    # Check for optical drive devices
    for dev in /dev/sr0 /dev/sr1 /dev/cdrom; do
        if [ -e "$dev" ]; then
            HW_OPTICAL=true
            HW_OPTICAL_DEVICE="$dev"
            # Detect Blu-ray vs DVD capability
            if command -v lsscsi &>/dev/null; then
                local desc
                desc=$(lsscsi 2>/dev/null | grep -i 'cd\|dvd\|bd\|blu' | head -1 || true)
                if echo "$desc" | grep -qi 'bd\|blu'; then
                    HW_OPTICAL_TYPE="bluray"
                else
                    HW_OPTICAL_TYPE="dvd"
                fi
            elif [ -d /proc/sys/dev/cdrom ]; then
                # Check cdrom info
                if grep -qi 'Can read Blu-Ray\|BD' /proc/sys/dev/cdrom/info 2>/dev/null; then
                    HW_OPTICAL_TYPE="bluray"
                else
                    HW_OPTICAL_TYPE="dvd"
                fi
            else
                HW_OPTICAL_TYPE="dvd"  # assume DVD if can't detect
            fi
            return
        fi
    done
}

# ── Derived Recommendations ──────────────────────────────────────────────────

HW_TDARR_CPU_WORKERS=1
HW_TDARR_GPU_WORKERS=0
HW_WHISPARR_MEM_LIMIT="2g"
HW_IMMICH_ML_WORKERS=1

compute_recommendations() {
    # Tdarr GPU workers: 1 per detected GPU, 2 if dual-GPU
    if [ "$HW_DUAL_GPU" = true ]; then
        HW_TDARR_GPU_WORKERS=2
    elif [ "$HW_GPU_TYPE" != "none" ]; then
        HW_TDARR_GPU_WORKERS=1
    fi

    # Tdarr CPU workers: cores/4 (min 1, max 4)
    HW_TDARR_CPU_WORKERS=$(( HW_CORES / 4 ))
    [ "$HW_TDARR_CPU_WORKERS" -lt 1 ] && HW_TDARR_CPU_WORKERS=1
    [ "$HW_TDARR_CPU_WORKERS" -gt 4 ] && HW_TDARR_CPU_WORKERS=4

    # Whisparr memory limit: scale with available RAM
    if [ "$HW_RAM_GB" -ge 64 ]; then
        HW_WHISPARR_MEM_LIMIT="4g"
    elif [ "$HW_RAM_GB" -ge 32 ]; then
        HW_WHISPARR_MEM_LIMIT="3g"
    else
        HW_WHISPARR_MEM_LIMIT="2g"
    fi

    # Immich ML workers
    if [ "$HW_GPU_TYPE" = "nvidia" ]; then
        HW_IMMICH_ML_WORKERS=2
    elif [ "$HW_CORES" -ge 8 ]; then
        HW_IMMICH_ML_WORKERS=2
    fi
}

# ── Run All Detection ────────────────────────────────────────────────────────

detect_gpu
detect_cpu
detect_ram
detect_disk
detect_optical
compute_recommendations

# ── Report ───────────────────────────────────────────────────────────────────

hw_report() {
    # Call this from the init script to log the hardware profile
    local _log="${1:-echo}"

    $_log "Hardware Profile:"
    $_log "  CPU: ${HW_CPU_MODEL} (${HW_CORES} cores / ${HW_THREADS} threads)"
    $_log "  RAM: ${HW_RAM_GB} GB total, ${HW_RAM_AVAILABLE_GB} GB available"
    $_log "  Disk: ${HW_BOOT_DISK_TYPE} (${HW_BOOT_DISK_SIZE_GB} GB)"

    if [ "$HW_GPU_TYPE" != "none" ]; then
        $_log "  GPU (primary): ${HW_GPU_NAME} (${HW_GPU_TYPE})"
        if [ "$HW_AV1" = true ]; then
            $_log "  Encode: AV1 hardware (${HW_ENCODER}) — modern codec, best compression"
        else
            $_log "  Encode: HEVC hardware (${HW_ENCODER}) — good compression, wide support"
        fi
        if [ "$HW_DUAL_GPU" = true ]; then
            $_log "  GPU (secondary): ${HW_GPU2_NAME} (${HW_GPU2_TYPE}) — ${HW_GPU2_ENCODER}"
            $_log "  Dual-GPU mode: Tdarr will use both GPUs for parallel transcoding"
            if [ "${TDARR_DEDICATED:-false}" = "true" ]; then
                $_log "  TDARR_DEDICATED=true: discrete GPU is primary, iGPU is secondary"
            else
                $_log "  Default: iGPU is primary (shared with Plex), discrete is secondary"
                $_log "  Set TDARR_DEDICATED=true in .env to flip priority for dedicated transcode boxes"
            fi
        fi
    else
        $_log "  GPU: none detected — software encoding (${HW_ENCODER})"
        if [ "$HW_AV1" = true ]; then
            $_log "  Using SVT-AV1 (software) — good quality, leverages ${HW_CORES} cores"
        else
            $_log "  Using libx265 (software) — transcoding will be slow on ${HW_CORES} cores"
        fi
    fi

    $_log "  Tdarr: ${HW_TDARR_GPU_WORKERS} GPU + ${HW_TDARR_CPU_WORKERS} CPU workers"
    $_log "  Whisparr memory limit: ${HW_WHISPARR_MEM_LIMIT}"

    if [ "$HW_OPTICAL" = true ]; then
        $_log "  Optical: ${HW_OPTICAL_TYPE} drive at ${HW_OPTICAL_DEVICE}"
    fi
}
