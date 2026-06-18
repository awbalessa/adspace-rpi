#!/usr/bin/env bash
# =============================================================================
# AdSpace RPi — Image Preparation Script
# =============================================================================
# Run this on a Pi BEFORE dumping its SD card to a golden image.
# Wipes all per-device state so each clone self-configures on first boot.
#
# What it clears:
#   - Tailscale node key (each clone gets its own on first boot)
#   - First-boot done flag (triggers firstboot.sh to run on next boot)
#   - Hostname (reset to CPU serial by firstboot.sh on next boot)
#   - SSH host keys (each clone generates its own on first boot)
#   - Machine ID (regenerated on first boot)
#
# After running this, power off immediately and dump the SD card.
# DO NOT reboot — the Pi will re-register before you can dump.
#
# USAGE (from your Mac):
#   ssh pi@adspace-{serial} "sudo bash -s" < prepare-image.sh
# =============================================================================

set -euo pipefail

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; NC='\033[0m'
log()  { echo -e "${GREEN}==>${NC} $*"; }
warn() { echo -e "${YELLOW}WARN${NC} $*"; }

[[ $EUID -eq 0 ]] || { echo -e "${RED}ERROR${NC} Run as root: sudo bash prepare-image.sh" >&2; exit 1; }

log "Preparing Pi for image dump..."

# ── Tailscale ─────────────────────────────────────────────────────────────────
log "Wiping Tailscale state..."
tailscale logout 2>/dev/null || true
systemctl stop tailscaled 2>/dev/null || true
rm -rf /var/lib/tailscale
log "Tailscale state wiped — will re-register on first boot"

# ── First-boot flag ───────────────────────────────────────────────────────────
log "Resetting first-boot flag..."
rm -f /etc/adspace-firstboot-done
systemctl enable adspace-firstboot.service 2>/dev/null || true
log "First-boot service will run on next boot"

# ── SSH host keys ─────────────────────────────────────────────────────────────
log "Wiping SSH host keys..."
rm -f /etc/ssh/ssh_host_*
# Re-generate on first boot via ssh.service
log "SSH host keys wiped — will regenerate on first boot"

# ── Machine ID ────────────────────────────────────────────────────────────────
log "Resetting machine ID..."
rm -f /etc/machine-id
rm -f /var/lib/dbus/machine-id
# systemd regenerates this on next boot
log "Machine ID wiped — will regenerate on first boot"

# ── Hostname ──────────────────────────────────────────────────────────────────
log "Resetting hostname to placeholder..."
echo "adspace-image" > /etc/hostname
hostnamectl set-hostname "adspace-image" 2>/dev/null || true
log "Hostname reset — firstboot.sh will set correct serial-based hostname"

# ── Runtime state ─────────────────────────────────────────────────────────────
log "Clearing runtime state..."
rm -f /tmp/adspace-setup-mode
rm -f /tmp/adspace-wifi-scan.json

# ── Done ──────────────────────────────────────────────────────────────────────
echo ""
echo -e "${GREEN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo -e "${GREEN}✓  Pi is ready for image dump!${NC}"
echo ""
echo "   IMPORTANT: Power off NOW — do not reboot."
echo "   Rebooting will re-register Tailscale before you can dump."
echo ""
echo "   Power off:"
echo "   sudo poweroff"
echo ""
echo "   Then dump the SD card on your Mac:"
echo "   diskutil unmountDisk /dev/diskN"
echo "   sudo dd if=/dev/diskN of=~/code/nizek/adspace/rpi/images/adspace-tv-v0.1.0.img bs=16m status=progress"
echo -e "${GREEN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
