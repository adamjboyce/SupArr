#!/usr/bin/env bash
# =============================================================================
# NFS Stall Monitor — watches dmesg for NFS server failures
# =============================================================================
# Runs as a systemd service. Sends Discord alerts (if webhook configured)
# and logs all NFS events to /var/log/nfs-monitor.log.
#
# Install: deployed by init scripts or manually:
#   sudo cp nfs-monitor.sh /usr/local/bin/
#   sudo chmod +x /usr/local/bin/nfs-monitor.sh
#   sudo systemctl enable --now nfs-monitor
# =============================================================================

set -euo pipefail

LOGFILE="/var/log/nfs-monitor.log"
DISCORD_WEBHOOK_URL="${DISCORD_WEBHOOK_URL:-}"
MACHINE_NAME="${MACHINE_NAME:-$(hostname)}"
COOLDOWN_SECONDS=300  # Don't spam — 5 min cooldown between alerts

# Direct link health check (optional — set DIRECT_LINK_IP to enable)
DIRECT_LINK_IP="${DIRECT_LINK_IP:-}"
DIRECT_LINK_CHECK_INTERVAL="${DIRECT_LINK_CHECK_INTERVAL:-60}"

last_alert=0
last_link_alert=0
link_was_down=false

log() {
    local msg="[$(date '+%Y-%m-%d %H:%M:%S')] $1"
    echo "$msg" >> "$LOGFILE"
    echo "$msg"
}

send_discord() {
    local title="$1" description="$2" color="$3"
    [ -z "$DISCORD_WEBHOOK_URL" ] && return 0

    local payload
    payload=$(cat <<ENDJSON
{
  "embeds": [{
    "title": "$title",
    "description": "$description",
    "color": $color,
    "footer": {"text": "$MACHINE_NAME"},
    "timestamp": "$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
  }]
}
ENDJSON
)
    curl -sf -X POST "$DISCORD_WEBHOOK_URL" \
        -H "Content-Type: application/json" \
        -d "$payload" > /dev/null 2>&1 || true
}

alert() {
    local now
    now=$(date +%s)
    if (( now - last_alert < COOLDOWN_SECONDS )); then
        return 0
    fi
    last_alert=$now

    local event="$1"
    log "ALERT: $event"

    if [[ "$event" == *"not responding"* ]]; then
        send_discord \
            "NFS Stall Detected" \
            "$event\n\nDownload clients may be frozen. Check NAS health." \
            "15158332"  # red
    elif [[ "$event" == *"OK"* ]]; then
        send_discord \
            "NFS Recovered" \
            "$event\n\nNFS connection restored." \
            "3066993"   # green
    elif [[ "$event" == *"shutting down socket"* ]]; then
        send_discord \
            "NFS Socket Failure (NAS-side)" \
            "$event\n\nNFS server dropped a connection." \
            "15105570"  # orange
    fi
}

log "NFS monitor started on $MACHINE_NAME"

# ── Direct Link Health Check (background) ─────────────────────────────────
# Pings the direct-link NAS IP every N seconds. Alerts on failure + recovery.
# Only runs if DIRECT_LINK_IP is set (opt-in per machine).
direct_link_monitor() {
    local ip="$1"
    log "Direct link monitor enabled — checking $ip every ${DIRECT_LINK_CHECK_INTERVAL}s"

    while true; do
        if ping -c 1 -W 3 "$ip" > /dev/null 2>&1; then
            if [ "$link_was_down" = true ]; then
                log "Direct link to $ip RECOVERED"
                local now
                now=$(date +%s)
                if (( now - last_link_alert >= COOLDOWN_SECONDS )); then
                    last_link_alert=$now
                    send_discord \
                        "Direct Link Recovered" \
                        "10G DAC link to NAS ($ip) is back up.\n\nNFS traffic flowing over direct path." \
                        "3066993"   # green
                fi
                link_was_down=false
            fi
        else
            log "Direct link to $ip FAILED — ping timeout"
            link_was_down=true
            local now
            now=$(date +%s)
            if (( now - last_link_alert >= COOLDOWN_SECONDS )); then
                last_link_alert=$now
                send_discord \
                    "Direct Link DOWN" \
                    "10G DAC link to NAS ($ip) is unreachable.\n\nPossible causes:\n• NAS rebooted and lost rc.local config\n• DAC cable disconnected\n• NAS firmware update reset NIC config\n\nNFS mounts will fail. Check Booty enp0s1 config." \
                    "15158332"  # red
            fi
        fi
        sleep "$DIRECT_LINK_CHECK_INTERVAL"
    done
}

if [ -n "$DIRECT_LINK_IP" ]; then
    direct_link_monitor "$DIRECT_LINK_IP" &
    LINK_MONITOR_PID=$!
    trap "kill $LINK_MONITOR_PID 2>/dev/null" EXIT
fi

# ── dmesg NFS Event Watcher ───────────────────────────────────────────────
# Follow kernel messages for NFS events
dmesg --follow --level=emerg,alert,crit,err,warn,notice 2>/dev/null | while IFS= read -r line; do
    if [[ "$line" == *"nfs: server"*"not responding"* ]]; then
        alert "$line"
    elif [[ "$line" == *"nfs: server"*"OK"* ]]; then
        alert "$line"
    elif [[ "$line" == *"nfsd:"*"shutting down socket"* ]]; then
        alert "$line"
    fi
done
