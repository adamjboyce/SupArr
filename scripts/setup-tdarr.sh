#!/usr/bin/env bash
# =============================================================================
# Tdarr Automated Setup — Hardware-detected flow pipeline + libraries
# =============================================================================
# Detects GPU hardware, creates appropriate transcode flow, seeds libraries.
# Called from init script after Tdarr container is running.
#
# Hardware detection priority:
#   1. Intel QSV (iGPU, /dev/dri/renderD128) → hevc_qsv
#   2. NVIDIA NVENC (nvidia-smi) → hevc_nvenc
#   3. CPU fallback → libx265
# =============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
SEED_DIR="$SCRIPT_DIR/../config-seeds/tdarr"
TDARR_URL="${TDARR_URL:-http://localhost:8265}"

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
CYAN='\033[0;36m'; BOLD='\033[1m'; NC='\033[0m'
log()  { echo -e "${GREEN}[✓]${NC} $1"; }
warn() { echo -e "${YELLOW}[!]${NC} $1"; }
info() { echo -e "${CYAN}[→]${NC} $1"; }

# ── Hardware Detection ────────────────────────────────────────────────────
# If HW_* variables are exported from detect-hardware.sh (sourced by init
# script), use them. Otherwise fall back to local detection.
detect_hardware() {
    if [ -n "${HW_GPU_TYPE:-}" ]; then
        echo "$HW_GPU_TYPE"
        return
    fi
    # Fallback for standalone runs
    if [ -e /dev/dri/renderD128 ]; then
        if lspci 2>/dev/null | grep -qi 'Intel.*Graphics\|Intel.*UHD\|Intel.*Iris'; then
            echo "qsv"
            return
        fi
    fi
    if command -v nvidia-smi &>/dev/null && nvidia-smi --query-gpu=name --format=csv,noheader &>/dev/null; then
        echo "nvenc"
        return
    fi
    echo "cpu"
}

# ── Wait for Tdarr API ────────────────────────────────────────────────────
wait_for_tdarr() {
    local attempts=20
    for i in $(seq 1 $attempts); do
        if curl -sf -o /dev/null "${TDARR_URL}/api/v2/cruddb" -X POST \
            -H "Content-Type: application/json" \
            -d '{"data":{"collection":"SettingsGlobalJSONDB","mode":"getAll"}}' 2>/dev/null; then
            return 0
        fi
        sleep 3
    done
    return 1
}

# ── API Helper ────────────────────────────────────────────────────────────
tdarr_api() {
    local collection="$1" mode="$2" docID="${3:-}" doc="${4:-}"
    local payload
    if [ -n "$docID" ] && [ -n "$doc" ]; then
        payload="{\"data\":{\"collection\":\"${collection}\",\"mode\":\"${mode}\",\"docID\":\"${docID}\",\"doc\":${doc}}}"
    elif [ -n "$docID" ]; then
        payload="{\"data\":{\"collection\":\"${collection}\",\"mode\":\"${mode}\",\"docID\":\"${docID}\"}}"
    else
        payload="{\"data\":{\"collection\":\"${collection}\",\"mode\":\"${mode}\"}}"
    fi
    curl -sf "${TDARR_URL}/api/v2/cruddb" -X POST \
        -H "Content-Type: application/json" \
        -d "$payload" 2>/dev/null
}

# ── Main ──────────────────────────────────────────────────────────────────
info "Configuring Tdarr..."

# Detect hardware
HW_TYPE=$(detect_hardware)
info "Hardware detected: ${BOLD}${HW_TYPE}${NC}"

# Use pre-detected values from detect-hardware.sh if available
if [ -n "${HW_ENCODER:-}" ]; then
    ENCODER="$HW_ENCODER"
    PLUGIN="$HW_TDARR_PLUGIN"
    TARGET_CODEC="${HW_CODEC:-hevc}"
else
    # Fallback codec selection for standalone runs
    TARGET_CODEC="hevc"
    case "$HW_TYPE" in
        qsv)   ENCODER="hevc_qsv";   PLUGIN="Community:Tdarr_Plugin_bsh1_Boosh_FFMPEG_QSV_HEVC" ;;
        nvenc) ENCODER="hevc_nvenc";  PLUGIN="Community:Tdarr_Plugin_bsh1_Boosh_FFMPEG_NVENC_HEVC" ;;
        cpu)   ENCODER="libx265";     PLUGIN="Community:Tdarr_Plugin_bsh1_Boosh_FFMPEG_CPU_HEVC" ;;
    esac
fi

FLOW_NAME="SupArr ${HW_TYPE^^} ${TARGET_CODEC^^} Pipeline"
FLOW_ID="suparr_${HW_TYPE}_${TARGET_CODEC}"

# Schedule from .env
case "${TDARR_SCHEDULE:-offhours}" in
    always)
        SCHEDULE_JSON='[]'  # empty = always active
        ;;
    overnight)
        # 12 AM - 8 AM every day
        SCHEDULE_JSON='[{"day":0,"startHour":0,"endHour":8},{"day":1,"startHour":0,"endHour":8},{"day":2,"startHour":0,"endHour":8},{"day":3,"startHour":0,"endHour":8},{"day":4,"startHour":0,"endHour":8},{"day":5,"startHour":0,"endHour":8},{"day":6,"startHour":0,"endHour":8}]'
        ;;
    *)  # offhours (default): 1 AM - 5 PM
        SCHEDULE_JSON='[{"day":0,"startHour":1,"endHour":17},{"day":1,"startHour":1,"endHour":17},{"day":2,"startHour":1,"endHour":17},{"day":3,"startHour":1,"endHour":17},{"day":4,"startHour":1,"endHour":17},{"day":5,"startHour":1,"endHour":17},{"day":6,"startHour":1,"endHour":17}]'
        ;;
