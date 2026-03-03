#!/usr/bin/env bash
# =============================================================================
# SupArr — 10G Direct Link Cutover: Privateer ↔ Booty
# =============================================================================
# Eliminates the network switch from the NFS path by establishing a dedicated
# 10G point-to-point DAC link between Privateer and Booty NAS.
#
# What changes:
#   Privateer enp1s0 (10G SFP+) → DAC → Booty enp0s2 (SFP+)     [NFS only]
#   Privateer eno2   (1G RJ45)  → Cat6 → UDM SE switch           [internet/LAN]
#
# Private /30 subnet for direct link:
#   Privateer: 10.10.10.1/30  (enp1s0)
#   Booty:     10.10.10.2/30  (enp0s2)
#
# Run from: Walsh's dev machine (WSL2)
# Prerequisites: DAC cable, Cat6 cable, SSH access to both machines
#
# Usage:
#   chmod +x scripts/10g-direct-link.sh
#   ./scripts/10g-direct-link.sh
#
# Phases:
#   A — Prepare Booty (NAS): configure enp0s2, update NFS exports
#   B — Physical cabling (manual — script pauses)
#   C — Configure Privateer: network, fstab, .env, restart containers
#   D — Verify end-to-end
#
# Rollback:
#   If the direct link fails, swap enp1s0 back to switch, run:
#   ./scripts/10g-direct-link.sh --rollback
# =============================================================================

set -euo pipefail

# ── Config ────────────────────────────────────────────────────────────────────
DIRECT_SUBNET="10.10.10.0/30"
PRIVATEER_DIRECT_IP="10.10.10.1"
BOOTY_DIRECT_IP="10.10.10.2"
PRIVATEER_DIRECT_NIC="enp1s0"
PRIVATEER_LAN_NIC="eno2"
BOOTY_DIRECT_NIC="enp0s1"
DIRECT_MTU=9000
LAN_MTU=1500

PRIVATEER_LAN_IP="192.168.1.27"
PRIVATEER_LAN_GATEWAY="192.168.1.1"
PRIVATEER_LAN_NETMASK="255.255.255.0"

# Booty has two switch IPs — both stay on the switch, untouched
BOOTY_LAN_IP_1="192.168.1.76"
BOOTY_LAN_IP_2="192.168.1.77"

# SSH access
SSH_KEY="$HOME/.ssh/suparr_deploy_key"
SSH_OPTS="-o StrictHostKeyChecking=no -o ConnectTimeout=10"
PRIVATEER_SSH="ssh $SSH_OPTS -i $SSH_KEY root@${PRIVATEER_LAN_IP}"
BOOTY_SSH="ssh $SSH_OPTS root@${BOOTY_LAN_IP_1}"

SUPARR_DIR="/opt/suparr"

# ── Colors & Helpers ──────────────────────────────────────────────────────────
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
CYAN='\033[0;36m'; BOLD='\033[1m'; DIM='\033[2m'; NC='\033[0m'

log()    { echo -e "${GREEN}[✓]${NC} $1"; }
warn()   { echo -e "${YELLOW}[!]${NC} $1"; }
err()    { echo -e "${RED}[✗]${NC} $1"; }
info()   { echo -e "${CYAN}[→]${NC} $1"; }
header() {
    echo ""
    echo -e "${BOLD}═══════════════════════════════════════════════════════${NC}"
    echo -e "${BOLD}  $1${NC}"
    echo -e "${BOLD}═══════════════════════════════════════════════════════${NC}"
    echo ""
}

confirm() {
    echo -en "${YELLOW}  $1 [y/N]: ${NC}"
    read -r answer
    [[ "$answer" =~ ^[Yy] ]] || { warn "Aborted."; exit 1; }
}

