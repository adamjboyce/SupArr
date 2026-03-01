#!/usr/bin/env bash
# =============================================================================
# Media Library Migration — Scan, Map & Copy
# =============================================================================
# Maps existing media folder names to *arr media categories and copies
# content via rsync. Default mode is dry-run preview. Pass "execute" to copy.
#
# Usage (via Docker Compose):
#   Preview:  docker compose --profile migration run --rm media-migration
#   Execute:  docker compose --profile migration run --rm media-migration execute
#
# Mounts:
#   /source  → existing library (read-only)
#   /media   → *arr media root (read-write)
# =============================================================================

set -euo pipefail

# Colors
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
CYAN='\033[0;36m'; BOLD='\033[1m'; DIM='\033[2m'; NC='\033[0m'

log()  { echo -e "${GREEN}[✓]${NC} $1"; }
warn() { echo -e "${YELLOW}[!]${NC} $1"; }
err()  { echo -e "${RED}[✗]${NC} $1"; }
info() { echo -e "${CYAN}[→]${NC} $1"; }

MODE="${1:-preview}"
OWNER="${PUID:-1000}:${PGID:-1000}"

# ==========================================================================
# Phase 1: Scan source library
# ==========================================================================

echo ""
echo -e "${BOLD}═══════════════════════════════════════════${NC}"
echo -e "${BOLD}  Media Library Migration${NC}"
echo -e "${BOLD}═══════════════════════════════════════════${NC}"
echo ""

if [ ! -d /source ] || [ -z "$(ls -A /source 2>/dev/null)" ]; then
    err "Source mount /source is empty or missing."
    err "Check that your migration source path is mounted correctly."
    exit 1
fi

info "Scanning source library at /source..."
echo ""
echo -e "  ${BOLD}Source Folders:${NC}"
echo ""

# Collect top-level directories
declare -a SRC_DIRS=()
while IFS= read -r dir; do
    SRC_DIRS+=("$dir")
done < <(find /source -maxdepth 1 -mindepth 1 -type d | sed 's|.*/||' | sort)

if [ ${#SRC_DIRS[@]} -eq 0 ]; then
    err "No subdirectories found in /source"
    exit 1
fi

for dir in "${SRC_DIRS[@]}"; do
    size=$(du -sh "/source/$dir" 2>/dev/null | cut -f1)
    count=$(find "/source/$dir" -type f 2>/dev/null | wc -l)
    printf "    %-30s %8s  (%s files)\n" "$dir" "$size" "$count"
done
echo ""

# ==========================================================================
# Phase 2: Map folders to *arr categories
# ==========================================================================

info "Mapping folders to media categories..."
echo ""

declare -A MAPPINGS=()
declare -a SKIPPED=()

map_folder() {
    local dir="$1"
    local lower
    lower=$(echo "$dir" | tr '[:upper:]' '[:lower:]')

    case "$lower" in
        anime\ movie*|anime-movie*|animemovie*)
            MAPPINGS["$dir"]="anime-movies" ;;
        movie*|film*)
            MAPPINGS["$dir"]="movies" ;;
        tv*|series|shows)
            MAPPINGS["$dir"]="tv" ;;
        anime)
            MAPPINGS["$dir"]="anime" ;;
        documentar*)
            MAPPINGS["$dir"]="documentaries" ;;
        stand*up|stand-up|standup|comedy\ special*)
            MAPPINGS["$dir"]="stand-up" ;;
        concert*|live\ *)
            MAPPINGS["$dir"]="concerts" ;;
        music|albums|flac)
            MAPPINGS["$dir"]="music" ;;
        book*|ebook*)
            MAPPINGS["$dir"]="books" ;;
        audiobook*)
            MAPPINGS["$dir"]="audiobooks" ;;
        adult|porn|xxx)
            MAPPINGS["$dir"]="adult" ;;
        *)
            SKIPPED+=("$dir") ;;
    esac
}

for dir in "${SRC_DIRS[@]}"; do
    map_folder "$dir"
done

