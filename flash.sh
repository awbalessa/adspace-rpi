#!/usr/bin/env bash
# =============================================================================
# AdSpace RPi — Full Device Flash Script
# =============================================================================
# Runs the complete setup on a Pi from your Mac in one command:
#   1. Provisions the Pi (installs all deps, creates users, configures services)
#   2. Deploys the frontend (React build → rsync to Pi)
#   3. Deploys the Go API binary (cross-compile → scp to Pi)
#   4. Reboots the Pi
#
# USAGE:
#   ./flash.sh <pi-ip-or-hostname> [options]
#
# OPTIONS:
#   --user <user>        SSH user (default: pi)
#   --key <path>         SSH identity file (default: none, uses ssh-agent)
#   --skip-provision     Skip provisioning, re-deploy only
#
# EXAMPLES:
#   # Fresh Pi — connect as pi (RPi OS default)
#   ./flash.sh 192.168.1.50
#
#   # Already-provisioned Pi — connect as aiagent with key (no password needed)
#   ./flash.sh adspace-c0c2489e --user aiagent --key ~/.ssh/ai-agent
#
#   # Re-deploy only, no provision
#   ./flash.sh adspace-c0c2489e --user aiagent --key ~/.ssh/ai-agent --skip-provision
#
# PRE-REQUISITES:
#   - Pi is flashed with RPi OS Lite 64-bit via Raspberry Pi Imager
#     (username: pi, SSH enabled, ethernet connected, WiFi left blank)
#   - Go installed on your Mac (brew install go)
#   - pnpm installed on your Mac (brew install pnpm)
#   - This repo cloned locally
# =============================================================================

set -euo pipefail

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; CYAN='\033[0;36m'; NC='\033[0m'
log()     { echo -e "${GREEN}==>${NC} $*"; }
section() { echo -e "\n${CYAN}━━━ $* ━━━${NC}"; }
warn()    { echo -e "${YELLOW}WARN${NC} $*"; }
die()     { echo -e "${RED}ERROR${NC} $*" >&2; exit 1; }

# ── Load .env if present ─────────────────────────────────────────────────────
REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [[ -f "$REPO_DIR/.env" ]]; then
    # shellcheck disable=SC1091
    set -a; source "$REPO_DIR/.env"; set +a
fi

# ── Args ──────────────────────────────────────────────────────────────────────
PI_HOST="${1:-}"
[[ -n "$PI_HOST" ]] || die "Usage: ./flash.sh <pi-ip-or-hostname> [--user <user>] [--key <path>] [--skip-provision]"

PI_USER="pi"
SSH_KEY=""
SKIP_PROVISION=""

shift
while [[ $# -gt 0 ]]; do
    case "$1" in
        --user) PI_USER="$2"; shift 2 ;;
        --key)  SSH_KEY="$2";  shift 2 ;;
        --skip-provision) SKIP_PROVISION="yes"; shift ;;
        *) die "Unknown argument: $1" ;;
    esac
done

# Build SSH options
SSH_OPTS="-o ConnectTimeout=10 -o StrictHostKeyChecking=no"
SCP_OPTS="-o StrictHostKeyChecking=no"
RSYNC_SSH="ssh -o StrictHostKeyChecking=no"
if [[ -n "$SSH_KEY" ]]; then
    SSH_OPTS="$SSH_OPTS -i $SSH_KEY"
    SCP_OPTS="$SCP_OPTS -i $SSH_KEY"
    RSYNC_SSH="$RSYNC_SSH -i $SSH_KEY"
fi

PI_SSH="${PI_USER}@${PI_HOST}"

section "AdSpace Pi Flash — target: $PI_SSH"

# ── Check SSH reachable ───────────────────────────────────────────────────────
log "Checking SSH connection to $PI_SSH..."
# shellcheck disable=SC2086
ssh $SSH_OPTS "$PI_SSH" "echo ok" \
  || die "Cannot reach $PI_SSH — is the Pi on ethernet and booted?"

# ── Step 1: Provision ─────────────────────────────────────────────────────────
if [[ -z "$SKIP_PROVISION" ]]; then
    section "Step 1/4 — Provisioning Pi"
    log "Uploading provision.sh..."
    # shellcheck disable=SC2086
    scp $SCP_OPTS "$REPO_DIR/provision.sh" "$PI_SSH":/tmp/provision.sh
    # shellcheck disable=SC2086
    ssh -t $SSH_OPTS "$PI_SSH" "sudo bash /tmp/provision.sh"
else
    warn "Skipping provision (--skip-provision passed)"
fi

# ── Step 2: Build + deploy frontend ──────────────────────────────────────────
section "Step 2/4 — Building frontend"
cd "$REPO_DIR/wifi-setup"
pnpm install --frozen-lockfile
pnpm build

section "Step 3/4 — Deploying frontend"
# shellcheck disable=SC2086
ssh $SSH_OPTS "$PI_SSH" "sudo chown -R pi:pi /opt/adspace/wifi-setup/dist && sudo chmod -R 775 /opt/adspace/wifi-setup/dist" 2>/dev/null || true
rsync -av --delete --exclude='config.json' \
    -e "$RSYNC_SSH" \
    dist/* \
    "${PI_SSH}:/opt/adspace/wifi-setup/dist"

# ── Step 3: Build + deploy Go API ────────────────────────────────────────────
section "Step 3/4 — Building + deploying API"
cd "$REPO_DIR/wifi-setup-api"
GOOS=linux GOARCH=arm64 go build -o wifi-setup-api .

# shellcheck disable=SC2086
scp $SCP_OPTS wifi-setup-api "${PI_SSH}:/tmp/wifi-setup-api-new"
# shellcheck disable=SC2086
ssh $SSH_OPTS "$PI_SSH" "sudo mv /tmp/wifi-setup-api-new /opt/adspace/wifi-setup-api \
             && sudo chown adspace:adspace /opt/adspace/wifi-setup-api \
             && sudo chmod +x /opt/adspace/wifi-setup-api"

# ── Step 4: Reboot ────────────────────────────────────────────────────────────
section "Step 4/4 — Rebooting"
log "Pi will reboot now. Watch the TV..."
# shellcheck disable=SC2086
ssh $SSH_OPTS "$PI_SSH" "sudo reboot" || true  # connection drops on reboot, that's expected

# ── Done ──────────────────────────────────────────────────────────────────────
echo ""
echo -e "${GREEN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo -e "${GREEN}✓  Flash complete!${NC}"
echo ""
echo "   Pi is rebooting now."
echo ""
echo "   WAIT 60 SECONDS, then verify:"
echo ""
echo "   1. Get the hostname:"
echo "      ssh ${PI_SSH} cat /etc/hostname"
echo ""
echo "   2. Verify passwordless sudo:"
echo "      ssh ${PI_SSH} sudo -l"
echo ""
echo "   3. Check kiosk service:"
echo "      ssh ${PI_SSH} sudo systemctl status adspace-kiosk"
echo ""
echo "   4. Check watchdog service:"
echo "      ssh ${PI_SSH} sudo systemctl status adspace-watchdog"
echo ""
echo "   Once Tailscale connects (~60s), SSH by hostname:"
echo "      ssh pi@adspace-{serial}"
echo -e "${GREEN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