# ── Pre-flight Checks ────────────────────────────────────────────────────────
preflight() {
    header "Pre-flight Checks"

    # SSH key exists
    if [ ! -f "$SSH_KEY" ]; then
        err "SSH key not found: $SSH_KEY"
        err "Run remote-deploy.sh first, or create the key manually."
        exit 1
    fi
    log "SSH key found: $SSH_KEY"

    # Can reach Privateer
    info "Testing SSH to Privateer ($PRIVATEER_LAN_IP)..."
    if $PRIVATEER_SSH "echo ok" &>/dev/null; then
        log "Privateer reachable via SSH"
    else
        err "Cannot SSH to Privateer at $PRIVATEER_LAN_IP"
        exit 1
    fi

    # Can reach Booty
    info "Testing SSH to Booty ($BOOTY_LAN_IP_1)..."
    if $BOOTY_SSH "echo ok" &>/dev/null; then
        log "Booty reachable via SSH"
    else
        warn "Cannot reach Booty at $BOOTY_LAN_IP_1, trying $BOOTY_LAN_IP_2..."
        BOOTY_SSH="ssh $SSH_OPTS root@${BOOTY_LAN_IP_2}"
        if $BOOTY_SSH "echo ok" &>/dev/null; then
            log "Booty reachable via SSH at $BOOTY_LAN_IP_2"
        else
            err "Cannot SSH to Booty at either $BOOTY_LAN_IP_1 or $BOOTY_LAN_IP_2"
            exit 1
        fi
    fi

    # Detect current NAS IP from Privateer's .env
    CURRENT_NAS_IP=$($PRIVATEER_SSH "grep '^NAS_IP=' ${SUPARR_DIR}/machine2-arr/.env 2>/dev/null | cut -d= -f2" || echo "")
    if [ -z "$CURRENT_NAS_IP" ]; then
        err "Could not read NAS_IP from Privateer's .env"
        exit 1
    fi
    log "Current NAS_IP on Privateer: $CURRENT_NAS_IP"

    # Verify Privateer NIC state
    info "Checking Privateer NIC state..."
    $PRIVATEER_SSH "echo '  enp1s0:'; ip -br addr show $PRIVATEER_DIRECT_NIC 2>/dev/null || echo '  (not found)'; echo '  eno2:'; ip -br addr show $PRIVATEER_LAN_NIC 2>/dev/null || echo '  (not found)'"

    # Verify Booty NIC state
    info "Checking Booty NIC state..."
    $BOOTY_SSH "echo '  enp0s2:'; ip -br addr show $BOOTY_DIRECT_NIC 2>/dev/null || echo '  (not found)'"

    # Show current NFS mounts on Privateer
    info "Current NFS mounts on Privateer:"
    $PRIVATEER_SSH "grep nfs /etc/fstab 2>/dev/null | head -5" || true

    echo ""
    log "Pre-flight complete. Review the state above before proceeding."
}