# Display mapping table
if [ ${#MAPPINGS[@]} -gt 0 ]; then
    echo -e "  ${BOLD}Mapped:${NC}"
    for src in "${!MAPPINGS[@]}"; do
        dest="${MAPPINGS[$src]}"
        printf "    ${GREEN}%-30s → /media/%s${NC}\n" "$src" "$dest"
    done
    echo ""
fi

if [ ${#SKIPPED[@]} -gt 0 ]; then
    echo -e "  ${YELLOW}Skipped (unrecognized — use FileBot for these):${NC}"
    for dir in "${SKIPPED[@]}"; do
        printf "    ${YELLOW}%-30s → SKIPPED${NC}\n" "$dir"
    done
    echo ""
fi

if [ ${#MAPPINGS[@]} -eq 0 ]; then
    warn "No folders matched known media categories."
    warn "Use FileBot (http://localhost:5800) for manual organization."
    exit 0
fi

# ==========================================================================
# Phase 3: Preview (rsync dry-run)
# ==========================================================================

echo -e "${BOLD}═══════════════════════════════════════════${NC}"
if [ "$MODE" = "execute" ]; then
    echo -e "${BOLD}  Mode: EXECUTE (copying files)${NC}"
else
    echo -e "${BOLD}  Mode: PREVIEW (dry-run, no files copied)${NC}"
fi
echo -e "${BOLD}═══════════════════════════════════════════${NC}"
echo ""

for src in "${!MAPPINGS[@]}"; do
    dest="${MAPPINGS[$src]}"
    echo -e "  ${CYAN}${src} → /media/${dest}${NC}"

    if [ "$MODE" = "execute" ]; then
        # Phase 4: Execute — rsync with chown, resumable, no --delete
        rsync -avhP --stats --chown="${OWNER}" \
            "/source/${src}/" "/media/${dest}/" 2>&1 | tail -5
    else
        # Preview — dry-run stats only
        rsync --dry-run --stats -ah \
            "/source/${src}/" "/media/${dest}/" 2>&1 | \
            grep -E "^(Number of|Total file size|Total transferred)"
    fi
    echo ""
done

# ==========================================================================
# Phase 5: Trigger *arr library scans (execute mode only)
# ==========================================================================

if [ "$MODE" = "execute" ]; then
    echo -e "${BOLD}═══════════════════════════════════════════${NC}"
    echo -e "${BOLD}  Triggering Library Scans${NC}"
    echo -e "${BOLD}═══════════════════════════════════════════${NC}"
    echo ""

    trigger_scan() {
        local name="$1" host="$2" port="$3" api_ver="$4" api_key="$5" command="$6"
        if [ -z "$api_key" ]; then return; fi
        local url="http://${host}:${port}/api/${api_ver}/command"
        local result
        result=$(curl -sf -X POST "$url" \
            -H "X-Api-Key: $api_key" \
            -H "Content-Type: application/json" \
            -d "{\"name\": \"${command}\"}" 2>/dev/null) && \
            log "${name}: library scan triggered" || \
            warn "${name}: could not trigger scan (may not be running)"
    }

    trigger_scan "Radarr"  "radarr"  7878 "v3" "${RADARR_API_KEY:-}"  "RescanMovie"
    trigger_scan "Sonarr"  "sonarr"  8989 "v3" "${SONARR_API_KEY:-}"  "RescanSeries"
    trigger_scan "Lidarr"  "lidarr"  8686 "v1" "${LIDARR_API_KEY:-}"  "RescanArtist"
    trigger_scan "Bookshelf" "bookshelf" 8787 "v1" "${BOOKSHELF_API_KEY:-}" "RescanAuthor"
    echo ""
fi

# ==========================================================================
# Summary
# ==========================================================================

if [ "$MODE" = "execute" ]; then
    log "Migration complete! Files copied and library scans triggered."
    echo -e "  ${DIM}Check *arr Activity tabs for scan progress.${NC}"
else
    echo -e "${BOLD}═══════════════════════════════════════════${NC}"
    echo -e "${BOLD}  Preview Complete — No Files Copied${NC}"
    echo -e "${BOLD}═══════════════════════════════════════════${NC}"
    echo ""
    echo -e "  To execute the migration:"
    echo -e "  ${BOLD}docker compose --profile migration run --rm media-migration execute${NC}"
    echo ""
    echo -e "  ${DIM}rsync is resumable — safe to re-run if interrupted.${NC}"
    echo -e "  ${DIM}Unrecognized folders can be handled via FileBot UI.${NC}"
fi
echo ""
