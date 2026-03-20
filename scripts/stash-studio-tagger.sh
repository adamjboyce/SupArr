#!/usr/bin/env bash
# =============================================================================
# Stash Studio Tagger — auto-assign studios + generate previews
# =============================================================================
# Whisparr imports scenes to: /data/scenes/{Network}/{Studio}/{Scene}/file.ext
# Stash scan adds files but doesn't assign metadata or generate previews.
# This script:
#   1. Reads the directory structure and assigns studios automatically
#   2. Triggers preview/sprite/thumbnail generation for scenes missing them
#
# Runs on a configurable interval (default: 30 min). Only touches scenes
# under /data/scenes/ for studio tagging. Generation covers all scenes.
#
# Older scenes in /data/{Studio}/ (pre-Whisparr v3) are left alone for
# studio tagging — those are mostly amateur content without clean paths.
# =============================================================================
set -uo pipefail

STASH_URL="${STASH_URL:-http://stash:9999}"
CHECK_INTERVAL="${CHECK_INTERVAL:-1800}"  # 30 minutes
STASH_API_KEY="${STASH_API_KEY:-}"
GENERATE_COVERS="${GENERATE_COVERS:-true}"
GENERATE_SPRITES="${GENERATE_SPRITES:-true}"
GENERATE_PHASHES="${GENERATE_PHASHES:-true}"
GENERATE_PREVIEWS="${GENERATE_PREVIEWS:-false}"

log()  { echo "[$(date '+%Y-%m-%d %H:%M:%S')] [OK] $1"; }
warn() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] [!!] $1"; }

# ── GraphQL helper ────────────────────────────────────────────────────────────
gql() {
    local query="$1"
    local headers=(-H "Content-Type: application/json")
    if [ -n "$STASH_API_KEY" ]; then
        headers+=(-H "ApiKey: $STASH_API_KEY")
    fi
    curl -sf "${STASH_URL}/graphql" "${headers[@]}" \
        -d "{\"query\": $(echo "$query" | jq -Rs .)}" 2>/dev/null
}

# ── Find or create a studio by name ──────────────────────────────────────────
find_or_create_studio() {
    local studio_name="$1"

    # Search for exact match
    local result
    result=$(gql "{ findStudios(studio_filter: { name: { value: \"${studio_name}\", modifier: EQUALS } }) { studios { id } } }")
    local studio_id
    studio_id=$(echo "$result" | jq -r '.data.findStudios.studios[0].id // empty')

    if [ -n "$studio_id" ]; then
        echo "$studio_id"
        return
    fi

    # Create it
    result=$(gql "mutation { studioCreate(input: { name: \"${studio_name}\" }) { id } }")
    studio_id=$(echo "$result" | jq -r '.data.studioCreate.id // empty')

    if [ -n "$studio_id" ]; then
        log "  Created studio: ${studio_name} (ID: ${studio_id})"
        echo "$studio_id"
    else
        warn "  Failed to create studio: ${studio_name}"
    fi
}