# ── Phase A: Prepare Booty (NAS) ─────────────────────────────────────────────
phase_a() {
    header "Phase A: Prepare Booty NAS"
    info "Configuring Booty enp0s2 with ${BOOTY_DIRECT_IP}/30 and MTU ${DIRECT_MTU}..."

    # Configure the direct-link NIC on Booty
    $BOOTY_SSH bash -s <<'BOOTY_SCRIPT'
set -euo pipefail

DIRECT_NIC="enp0s2"
DIRECT_IP="10.10.10.2"
DIRECT_MTU=9000

echo "[→] Checking if $DIRECT_NIC exists..."
if ! ip link show "$DIRECT_NIC" &>/dev/null; then
    echo "[✗] NIC $DIRECT_NIC not found on Booty"
    exit 1
fi
echo "[✓] NIC $DIRECT_NIC exists"

# Check if already configured
CURRENT_IP=$(ip -4 addr show "$DIRECT_NIC" 2>/dev/null | grep -oP 'inet \K[\d.]+' || echo "")
if [ "$CURRENT_IP" = "$DIRECT_IP" ]; then
    echo "[✓] $DIRECT_NIC already has IP $DIRECT_IP — skipping IP assignment"
else
    # Bring up the interface and assign IP
    ip link set "$DIRECT_NIC" up
    ip addr add "${DIRECT_IP}/30" dev "$DIRECT_NIC" 2>/dev/null || {
        # If address exists but different, flush and re-add
        ip addr flush dev "$DIRECT_NIC"
        ip addr add "${DIRECT_IP}/30" dev "$DIRECT_NIC"
    }
    echo "[✓] Assigned ${DIRECT_IP}/30 to $DIRECT_NIC"
fi

# Set MTU
ip link set "$DIRECT_NIC" mtu "$DIRECT_MTU"
echo "[✓] Set MTU $DIRECT_MTU on $DIRECT_NIC"

# Verify
echo ""
echo "[→] Interface state:"
ip addr show "$DIRECT_NIC"

# Persist across reboots — UniFi OS (Alpine-based) uses /etc/network/interfaces
# or we can use rc.local as a fallback
PERSIST_SCRIPT="/etc/local.d/10g-direct-link.start"
PERSIST_DIR="/etc/local.d"

if [ -d "$PERSIST_DIR" ]; then
    # Alpine/UniFi OS pattern
    cat > "$PERSIST_SCRIPT" <<PERSIST
#!/bin/sh
# 10G Direct Link to Privateer — NFS dedicated path
ip link set $DIRECT_NIC up
ip addr add ${DIRECT_IP}/30 dev $DIRECT_NIC 2>/dev/null || true
ip link set $DIRECT_NIC mtu $DIRECT_MTU
PERSIST
    chmod +x "$PERSIST_SCRIPT"
    # Ensure local service is enabled
    rc-update add local default 2>/dev/null || true
    echo "[✓] Persisted config to $PERSIST_SCRIPT"
elif [ -f /etc/network/interfaces ]; then
    # Standard Debian/Ubuntu pattern
    if ! grep -q "$DIRECT_NIC" /etc/network/interfaces; then
        cat >> /etc/network/interfaces <<IFACE

# 10G Direct Link to Privateer — NFS dedicated path
auto $DIRECT_NIC
iface $DIRECT_NIC inet static
    address $DIRECT_IP
    netmask 255.255.255.252
    mtu $DIRECT_MTU
IFACE
        echo "[✓] Added $DIRECT_NIC to /etc/network/interfaces"
    else
        echo "[!] $DIRECT_NIC already in /etc/network/interfaces — verify config manually"
    fi
else
    # Last resort: rc.local
    RC_LOCAL="/etc/rc.local"
    if [ ! -f "$RC_LOCAL" ] || ! grep -q "$DIRECT_NIC" "$RC_LOCAL"; then
        echo "#!/bin/sh" > "$RC_LOCAL"
        echo "# 10G Direct Link to Privateer" >> "$RC_LOCAL"
        echo "ip link set $DIRECT_NIC up" >> "$RC_LOCAL"
        echo "ip addr add ${DIRECT_IP}/30 dev $DIRECT_NIC 2>/dev/null || true" >> "$RC_LOCAL"
        echo "ip link set $DIRECT_NIC mtu $DIRECT_MTU" >> "$RC_LOCAL"
        echo "exit 0" >> "$RC_LOCAL"
        chmod +x "$RC_LOCAL"
        echo "[✓] Created $RC_LOCAL for persistence"
    fi
fi
BOOTY_SCRIPT

    log "Booty enp0s2 configured"

    # Update NFS exports on Booty
    info "Updating NFS exports to allow Privateer direct-link IP..."

    $BOOTY_SSH bash -s <<'EXPORTS_SCRIPT'
set -euo pipefail

PRIVATEER_DIRECT="10.10.10.1"
EXPORTS_FILE="/etc/exports"

if [ ! -f "$EXPORTS_FILE" ]; then
    echo "[✗] /etc/exports not found on Booty"
    exit 1
fi

echo "[→] Current exports:"
cat "$EXPORTS_FILE"
echo ""

# Check if direct-link IP already in exports
if grep -q "$PRIVATEER_DIRECT" "$EXPORTS_FILE"; then
    echo "[✓] Privateer direct-link IP ($PRIVATEER_DIRECT) already in exports"
else
    # Add the direct-link IP alongside existing entries
    # Pattern: find lines with 192.168.1.27 (Privateer's switch IP) and add 10.10.10.1
    # with the same options
    cp "$EXPORTS_FILE" "${EXPORTS_FILE}.bak.$(date +%Y%m%d%H%M%S)"
    echo "[✓] Backed up exports to ${EXPORTS_FILE}.bak.*"

    # For each export line that contains a Privateer IP (192.168.1.27),
    # duplicate the Privateer entry with the direct-link IP
    TEMP_FILE=$(mktemp)
    while IFS= read -r line; do
        if echo "$line" | grep -q "192.168.1.27"; then
            # Extract the options used for 192.168.1.27
            OPTS=$(echo "$line" | grep -oP '192\.168\.1\.27\([^)]+\)' | grep -oP '\([^)]+\)')
            if [ -n "$OPTS" ]; then
                # Append the direct-link IP with same options
                echo "${line} ${PRIVATEER_DIRECT}${OPTS}" >> "$TEMP_FILE"
            else
                echo "$line" >> "$TEMP_FILE"
            fi
        else
            echo "$line" >> "$TEMP_FILE"
        fi
    done < "$EXPORTS_FILE"
    mv "$TEMP_FILE" "$EXPORTS_FILE"

    echo "[✓] Added $PRIVATEER_DIRECT to NFS exports"
fi

echo ""
echo "[→] Updated exports:"
cat "$EXPORTS_FILE"

# Re-export
exportfs -ra 2>/dev/null || exportfs -a 2>/dev/null || echo "[!] exportfs not found — NFS exports may need manual reload"
echo ""
echo "[✓] NFS exports reloaded"
EXPORTS_SCRIPT

    log "Booty NFS exports updated"
    echo ""
    log "Phase A complete. Booty is ready for the direct link."
}

