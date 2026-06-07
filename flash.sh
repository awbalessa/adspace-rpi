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
#   ./flash.sh <pi-ip> <tailscale-auth-key>
#
# EXAMPLES:
#   ./flash.sh 192.168.1.50 tskey-auth-xxxxx        # fresh Pi
#   ./flash.sh 192.168.1.50 tskey-auth-xxxxx --skip-provision  # re-deploy only
#
# PRE-REQUISITES:
#   - Pi is flashed with RPi OS Lite 64-bit via Raspberry Pi Imager
#     (username: pi, SSH enabled, ethernet connected)
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

# ── Args ──────────────────────────────────────────────────────────────────────
PI_IP="${1:-}"
TAILSCALE_KEY="${2:-}"
SKIP_PROVISION="${3:-}"

[[ -n "$PI_IP" ]] || die "Usage: ./flash.sh <pi-ip> [tailscale-auth-key] [--skip-provision]"

PI_USER="pi"
PI_SSH="${PI_USER}@${PI_IP}"
REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

section "AdSpace Pi Flash — target: $PI_SSH"

# ── Check SSH reachable ───────────────────────────────────────────────────────
log "Checking SSH connection to $PI_SSH..."
ssh -o ConnectTimeout=10 -o StrictHostKeyChecking=no "$PI_SSH" "echo ok" \
  || die "Cannot reach $PI_SSH — is the Pi on ethernet and booted?"

# ── Step 1: Provision ─────────────────────────────────────────────────────────
if [[ "$SKIP_PROVISION" != "--skip-provision" ]]; then
    section "Step 1/4 — Provisioning Pi"

    if [[ -n "$TAILSCALE_KEY" ]]; then
        log "Provisioning with Tailscale auth..."
        ssh -o StrictHostKeyChecking=no "$PI_SSH" \
            "TAILSCALE_AUTH_KEY=${TAILSCALE_KEY} sudo --preserve-env=TAILSCALE_AUTH_KEY bash -s" \
            < "$REPO_DIR/provision.sh"
    else
        warn "No Tailscale key provided — Tailscale will be installed but not authenticated"
        ssh -o StrictHostKeyChecking=no "$PI_SSH" "sudo bash -s" \
            < "$REPO_DIR/provision.sh"
    fi
else
    warn "Skipping provision (--skip-provision passed)"
fi

# ── Step 2: Build + deploy frontend ──────────────────────────────────────────
section "Step 2/4 — Building frontend"
cd "$REPO_DIR/wifi-setup"
pnpm install --frozen-lockfile
pnpm build

section "Step 3/4 — Deploying frontend"
rsync -av --delete --exclude='config.json' \
    dist/* \
    "${PI_SSH}:/opt/adspace/wifi-setup/dist"

# ── Step 3: Build + deploy Go API ────────────────────────────────────────────
section "Step 3/4 — Building + deploying API"
cd "$REPO_DIR/wifi-setup-api"
GOOS=linux GOARCH=arm64 go build -o wifi-setup-api .

scp wifi-setup-api "${PI_SSH}:/tmp/wifi-setup-api-new"
ssh "$PI_SSH" "sudo mv /tmp/wifi-setup-api-new /opt/adspace/wifi-setup-api \
             && sudo chmod +x /opt/adspace/wifi-setup-api"

# ── Step 4: Reboot ────────────────────────────────────────────────────────────
section "Step 4/4 — Rebooting"
log "Pi will reboot now. Watch the TV..."
ssh "$PI_SSH" "sudo reboot" || true  # connection drops on reboot, that's expected

# ── Done ──────────────────────────────────────────────────────────────────────
DEVICE_NAME="adspace-$(ssh -o ConnectTimeout=5 "$PI_SSH" "grep Serial /proc/cpuinfo | awk '{print \$3}' | tail -c 9" 2>/dev/null || echo '?')"

echo ""
echo -e "${GREEN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo -e "${GREEN}✓  Flash complete!${NC}"
echo ""
echo "   Device name: ${DEVICE_NAME}"
echo ""
echo "   After reboot (~30s), SSH via Tailscale:"
echo "   ssh pi@${DEVICE_NAME}"
echo ""
echo "   Or by IP until Tailscale connects:"
echo "   ssh pi@${PI_IP}"
echo -e "${GREEN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
