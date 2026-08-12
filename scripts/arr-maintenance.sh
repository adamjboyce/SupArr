#!/bin/bash
# arr-maintenance.sh — Keep *arr apps healthy
# Was in jolly's personal crontab (0 */2 * * *), moved into the project 2026-08-12.
#
# CRON DISABLED as of 2026-08-12 (commented out in root's crontab, script left
# intact) — section 3's Commands-table truncate does a hard `docker stop`/
# `docker start` on Sonarr/Radarr/Whisparr/Lidarr. Confirmed as the cause of
# SAB's queue appearing to "purge": the app's Activity/Queue view fully
# resyncs against the download client after the bounce, which reads as the
# queue emptying. Command backlog >500 was happening on nearly every 2h run.
# Root cause of the backlog itself is still open. Disabled to observe whether
# anything breaks without it (unbounded Commands growth, qBit seed pileup,
# DownloadHistory bloat). See .mal/decisions.md and .mal/lessons-learned.md,
# 2026-08-12, before re-enabling.
#
# What it does:
# 1. Purges completed/seeding torrents from qBit (files stay on disk)
# 2. Trims download history older than 7 days (Sonarr, Whisparr)
# 3. Caps command queues — if any *arr has >500 backed up commands, truncate
#    (hard stop/truncate/start — this is the disabled part)
# 4. Ghost queue cleanup (ghost-cleanup.sh)

set -uo pipefail

COMPOSE_DIR="${COMPOSE_DIR:-/opt/suparr/machine2-arr}"
LOG="/opt/suparr/logs/arr-maintenance.log"
echo "$(date '+%Y-%m-%d %H:%M:%S') — Maintenance run" >> "$LOG"

# === 1. Purge seeding torrents from qBit ===
QBT="http://localhost:8080/api/v2"

QBIT_USERNAME="${QBIT_USERNAME:-}"
QBIT_PASSWORD="${QBIT_PASSWORD:-}"
if [ -z "$QBIT_PASSWORD" ] && [ -f "${COMPOSE_DIR}/.env" ]; then
    QBIT_USERNAME=$(grep '^QBIT_USERNAME=' "${COMPOSE_DIR}/.env" 2>/dev/null | cut -d'=' -f2- | tr -d "'" | tr -d '"' || true)
    QBIT_PASSWORD=$(grep '^QBIT_PASSWORD=' "${COMPOSE_DIR}/.env" 2>/dev/null | cut -d'=' -f2- | tr -d "'" | tr -d '"' || true)
fi
QBIT_USERNAME="${QBIT_USERNAME:-admin}"

curl -s -c /tmp/qb_maint.cookie "$QBT/auth/login" -d "username=${QBIT_USERNAME}&password=${QBIT_PASSWORD}" > /dev/null 2>&1

HASHES=$(curl -s -b /tmp/qb_maint.cookie "$QBT/torrents/info" | python3 -c '
import json, sys
torrents = json.loads(sys.stdin.read())
seeding = [t for t in torrents if t["state"] in ("queuedUP", "stalledUP", "pausedUP", "stoppedUP", "uploading", "forcedUP")]
if seeding:
    print("|".join(t["hash"] for t in seeding))
    print(len(seeding), file=sys.stderr)
' 2>/tmp/qb_count.txt)

COUNT=$(cat /tmp/qb_count.txt 2>/dev/null)
if [ -n "$HASHES" ]; then
    curl -s -b /tmp/qb_maint.cookie -X POST "$QBT/torrents/delete" \
        -d "hashes=$HASHES&deleteFiles=false"
    echo "  Purged $COUNT seeding torrents from qBit" >> "$LOG"
fi

# === 2. Trim download history ===
for DB in sonarr-main whisparr-main radarr-main lidarr-main; do
    RESULT=$(docker exec arr-postgres psql -U arr_admin -d "$DB" -t -c \
        "DELETE FROM \"DownloadHistory\" WHERE \"Date\" < NOW() - INTERVAL '7 days';" 2>/dev/null)
    COUNT=$(echo "$RESULT" | grep -oP '\d+' | head -1)
    if [ -n "$COUNT" ] && [ "$COUNT" -gt 0 ]; then
        echo "  $DB: trimmed $COUNT old history entries" >> "$LOG"
    fi
done

# === 3. Cap command queues ===
for DB in sonarr-main whisparr-main radarr-main lidarr-main; do
    CMD_COUNT=$(docker exec arr-postgres psql -U arr_admin -d "$DB" -t -c \
        'SELECT COUNT(*) FROM "Commands";' 2>/dev/null | tr -d ' ')
    if [ -n "$CMD_COUNT" ] && [ "$CMD_COUNT" -gt 500 ]; then
        echo "  $DB: $CMD_COUNT commands backed up — truncating" >> "$LOG"
        # Stop the app, truncate, start it
        APP=$(echo "$DB" | cut -d- -f1)
        docker stop "$APP" > /dev/null 2>&1
        docker exec arr-postgres psql -U arr_admin -d "$DB" -c 'TRUNCATE TABLE "Commands";' > /dev/null 2>&1
        docker start "$APP" > /dev/null 2>&1
        echo "  $DB: commands cleared, $APP restarted" >> "$LOG"
    fi
done

echo "  Done" >> "$LOG"

# === 4. Ghost queue cleanup ===
/opt/suparr/scripts/ghost-cleanup.sh >> "$LOG" 2>&1