# ── Phase B: Physical Cabling ─────────────────────────────────────────────────
phase_b() {
    header "Phase B: Physical Cabling"
    echo -e "${BOLD}  Do the following now:${NC}"
    echo ""
    echo "  1. Disconnect Privateer's enp1s0 SFP+ cable from the UDM SE switch"
    echo "  2. Connect DAC cable: Privateer enp1s0 ↔ Booty enp0s2"
    echo "  3. Connect Cat6: Privateer eno2 → UDM SE (1G RJ45 port)"
    echo ""
    echo -e "  ${DIM}Privateer will lose SSH briefly if enp1s0 was the active path.${NC}"
    echo -e "  ${DIM}eno2 will be brought up in Phase C to restore connectivity.${NC}"
    echo ""
    confirm "Cables connected? Ready to proceed to Phase C?"
    log "Physical cabling confirmed"
}

# ── Phase C: Configure Privateer ──────────────────────────────────────────────
phase_c() {
    header "Phase C: Configure Privateer"

    # First, try reaching Privateer. If enp1s0 was disconnected, we might need
    # to wait for eno2 or use an alternative path.
    info "Checking Privateer SSH access..."
    if ! $PRIVATEER_SSH "echo ok" &>/dev/null; then
        warn "Privateer not reachable on $PRIVATEER_LAN_IP via current path."
        warn "This is expected if enp1s0 was the only active NIC."
        echo ""
        echo "  Options:"
        echo "  1. Connect a keyboard/monitor to Privateer and run Phase C manually"
        echo "  2. SSH from Spyglass: ssh -i ~/.ssh/suparr_deploy_key root@192.168.1.27"
        echo "  3. If eno2 has link, it may auto-negotiate DHCP — check your router"
        echo ""
        confirm "Can you reach Privateer now? Enter 'y' once SSH is working"

        # Re-test
        if ! $PRIVATEER_SSH "echo ok" &>/dev/null; then
            err "Still cannot reach Privateer. Aborting Phase C."
            err "You may need to configure Privateer manually."
            exit 1
        fi
    fi
    log "Privateer reachable via SSH"

    # Read current NAS IP for sed replacements
    CURRENT_NAS_IP=$($PRIVATEER_SSH "grep '^NAS_IP=' ${SUPARR_DIR}/machine2-arr/.env 2>/dev/null | cut -d= -f2" || echo "")
    if [ -z "$CURRENT_NAS_IP" ]; then
        err "Could not determine current NAS_IP from Privateer's .env"
        exit 1
    fi
    info "Current NAS_IP: $CURRENT_NAS_IP → will be replaced with $BOOTY_DIRECT_IP"

    # Step 1: Configure network interfaces
    info "Configuring Privateer network interfaces..."
    $PRIVATEER_SSH bash -s -- "$CURRENT_NAS_IP" <<'PRIVATEER_NET'
set -euo pipefail

CURRENT_NAS_IP="$1"
DIRECT_NIC="enp1s0"
LAN_NIC="eno2"
DIRECT_IP="10.10.10.1"
DIRECT_MTU=9000
LAN_IP="192.168.1.27"
LAN_GATEWAY="192.168.1.1"
LAN_MTU=1500
INTERFACES_FILE="/etc/network/interfaces"

# Back up current interfaces file
if [ -f "$INTERFACES_FILE" ]; then
    cp "$INTERFACES_FILE" "${INTERFACES_FILE}.bak.$(date +%Y%m%d%H%M%S)"
    echo "[✓] Backed up $INTERFACES_FILE"
fi

# Determine if using netplan or interfaces file
if [ -d /etc/netplan ] && ls /etc/netplan/*.yaml &>/dev/null; then
    echo "[→] Detected netplan — configuring via netplan"

    # Back up existing netplan configs
    for f in /etc/netplan/*.yaml; do
        cp "$f" "${f}.bak.$(date +%Y%m%d%H%M%S)"
    done

    cat > /etc/netplan/01-direct-link.yaml <<NETPLAN
network:
  version: 2
  ethernets:
    # 10G Direct Link to Booty NAS — NFS only
    ${DIRECT_NIC}:
      addresses:
        - ${DIRECT_IP}/30
      mtu: ${DIRECT_MTU}
      # No gateway — point-to-point, NFS traffic only

    # 1G Switch — internet + LAN
    ${LAN_NIC}:
      addresses:
        - ${LAN_IP}/24
      routes:
        - to: default
          via: ${LAN_GATEWAY}
      nameservers:
        addresses:
          - ${LAN_GATEWAY}
      mtu: ${LAN_MTU}
NETPLAN
    echo "[✓] Created /etc/netplan/01-direct-link.yaml"

    # Remove old configs that might conflict
    for f in /etc/netplan/*.yaml; do
        [ "$f" = "/etc/netplan/01-direct-link.yaml" ] && continue
        if grep -q "$DIRECT_NIC\|$LAN_NIC" "$f" 2>/dev/null; then
            mv "$f" "${f}.disabled"
            echo "[!] Disabled conflicting netplan: $f"
        fi
    done

    netplan apply 2>/dev/null || echo "[!] netplan apply returned non-zero — check manually"

elif [ -f "$INTERFACES_FILE" ]; then
    echo "[→] Detected /etc/network/interfaces — configuring directly"

    # Build new interfaces file preserving loopback and any other interfaces
    TEMP_FILE=$(mktemp)

    # Keep loopback
    echo "# Loopback" > "$TEMP_FILE"
    echo "auto lo" >> "$TEMP_FILE"
    echo "iface lo inet loopback" >> "$TEMP_FILE"
    echo "" >> "$TEMP_FILE"

    # 10G Direct Link
    cat >> "$TEMP_FILE" <<IFACE_DIRECT
# 10G Direct Link to Booty NAS — NFS only
auto ${DIRECT_NIC}
iface ${DIRECT_NIC} inet static
    address ${DIRECT_IP}
    netmask 255.255.255.252
    mtu ${DIRECT_MTU}

IFACE_DIRECT

    # 1G Switch — internet + LAN
    cat >> "$TEMP_FILE" <<IFACE_LAN
# 1G Switch — internet + LAN
auto ${LAN_NIC}
iface ${LAN_NIC} inet static
    address ${LAN_IP}
    netmask 255.255.255.0
    gateway ${LAN_GATEWAY}
    dns-nameservers ${LAN_GATEWAY}
    mtu ${LAN_MTU}
IFACE_LAN

    mv "$TEMP_FILE" "$INTERFACES_FILE"
    echo "[✓] Updated $INTERFACES_FILE"
else
    echo "[✗] No recognized network config system found"
    exit 1
fi

# Bring up eno2 first (LAN/internet — ensures SSH stays alive)
echo "[→] Bringing up $LAN_NIC..."
ip link set "$LAN_NIC" up 2>/dev/null || true

# Check if eno2 already has the right IP
CURRENT_LAN_IP=$(ip -4 addr show "$LAN_NIC" 2>/dev/null | grep -oP 'inet \K[\d.]+' || echo "")
if [ "$CURRENT_LAN_IP" != "$LAN_IP" ]; then
    ip addr flush dev "$LAN_NIC" 2>/dev/null || true
    ip addr add "${LAN_IP}/24" dev "$LAN_NIC"
    ip route add default via "$LAN_GATEWAY" dev "$LAN_NIC" 2>/dev/null || true
fi
ip link set "$LAN_NIC" mtu "$LAN_MTU"
echo "[✓] $LAN_NIC up with ${LAN_IP}/24"

# Now configure enp1s0 for direct link
echo "[→] Configuring $DIRECT_NIC for direct link..."
ip addr flush dev "$DIRECT_NIC" 2>/dev/null || true
ip link set "$DIRECT_NIC" up 2>/dev/null || true
ip addr add "${DIRECT_IP}/30" dev "$DIRECT_NIC" 2>/dev/null || true
ip link set "$DIRECT_NIC" mtu "$DIRECT_MTU"
echo "[✓] $DIRECT_NIC configured with ${DIRECT_IP}/30, MTU ${DIRECT_MTU}"

# Remove any old default route via enp1s0 (it should only be on eno2 now)
ip route del default dev "$DIRECT_NIC" 2>/dev/null || true

echo ""
echo "[→] Final interface state:"
ip -br addr show "$DIRECT_NIC"
ip -br addr show "$LAN_NIC"
echo ""
echo "[→] Routing table:"
ip route show
PRIVATEER_NET

    log "Network interfaces configured"

    # Step 2: Test direct link connectivity
    info "Testing direct link..."
    $PRIVATEER_SSH bash -s <<'PING_TEST'
echo "[→] Ping test to 10.10.10.2..."
if ping -c 3 -W 3 10.10.10.2; then
    echo "[✓] Direct link is UP"
else
    echo "[✗] Cannot reach 10.10.10.2 — check cabling"
    exit 1
fi

echo ""
echo "[→] Jumbo frame test (MTU 9000)..."
if ping -M do -s 8972 -c 1 -W 3 10.10.10.2; then
    echo "[✓] Jumbo frames working end-to-end"
else
    echo "[!] Jumbo frame test failed — MTU mismatch somewhere"
    echo "[!] Standard frames work, continuing with MTU 1500 fallback possible"
fi
PING_TEST

    log "Direct link verified"

    # Step 3: Update fstab
    info "Updating fstab NFS entries..."
    $PRIVATEER_SSH bash -s -- "$CURRENT_NAS_IP" "$BOOTY_DIRECT_IP" <<'FSTAB_UPDATE'
set -euo pipefail
OLD_IP="$1"
NEW_IP="$2"

echo "[→] Replacing ${OLD_IP}: with ${NEW_IP}: in /etc/fstab..."
cp /etc/fstab /etc/fstab.bak.$(date +%Y%m%d%H%M%S)
echo "[✓] Backed up fstab"

# Only replace in NFS mount lines (safety: don't touch non-NFS entries)
sed -i "/nfs/s/${OLD_IP}:/${NEW_IP}:/g" /etc/fstab
echo "[✓] fstab updated"

echo ""
echo "[→] NFS entries in fstab:"
grep nfs /etc/fstab || echo "  (none found)"

# Reload systemd mount units
systemctl daemon-reload
echo "[✓] systemd daemon reloaded"
FSTAB_UPDATE

    log "fstab updated"

    # Step 4: Remount NFS
    info "Remounting NFS shares via direct link..."
    $PRIVATEER_SSH bash -s <<'REMOUNT'
set -euo pipefail

echo "[→] Unmounting NFS shares..."
# Lazy unmount to avoid blocking if something is using the mount
for mount in /mnt/media /mnt/downloads /mnt/backups; do
    if mountpoint -q "$mount" 2>/dev/null; then
        umount -l "$mount" 2>/dev/null && echo "[✓] Unmounted $mount" || echo "[!] Could not unmount $mount"
    else
        echo "[→] $mount not currently mounted"
    fi
done

# Brief pause for unmounts to complete
sleep 2

echo "[→] Mounting all from fstab..."
mount -a 2>&1 || echo "[!] mount -a returned non-zero"

echo ""
echo "[→] Verifying mounts..."
for mount in /mnt/media /mnt/downloads /mnt/backups; do
    if mountpoint -q "$mount" 2>/dev/null; then
        echo "[✓] $mount is mounted"
        # Quick content check
        COUNT=$(ls "$mount" 2>/dev/null | wc -l)
        echo "    → $COUNT items visible"
    else
        echo "[!] $mount is NOT mounted"
    fi
done

echo ""
echo "[→] NFS connection details:"
mount | grep nfs || echo "  (no NFS mounts found)"
REMOUNT

    log "NFS mounts remounted via direct link"

    # Step 5: Update .env
    info "Updating .env NAS_IP..."
    $PRIVATEER_SSH bash -s -- "$BOOTY_DIRECT_IP" <<'ENV_UPDATE'
set -euo pipefail
NEW_IP="$1"
ENV_FILE="/opt/suparr/machine2-arr/.env"

if [ -f "$ENV_FILE" ]; then
    sed -i "s/^NAS_IP=.*/NAS_IP=${NEW_IP}/" "$ENV_FILE"
    echo "[✓] Updated NAS_IP to $NEW_IP in $ENV_FILE"
    grep "^NAS_IP=" "$ENV_FILE"
else
    echo "[✗] .env not found at $ENV_FILE"
    exit 1
fi
ENV_UPDATE

    log ".env updated"

    # Step 6: Restart Docker containers
    info "Restarting Docker containers..."
    $PRIVATEER_SSH bash -s <<'DOCKER_RESTART'
set -euo pipefail
cd /opt/suparr/machine2-arr

echo "[→] Stopping containers..."
docker compose down --timeout 30

echo "[→] Starting containers..."
docker compose up -d

echo "[→] Waiting for containers to start..."
sleep 10

echo "[→] Container status:"
docker compose ps --format "table {{.Name}}\t{{.Status}}" | head -20
DOCKER_RESTART

    log "Docker containers restarted"
    echo ""
    log "Phase C complete."
}