esac

# Wait for Tdarr
if ! wait_for_tdarr; then
    warn "Tdarr API not responding at ${TDARR_URL} — skipping setup"
    exit 0
fi

# Check if flow already exists
EXISTING_FLOWS=$(tdarr_api "FlowsJSONDB" "getAll")
if echo "$EXISTING_FLOWS" | python3 -c "import sys,json; flows=json.load(sys.stdin); exit(0 if any(f.get('_id')=='${FLOW_ID}' for f in flows) else 1)" 2>/dev/null; then
    log "Tdarr: flow '${FLOW_NAME}' already exists"
else
    # Load seed flow and adjust for hardware
    if [ -f "$SEED_DIR/flows.json" ]; then
        FLOW_DOC=$(python3 -c "
import json, sys
flows = json.load(open('${SEED_DIR}/flows.json'))
flow = flows[0]  # Use first flow as template
flow['_id'] = '${FLOW_ID}'
flow['name'] = '${FLOW_NAME}'
# Update the transcode step
for step in flow.get('flowPlugins', []):
    if 'transcode' in step.get('name', '').lower() or 'QSV' in step.get('name', '') or 'NVENC' in step.get('name', ''):
        step['inputsDB']['pluginSourceId'] = '${PLUGIN}'
        step['inputsDB']['encoder'] = '${ENCODER}'
        step['name'] = '${HW_TYPE} HEVC Transcode'.replace('qsv','QSV').replace('nvenc','NVENC').replace('cpu','CPU')
print(json.dumps(flow))
" 2>/dev/null)

        if [ -n "$FLOW_DOC" ]; then
            tdarr_api "FlowsJSONDB" "insert" "$FLOW_ID" "$FLOW_DOC" > /dev/null
            log "Tdarr: flow '${FLOW_NAME}' created (encoder: ${ENCODER})"
        else
            warn "Tdarr: could not generate flow from seed"
        fi
    else
        warn "Tdarr: flow seed not found at ${SEED_DIR}/flows.json"
    fi
fi

# Check if libraries exist
EXISTING_LIBS=$(tdarr_api "LibrarySettingsJSONDB" "getAll")
LIB_COUNT=$(echo "$EXISTING_LIBS" | python3 -c "import sys,json; print(len(json.load(sys.stdin)))" 2>/dev/null || echo "0")

if [ "${LIB_COUNT:-0}" -gt 0 ]; then
    log "Tdarr: ${LIB_COUNT} libraries already configured"
else
    # Seed libraries from template
    if [ -f "$SEED_DIR/libraries.json" ]; then
        python3 -c "
import json, subprocess
libs = json.load(open('${SEED_DIR}/libraries.json'))
for lib in libs:
    # Update flow reference to match detected hardware
    lib['flowId'] = '${FLOW_ID}'
    lib['schedule'] = json.loads('${SCHEDULE_JSON}')
    doc = json.dumps(lib)
    subprocess.run([
        'curl', '-sf', '${TDARR_URL}/api/v2/cruddb', '-X', 'POST',
        '-H', 'Content-Type: application/json',
        '-d', json.dumps({'data':{'collection':'LibrarySettingsJSONDB','mode':'insert','docID':lib['_id'],'doc':lib}})
    ], capture_output=True, timeout=10)
print(f'Seeded {len(libs)} libraries')
" 2>/dev/null && log "Tdarr: libraries seeded with flow '${FLOW_ID}'" || \
            warn "Tdarr: could not seed libraries"
    else
        warn "Tdarr: library seed not found at ${SEED_DIR}/libraries.json"
    fi
fi

# --- Dual-GPU: create second worker if available ---
if [ "${HW_DUAL_GPU:-false}" = "true" ] && [ -n "${HW_GPU2_TYPE:-}" ]; then
    info "Configuring second GPU worker (${HW_GPU2_TYPE}: ${HW_GPU2_ENCODER:-})..."

    # Check if a second node already exists
    EXISTING_NODES=$(tdarr_api "NodeSettingsJSONDB" "getAll" 2>/dev/null || echo "{}")
    NODE_COUNT=$(echo "$EXISTING_NODES" | python3 -c "import sys,json; print(len(json.load(sys.stdin)))" 2>/dev/null || echo "0")

    if [ "${NODE_COUNT:-0}" -lt 2 ]; then
        # Configure the internal node to use both GPUs
        # Tdarr's internal node supports multiple GPU workers via the server settings
        tdarr_api "SettingsGlobalJSONDB" "update" "settings" "{
            \"gpuWorkers\": ${HW_TDARR_GPU_WORKERS:-2},
            \"cpuWorkers\": ${HW_TDARR_CPU_WORKERS:-1}
        }" > /dev/null 2>&1 && \
            log "Tdarr: dual-GPU workers configured (${HW_TDARR_GPU_WORKERS:-2} GPU + ${HW_TDARR_CPU_WORKERS:-1} CPU)" || \
            warn "Tdarr: could not configure dual-GPU workers"
    else
        log "Tdarr: multiple nodes already configured"
    fi
fi

log "Tdarr setup complete (hardware: ${HW_TYPE}, encoder: ${ENCODER})"