# ── Studio tagging pass ──────────────────────────────────────────────────────
tag_studios() {
    log "Checking for untagged Whisparr scenes..."

    # Fetch all scenes with no studio under /data/scenes/
    local result
    result=$(gql '{
        findScenes(
            scene_filter: {
                studios: { modifier: IS_NULL }
                path: { value: "/data/scenes/", modifier: INCLUDES }
            }
            filter: { per_page: -1 }
        ) {
            count
            scenes { id files { path } }
        }
    }')

    local count
    count=$(echo "$result" | jq -r '.data.findScenes.count // 0')

    if [ "$count" -eq 0 ]; then
        log "No untagged scenes found"
        return
    fi

    log "Found ${count} untagged scene(s)"

    # Build a map: studio_name → [scene_ids]
    # Two path formats from Whisparr:
    #   7 parts: /data/scenes/{Network}/{Studio}/{Scene Dir}/file.ext → studio at [4]
    #   6 parts: /data/scenes/{Studio}/{Scene Dir}/file.ext           → studio at [3]
    # Detect by checking if [4] starts with a date (YYYY-MM-DD), which means it's
    # a scene dir, not a studio name.
    local assignments
    assignments=$(echo "$result" | jq -r '
        .data.findScenes.scenes[] |
        . as $scene |
        .files[0].path |
        split("/") |
        if length >= 7 and (.[4] | test("^\\d{4}-\\d{2}-\\d{2}") | not) then
            "\(.[4])\t\($scene.id)"
        elif length >= 6 then
            "\(.[3])\t\($scene.id)"
        else
            empty
        end
    ')

    if [ -z "$assignments" ]; then
        warn "Could not parse studio from any scene paths"
        return
    fi

    # Process unique studios
    local tagged=0

    while IFS=$'\t' read -r studio_name scene_id; do
        # Find or create studio (cache lookups within this pass)
        local studio_id=""
        local cache_key="cache_$(echo "$studio_name" | md5sum | cut -c1-8)"
        studio_id="${!cache_key:-}"

        if [ -z "$studio_id" ]; then
            studio_id=$(find_or_create_studio "$studio_name")
            if [ -n "$studio_id" ]; then
                printf -v "$cache_key" '%s' "$studio_id"
            fi
        fi

        if [ -z "$studio_id" ]; then
            warn "  Skipping scene ${scene_id} — couldn't resolve studio '${studio_name}'"
            continue
        fi

        # Assign
        local update_result
        update_result=$(gql "mutation { sceneUpdate(input: { id: \"${scene_id}\", studio_id: \"${studio_id}\" }) { id } }")

        if echo "$update_result" | jq -e '.data.sceneUpdate.id' > /dev/null 2>&1; then
            tagged=$((tagged + 1))
        else
            warn "  Failed to assign scene ${scene_id} to studio '${studio_name}'"
        fi
    done <<< "$assignments"

    log "Tagged ${tagged}/${count} scene(s)"
}

# ── Generate missing previews/sprites/covers ─────────────────────────────────
generate_missing() {
    log "Triggering generation pass (overwrite=false, skips existing)..."

    # Trigger a full generate with overwrite=false — Stash skips scenes that
    # already have generated content, so this is cheap when everything is current.
    # Stash's is_missing filter is unreliable (checks DB flags, not actual files),
    # so we let Stash's own generation logic decide what needs work.
    local gen_result
    gen_result=$(gql "mutation {
        metadataGenerate(input: {
            covers: ${GENERATE_COVERS}
            sprites: ${GENERATE_SPRITES}
            phashes: ${GENERATE_PHASHES}
            previews: ${GENERATE_PREVIEWS}
            overwrite: false
        })
    }")

    if echo "$gen_result" | jq -e '.data.metadataGenerate' > /dev/null 2>&1; then
        log "Generation task queued"
    else
        warn "Failed to trigger generation: $(echo "$gen_result" | jq -r '.errors[0].message // "unknown error"')"
    fi
}

# ── Entry point ───────────────────────────────────────────────────────────────
log "Stash Studio Tagger started"
log "Stash URL: ${STASH_URL} | Interval: ${CHECK_INTERVAL}s"
log "Generate — covers: ${GENERATE_COVERS} | sprites: ${GENERATE_SPRITES} | phashes: ${GENERATE_PHASHES} | previews: ${GENERATE_PREVIEWS}"

# Wait for Stash to be ready
for i in $(seq 1 30); do
    if curl -sf "${STASH_URL}" > /dev/null 2>&1; then
        break
    fi
    if [ "$i" -eq 30 ]; then
        warn "Stash not reachable after 30 attempts — exiting"
        exit 1
    fi
    sleep 2
done

# Run immediately, then loop
tag_studios
generate_missing
while true; do
    sleep "$CHECK_INTERVAL"
    tag_studios
    generate_missing
done
