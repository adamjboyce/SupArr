#!/usr/bin/env bash
# =============================================================================
# Stash Watchdog — detect and clear a wedged scan/generate job
# =============================================================================
# Runs on the host via cron (Spyglass), not inside a container — needs plain
# `docker restart`, no docker.sock exposure to stash-tagger required.
#
# Stash's job queue can wedge: a job sits in RUNNING or STOPPING with no
# progress indefinitely, blocking every job queued behind it. This happened
# for 3 days undetected (2026-07-11 to 2026-07-14) before anyone noticed
# nothing new was showing up. A restart clears it — nothing else does.
#
# Install:
#   crontab -e
#   */30 * * * * /opt/suparr/scripts/stash-watchdog.sh >> /var/log/stash-watchdog.log 2>&1
# =============================================================================
set -uo pipefail

STASH_URL="${STASH_URL:-http://localhost:9999}"
STUCK_THRESHOLD_SECONDS="${STASH_STUCK_THRESHOLD_SECONDS:-3600}"  # 1 hour

# Resolve webhook: alerts webhook takes priority, fall back to content webhook
COMPOSE_DIR="${COMPOSE_DIR:-/opt/suparr/machine1-plex}"
DISCORD_WEBHOOK_URL="${DISCORD_ALERTS_WEBHOOK_URL:-}"
if [ -z "$DISCORD_WEBHOOK_URL" ] && [ -f "${COMPOSE_DIR}/.env" ]; then
    DISCORD_WEBHOOK_URL=$(grep '^DISCORD_ALERTS_WEBHOOK_URL=' "${COMPOSE_DIR}/.env" 2>/dev/null | cut -d'=' -f2- | tr -d "'" | tr -d '"' || true)
fi
if [ -z "$DISCORD_WEBHOOK_URL" ] && [ -f "${COMPOSE_DIR}/.env" ]; then
    DISCORD_WEBHOOK_URL=$(grep '^DISCORD_WEBHOOK_URL=' "${COMPOSE_DIR}/.env" 2>/dev/null | cut -d'=' -f2- | tr -d "'" | tr -d '"' || true)
fi

log()  { echo "[$(date '+%Y-%m-%d %H:%M:%S')] [OK] $1"; }
warn() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] [!!] $1"; }

notify_discord() {
    local message="$1"
    [ -z "$DISCORD_WEBHOOK_URL" ] && return
    local payload
    payload=$(jq -n --arg c "$message" --arg u "Stash Watchdog" '{username: $u, content: $c}') 2>/dev/null || return
    curl -sf -X POST "$DISCORD_WEBHOOK_URL" \
        -H "Content-Type: application/json" \
        -d "$payload" > /dev/null 2>&1 || true
}

gql() {
    curl -sf "${STASH_URL}/graphql" -H "Content-Type: application/json" \
        -d "{\"query\": $(echo "$1" | jq -Rs .)}" 2>/dev/null
}

if ! curl -sf --connect-timeout 5 "$STASH_URL" > /dev/null 2>&1; then
    warn "Stash unreachable at ${STASH_URL} — container may be down"
    notify_discord "**Stash unreachable** at ${STASH_URL} — container may be down. Check \`docker ps\` on Spyglass."
    exit 1
fi

queue=$(gql '{ jobQueue { id status description startTime } }')

stuck_id=$(echo "$queue" | jq -r --argjson threshold "$STUCK_THRESHOLD_SECONDS" '
    .data.jobQueue[]?
    | select(.status == "RUNNING" or .status == "STOPPING")
    | select(.startTime != null)
    | select((now - (.startTime | sub("\\.[0-9]+Z$"; "Z") | fromdateiso8601)) > $threshold)
    | .id
' 2>/dev/null | head -1)

if [ -z "$stuck_id" ]; then
    log "No stuck jobs found"
    exit 0
fi

stuck_desc=$(echo "$queue" | jq -r --arg id "$stuck_id" '.data.jobQueue[] | select(.id == $id) | .description')

warn "Job ${stuck_id} (${stuck_desc}) has been running longer than ${STUCK_THRESHOLD_SECONDS}s — restarting Stash"
notify_discord "**Stash job stuck** — \"${stuck_desc}\" (job ${stuck_id}) running longer than $((STUCK_THRESHOLD_SECONDS / 60)) min. Restarting Stash container to clear the queue."

docker restart stash > /dev/null 2>&1

for i in $(seq 1 30); do
    curl -sf --connect-timeout 5 "$STASH_URL" > /dev/null 2>&1 && break
    sleep 2
done

if curl -sf --connect-timeout 5 "$STASH_URL" > /dev/null 2>&1; then
    log "Stash restarted and reachable again"
    notify_discord "**Stash restarted** — back up after clearing stuck job ${stuck_id}."
else
    warn "Stash still unreachable after restart"
    notify_discord "**Stash restart FAILED** — still unreachable after restart attempt. Manual intervention required."
fi