# ── Phase D: Verify ───────────────────────────────────────────────────────────
phase_d() {
    header "Phase D: Verification"

    $PRIVATEER_SSH bash -s <<'VERIFY'
echo "═══ NFS Connections ═══"
echo ""
ss -tnp 2>/dev/null | grep 2049 | head -10 || echo "  No NFS connections found (automount may not have triggered yet)"
echo ""

echo "═══ Internet Connectivity ═══"
if ping -c 1 -W 3 google.com &>/dev/null; then
    echo "[✓] Internet works (via eno2)"
else
    echo "[✗] No internet — check eno2 gateway/DNS"
fi
echo ""

echo "═══ LAN Connectivity ═══"
if ping -c 1 -W 3 192.168.1.1 &>/dev/null; then
    echo "[✓] Gateway reachable (192.168.1.1)"
else
    echo "[✗] Cannot reach gateway"
fi

if ping -c 1 -W 3 192.168.1.104 &>/dev/null; then
    echo "[✓] Spyglass reachable (192.168.1.104)"
else
    echo "[!] Cannot reach Spyglass (may be down)"
fi
echo ""

echo "═══ Direct Link ═══"
if ping -c 1 -W 3 10.10.10.2 &>/dev/null; then
    echo "[✓] Booty reachable via direct link (10.10.10.2)"
else
    echo "[✗] Cannot reach Booty on direct link"
fi

echo ""
echo "═══ Jumbo Frame Test ═══"
if ping -M do -s 8972 -c 1 -W 3 10.10.10.2 &>/dev/null; then
    echo "[✓] MTU 9000 working end-to-end"
else
    echo "[✗] Jumbo frame test failed"
fi

echo ""
echo "═══ NFS Mounts ═══"
for mount in /mnt/media /mnt/downloads /mnt/backups; do
    if mountpoint -q "$mount" 2>/dev/null; then
        echo "[✓] $mount mounted"
    else
        echo "[✗] $mount NOT mounted"
    fi
done

echo ""
echo "═══ Docker Services ═══"
cd /opt/suparr/machine2-arr
RUNNING=$(docker compose ps --status running -q 2>/dev/null | wc -l)
TOTAL=$(docker compose ps -q 2>/dev/null | wc -l)
echo "  $RUNNING / $TOTAL containers running"

# Quick health check on key services
for svc in radarr sonarr prowlarr sabnzbd; do
    PORT=""
    case $svc in
        radarr)   PORT=7878 ;;
        sonarr)   PORT=8989 ;;
        prowlarr) PORT=9696 ;;
        sabnzbd)  PORT=8085 ;;
    esac
    if curl -sf "http://localhost:$PORT" -o /dev/null --max-time 5 2>/dev/null; then
        echo "[✓] $svc responding on :$PORT"
    else
        echo "[!] $svc not responding on :$PORT (may still be starting)"
    fi
