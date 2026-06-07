#!/usr/bin/env bash
# =============================================================================
# AdSpace RPi Deprovision Script
# =============================================================================
# Undoes everything provision.sh did. Use to test provisioning on an existing
# Pi WITHOUT reflashing the SD card.
#
# Usage:
#   ssh pi@<ip> "sudo bash -s" < deprovision.sh
#
# WARNING: This removes all adspace config, users, and services.
#          Only use on a dev/test Pi — never on a live device.
# =============================================================================

set -euo pipefail

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; NC='\033[0m'
log()  { echo -e "${GREEN}==>${NC} $*"; }
warn() { echo -e "${YELLOW}WARN${NC} $*"; }

[[ $EUID -eq 0 ]] || { echo "Run as root: sudo bash deprovision.sh"; exit 1; }

log "Stopping services..."
systemctl stop adspace-watchdog.service  2>/dev/null || true
systemctl stop adspace-kiosk.service     2>/dev/null || true
systemctl stop adspace-setup-api.service 2>/dev/null || true
systemctl stop caddy.service             2>/dev/null || true

log "Disabling services..."
systemctl disable adspace-watchdog.service  2>/dev/null || true
systemctl disable adspace-kiosk.service     2>/dev/null || true
systemctl disable adspace-setup-api.service 2>/dev/null || true

log "Removing systemd units..."
rm -f /etc/systemd/system/adspace-watchdog.service
rm -f /etc/systemd/system/adspace-kiosk.service
rm -f /etc/systemd/system/adspace-setup-api.service
rm -f /etc/systemd/system/getty@tty1.service.d/autologin.conf
rmdir /etc/systemd/system/getty@tty1.service.d 2>/dev/null || true
systemctl daemon-reload

log "Removing /opt/adspace..."
rm -rf /opt/adspace

log "Removing labwc autostart..."
rm -f /home/adspace/.config/labwc/autostart

log "Resetting Caddyfile..."
cat > /etc/caddy/Caddyfile << 'EOF'
# Default Caddyfile — restored by deprovision.sh
:80 {
    respond "Caddy is running"
}
EOF

log "Removing nmcli hotspot profile..."
nmcli con delete adspace-hotspot 2>/dev/null || true

log "Removing runtime flags..."
rm -f /tmp/adspace-setup-mode
rm -f /tmp/adspace-wifi-scan.json

log "Removing sudoers..."
rm -f /etc/sudoers.d/aiagent

log "Removing aiagent user..."
userdel -r aiagent 2>/dev/null || warn "aiagent user not found or already removed"

log "Removing adspace user..."
userdel -r adspace 2>/dev/null || warn "adspace user not found or already removed"

log "Logging out of Tailscale..."
if command -v tailscale &>/dev/null; then
    tailscale logout 2>/dev/null || true
fi
# Note: we don't uninstall Tailscale itself — provision.sh skips reinstall if already present

log ""
log "────────────────────────────────────────────────────────"
log "✓  Deprovision complete. Pi is back to bare OS state."
log "   Run provision.sh to reprovision:"
log "   TAILSCALE_AUTH_KEY=tskey-auth-xxx ssh pi@<ip> 'sudo --preserve-env=TAILSCALE_AUTH_KEY bash -s' < provision.sh"
log "────────────────────────────────────────────────────────"
