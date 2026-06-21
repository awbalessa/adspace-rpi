#!/usr/bin/env bash
# =============================================================================
# AdSpace RPi — Embed Script (Mac-side)
# =============================================================================
# Injects bootstrap.sh + adspace-bootstrap.service into a vanilla
# Raspberry Pi OS Lite 64-bit .img file so it self-provisions on first boot.
#
# USAGE:
#   ./embed.sh <path-to-rpios-lite.img> [output.img]
#
# EXAMPLE:
#   ./embed.sh ~/Downloads/2026-06-18-raspios-trixie-arm64-lite.img ~/Downloads/adspace-tv-v0.1.0.img
#
# REQUIREMENTS (Mac):
#   hdiutil — built into macOS, no install needed
#
# WHAT IT DOES:
#   1. Copies the input image to the output path
#   2. Attaches the image via hdiutil, mounts the FAT32 boot partition
#   3. Writes three files to the boot partition:
#      - firstrun.sh         (RPi OS runs this once on Boot 1 as root)
#      - adspace-bootstrap.sh       (bootstrap.sh — copy of repo file)
#      - adspace-bootstrap.service  (systemd unit — copy of repo file)
#   4. firstrun.sh copies both files into rootfs and enables the service
#   5. On Boot 2, adspace-bootstrap.service runs bootstrap.sh
#
# BOOT SEQUENCE on a flashed Pi:
#   Boot 1: RPi OS firstrun.sh runs → copies files into rootfs,
#            enables adspace-bootstrap.service → reboots
#   Boot 2: adspace-bootstrap.service runs → full provisioning (~10 min) → reboots
#   Boot 3+: Normal kiosk/setup operation
# =============================================================================

set -euo pipefail

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; NC='\033[0m'
log()  { echo -e "${GREEN}[embed]${NC} $*"; }
warn() { echo -e "${YELLOW}[embed]${NC} WARN: $*"; }
die()  { echo -e "${RED}[embed]${NC} ERROR: $*" >&2; exit 1; }

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# ── Args ──────────────────────────────────────────────────────────────────────
INPUT_IMG="${1:-}"
OUTPUT_IMG="${2:-${REPO_DIR}/adspace-tv.img}"

[[ -n "$INPUT_IMG" ]]  || die "Usage: ./embed.sh <rpios-lite.img> [output.img]"
[[ -f "$INPUT_IMG" ]]  || die "Input image not found: $INPUT_IMG"
[[ -f "$REPO_DIR/bootstrap.sh" ]] \
    || die "bootstrap.sh not found in repo root"
[[ -f "$REPO_DIR/adspace-bootstrap.service" ]] \
    || die "adspace-bootstrap.service not found in repo root"

log "Input:  $INPUT_IMG"
log "Output: $OUTPUT_IMG"

# ── Copy image ────────────────────────────────────────────────────────────────
log "Copying image (this takes a moment)..."
cp "$INPUT_IMG" "$OUTPUT_IMG"

# ── Attach image and find the FAT32 boot partition device ────────────────────
log "Attaching image..."
HDIUTIL_OUT=$(hdiutil attach "$OUTPUT_IMG" \
    -imagekey diskimage-class=CRawDiskImage \
    -nomount 2>&1)
log "hdiutil output: $HDIUTIL_OUT"

# Find the FAT32 slice (Windows_FAT_32)
DISK_DEV=$(echo "$HDIUTIL_OUT" | awk '/Windows_FAT/{print $1}' | head -1)

if [[ -z "$DISK_DEV" ]]; then
    # Detach before dying
    WHOLE_DISK=$(echo "$HDIUTIL_OUT" | awk 'NR==1{print $1}')
    hdiutil detach "$WHOLE_DISK" 2>/dev/null || true
    die "Could not find FAT32 boot partition in image. hdiutil output was:\n$HDIUTIL_OUT"
fi

log "Boot partition device: $DISK_DEV"

# ── Mount the boot partition ──────────────────────────────────────────────────
MOUNT_DIR=$(mktemp -d)
log "Mounting boot partition at $MOUNT_DIR..."

mount_msdos "$DISK_DEV" "$MOUNT_DIR" \
    || die "Could not mount boot partition ($DISK_DEV)"

log "Mounted."

# ── Write firstrun.sh ─────────────────────────────────────────────────────────
# RPi OS Lite runs /boot/firmware/firstrun.sh automatically on first boot as root,
# then deletes it and reboots. We use it to copy our files into the rootfs and
# enable adspace-bootstrap.service.
log "Writing firstrun.sh..."
cat > "$MOUNT_DIR/firstrun.sh" << 'FIRSTRUN'
#!/bin/bash
# AdSpace firstrun — runs once on Boot 1 via RPi OS firstrun mechanism.
# Copies bootstrap.sh into rootfs and enables adspace-bootstrap.service.
# RPi OS deletes this file and reboots after it exits.

set -euo pipefail
logger -t adspace-firstrun "Starting AdSpace firstrun setup..."

BOOT="/boot/firmware"

# Copy bootstrap script into rootfs
mkdir -p /opt/adspace
cp "$BOOT/adspace-bootstrap.sh" /opt/adspace/bootstrap.sh
chmod +x /opt/adspace/bootstrap.sh
logger -t adspace-firstrun "bootstrap.sh copied to /opt/adspace/"

# Copy and enable the service unit
cp "$BOOT/adspace-bootstrap.service" /etc/systemd/system/adspace-bootstrap.service
systemctl daemon-reload
systemctl enable adspace-bootstrap.service
logger -t adspace-firstrun "adspace-bootstrap.service enabled — will run on next boot"
FIRSTRUN
chmod +x "$MOUNT_DIR/firstrun.sh"

# ── Copy bootstrap.sh + service unit to boot partition ───────────────────────
log "Copying bootstrap.sh and service unit to boot partition..."
cp "$REPO_DIR/bootstrap.sh"              "$MOUNT_DIR/adspace-bootstrap.sh"
cp "$REPO_DIR/adspace-bootstrap.service" "$MOUNT_DIR/adspace-bootstrap.service"

log "Boot partition contents:"
ls -lh "$MOUNT_DIR/firstrun.sh" "$MOUNT_DIR/adspace-bootstrap.sh" "$MOUNT_DIR/adspace-bootstrap.service"

# ── Unmount ───────────────────────────────────────────────────────────────────
log "Unmounting..."
sync
umount "$MOUNT_DIR" 2>/dev/null || diskutil unmount "$MOUNT_DIR" 2>/dev/null || true
rmdir "$MOUNT_DIR"

# Detach the whole image disk (find parent disk from slice)
WHOLE_DISK=$(echo "$DISK_DEV" | sed 's/s[0-9]*$//')
hdiutil detach "$WHOLE_DISK" > /dev/null 2>&1 || true

# ── Done ──────────────────────────────────────────────────────────────────────
log ""
log "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
log "  Image ready: $OUTPUT_IMG"
log ""
log "  Flash with Raspberry Pi Imager:"
log "    - OS: Use Custom → select $OUTPUT_IMG"
log "    - Storage: your SD card"
log "    - OS Customisation (gear icon):"
log "        Username: pi, set a password"
log "        Enable SSH (password auth)"
log "        Leave WiFi and hostname blank"
log ""
log "  On first boot (plug in ethernet):"
log "    Boot 1 (~1 min):   firstrun.sh runs, enables bootstrap service"
log "    Boot 2 (~10 min):  bootstrap.sh installs everything, pulls from GitHub"
log "    Boot 3:            Kiosk is live at https://screen.adspace.so"
log "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