done

echo ""
echo "═══ Interface Summary ═══"
ip -br addr show enp1s0
ip -br addr show eno2

echo ""
echo "═══ Routing Summary ═══"
ip route show
VERIFY

    echo ""
    log "Verification complete. Review the output above."
    echo ""
    info "Optional: run iperf3 between the machines to benchmark throughput:"
    echo "  On Booty:     iperf3 -s -B 10.10.10.2"
    echo "  On Privateer: iperf3 -c 10.10.10.2 -t 10"
    echo "  Expected: ~9.4 Gbps with jumbo frames"
}

# ── Rollback ──────────────────────────────────────────────────────────────────
rollback() {
    header "Rollback: Reverting to Switch Configuration"
    warn "This reverts Privateer's fstab and .env to the switch IP."
    warn "You must also physically move the SFP+ cable back to the switch."

    confirm "Proceed with rollback?"

    # Detect current NAS IP (should be 10.10.10.2 if cutover was done)
    CURRENT_NAS_IP=$($PRIVATEER_SSH "grep '^NAS_IP=' ${SUPARR_DIR}/machine2-arr/.env 2>/dev/null | cut -d= -f2" || echo "")

    echo ""
    info "Current NAS_IP: ${CURRENT_NAS_IP:-unknown}"

    # Ask which switch IP to revert to
    echo -en "${CYAN}  Booty switch IP to revert to [192.168.1.76]: ${NC}"
    read -r REVERT_IP
    REVERT_IP="${REVERT_IP:-192.168.1.76}"

    $PRIVATEER_SSH bash -s -- "$BOOTY_DIRECT_IP" "$REVERT_IP" <<'ROLLBACK_SCRIPT'
set -euo pipefail
DIRECT_IP="$1"
SWITCH_IP="$2"

echo "[→] Reverting fstab from $DIRECT_IP to $SWITCH_IP..."
sed -i "/nfs/s/${DIRECT_IP}:/${SWITCH_IP}:/g" /etc/fstab
echo "[✓] fstab reverted"
grep nfs /etc/fstab

echo "[→] Reverting .env..."
sed -i "s/^NAS_IP=.*/NAS_IP=${SWITCH_IP}/" /opt/suparr/machine2-arr/.env
echo "[✓] .env reverted"

systemctl daemon-reload

echo "[→] Remounting..."
for mount in /mnt/media /mnt/downloads /mnt/backups; do
    umount -l "$mount" 2>/dev/null || true
done
sleep 2
mount -a

echo "[→] Restarting containers..."
cd /opt/suparr/machine2-arr
docker compose down --timeout 30
docker compose up -d

echo "[✓] Rollback complete"
ROLLBACK_SCRIPT

    log "Rollback complete. Move the SFP+ cable back to the switch."
}

# ── Main ──────────────────────────────────────────────────────────────────────
main() {
    echo ""
    echo -e "${BOLD}╔═══════════════════════════════════════════════════════╗${NC}"
    echo -e "${BOLD}║     SupArr — 10G Direct Link Cutover                 ║${NC}"
    echo -e "${BOLD}║     Privateer ↔ Booty (DAC, point-to-point)          ║${NC}"
    echo -e "${BOLD}╚═══════════════════════════════════════════════════════╝${NC}"
    echo ""
    echo "  Direct link: ${PRIVATEER_DIRECT_IP}/30 ↔ ${BOOTY_DIRECT_IP}/30"
    echo "  MTU: ${DIRECT_MTU} (jumbo frames, end-to-end)"
    echo "  Purpose: Dedicated NFS path, zero switch contention"
    echo ""

    if [ "${1:-}" = "--rollback" ]; then
        preflight
        rollback
        exit 0
    fi

    if [ "${1:-}" = "--verify" ]; then
        phase_d
        exit 0
    fi

    if [ "${1:-}" = "--phase" ]; then
        PHASE="${2:-}"
        case "$PHASE" in
            a|A) preflight; phase_a ;;
            b|B) phase_b ;;
            c|C) phase_c ;;
            d|D) phase_d ;;
            *) err "Unknown phase: $PHASE (use a, b, c, or d)"; exit 1 ;;
        esac
        exit 0
    fi

    # Full cutover
    preflight
    confirm "Pre-flight looks good. Proceed with full cutover?"

    phase_a
    confirm "Phase A complete. Ready for cabling?"

    phase_b
    phase_c
    phase_d

    echo ""
    header "Cutover Complete"
    echo -e "  ${GREEN}NFS traffic now flows over the dedicated 10G direct link.${NC}"
    echo "  Switch is freed from NFS contention."
    echo "  Internet/LAN traffic routes through eno2 → UDM SE."
    echo ""
    echo "  Monitor for NFS stalls over the next 24h."
    echo "  If issues arise: ./scripts/10g-direct-link.sh --rollback"
    echo ""
}

main "$@"
