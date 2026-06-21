#!/usr/bin/env bash
# =============================================================================
# AdSpace RPi — Embed Script (Mac-side)
# =============================================================================
# Injects bootstrap.sh + adspace-bootstrap.service into a vanilla
# Raspberry Pi OS Lite 64-bit .img file so it self-provisions on first boot.
#
# This replaces the old provision.sh + prepare-image.sh + flash.sh workflow.
# You only need to run this when cutting a new base image.
#
# USAGE:
#   ./embed.sh <path-to-rpios-lite.img> [output.img]
#
# EXAMPLE:
#   ./embed.sh ~/Downloads/2025-03-15-raspios-bookworm-arm64-lite.img
#   # Writes: adspace-tv.img (ready to flash with Raspberry Pi Imager)
#
# REQUIREMENTS (Mac):
#   brew install e2fsprogs  — provides debugfs for writing to ext4 rootfs
#
# WHAT IT DOES:
#   1. Copies the input image to the output path
#   2. Finds the boot partition (FAT32) and rootfs (ext4) offsets
#   3. Mounts the boot partition via hdiutil
#   4. Writes a firstrun.sh into the boot partition (RPi OS runs this once on boot)
#      firstrun.sh: copies bootstrap.sh to /opt/adspace/, installs the service, enables it
#   5. Uses debugfs to write bootstrap.sh + service unit into the ext4 rootfs directly
#      (no root needed — debugfs writes without mounting)
#   6. Unmounts — output image is ready to flash
#
# BOOT SEQUENCE on a flashed Pi:
#   Boot 1: RPi OS firstrun.sh runs → copies files, enables service → reboots
#   Boot 2: adspace-bootstrap.service runs → full provisioning → reboots
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

[[ -n "$INPUT_IMG" ]] || die "Usage: ./embed.sh <rpios-lite.img> [output.img]"
[[ -f "$INPUT_IMG" ]] || die "Input image not found: $INPUT_IMG"
[[ -f "$REPO_DIR/bootstrap.sh" ]] || die "bootstrap.sh not found in repo root"
[[ -f "$REPO_DIR/adspace-bootstrap.service" ]] || die "adspace-bootstrap.service not found in repo root"

# ── Check tools ───────────────────────────────────────────────────────────────
command -v debugfs &>/dev/null || die "debugfs not found — run: brew install e2fsprogs"

log "Input:  $INPUT_IMG"
log "Output: $OUTPUT_IMG"

# ── Copy image ────────────────────────────────────────────────────────────────
log "Copying image (this takes a moment)..."
cp "$INPUT_IMG" "$OUTPUT_IMG"

# ── Find partition offsets ────────────────────────────────────────────────────
log "Reading partition table..."

# fdisk -l output gives us byte offsets
FDISK=$(fdisk -l "$OUTPUT_IMG" 2>/dev/null || true)

# Sector size
SECTOR_SIZE=$(echo "$FDISK" | grep -i 'Sector size' | awk '{print $4}' | head -1)
SECTOR_SIZE="${SECTOR_SIZE:-512}"

# Boot partition = first partition (FAT32, smaller)
BOOT_START_SECTOR=$(echo "$FDISK" | awk '/\.img1/{print $2}')
# Rootfs = second partition (ext4, larger)
ROOT_START_SECTOR=$(echo "$FDISK" | awk '/\.img2/{print $2}')

[[ -n "$BOOT_START_SECTOR" ]] || die "Could not find boot partition in image"
[[ -n "$ROOT_START_SECTOR" ]] || die "Could not find rootfs partition in image"

BOOT_OFFSET=$((BOOT_START_SECTOR * SECTOR_SIZE))
ROOT_OFFSET=$((ROOT_START_SECTOR * SECTOR_SIZE))

log "Boot partition offset: $BOOT_OFFSET bytes (sector $BOOT_START_SECTOR)"
log "Rootfs offset:         $ROOT_OFFSET bytes (sector $ROOT_START_SECTOR)"

# ── Write bootstrap.sh + service into rootfs via debugfs (no mount needed) ───
log "Writing bootstrap.sh into rootfs..."
# Ensure /opt/adspace exists in rootfs
debugfs -w -o offset="$ROOT_OFFSET" "$OUTPUT_IMG" << DEBUGFS_EOF 2>/dev/null
mkdir /opt
mkdir /opt/adspace
write ${REPO_DIR}/bootstrap.sh /opt/adspace/bootstrap.sh
set_inode_field /opt/adspace/bootstrap.sh mode 0100755
write ${REPO_DIR}/adspace-bootstrap.service /etc/systemd/system/adspace-bootstrap.service
DEBUGFS_EOF

log "Files written to rootfs"

# ── Mount boot partition and write firstrun.sh ────────────────────────────────
log "Mounting boot partition..."
MOUNT_DIR=$(mktemp -d)

hdiutil attach "$OUTPUT_IMG" \
    -imagekey diskimage-class=CRawDiskImage \
    -nomount \
    -section "$BOOT_START_SECTOR" \
    > /dev/null 2>&1 || true

# hdiutil approach for partitioned images
DISK_DEV=$(hdiutil attach "$OUTPUT_IMG" \
    -imagekey diskimage-class=CRawDiskImage \
    -nomount 2>/dev/null | awk '/FAT/{print $1}' | head -1)

if [[ -z "$DISK_DEV" ]]; then
    # Fallback: attach whole image, find the FAT slice
    DISK_DEV=$(hdiutil attach "$OUTPUT_IMG" \
        -imagekey diskimage-class=CRawDiskImage \
        -nomount 2>/dev/null | grep 'Windows_FAT' | awk '{print $1}' | head -1)
fi

[[ -n "$DISK_DEV" ]] || die "Could not attach boot partition — try: hdiutil attach '$OUTPUT_IMG' -nomount"

mount -t msdos "$DISK_DEV" "$MOUNT_DIR" \
    || die "Could not mount boot partition at $DISK_DEV"

log "Boot partition mounted at $MOUNT_DIR"

# Write firstrun.sh — RPi OS Lite runs this automatically on first boot as root
# It copies our files from /boot/firmware into place and enables the service.
# RPi OS deletes firstrun.sh and triggers a reboot after it finishes.
cat > "$MOUNT_DIR/firstrun.sh" << 'FIRSTRUN'
#!/bin/bash
set -euo pipefail

# AdSpace firstrun — runs once via RPi OS firstrun mechanism, then deleted automatically.
# Copies bootstrap.sh into place and enables adspace-bootstrap.service.

logger -t adspace-firstrun "firstrun.sh starting"

# Copy bootstrap script into place (already written to rootfs by embed.sh,
# but also copy from boot partition as a fallback in case rootfs write failed)
if [ -f /boot/firmware/adspace-bootstrap.sh ]; then
    mkdir -p /opt/adspace
    cp /boot/firmware/adspace-bootstrap.sh /opt/adspace/bootstrap.sh
    chmod +x /opt/adspace/bootstrap.sh
fi

# Copy service unit
if [ -f /boot/firmware/adspace-bootstrap.service ]; then
    cp /boot/firmware/adspace-bootstrap.service /etc/systemd/system/adspace-bootstrap.service
fi

# Enable the service — it will run on next boot
systemctl daemon-reload
systemctl enable adspace-bootstrap.service

logger -t adspace-firstrun "firstrun.sh complete — adspace-bootstrap.service enabled"
FIRSTRUN
chmod +x "$MOUNT_DIR/firstrun.sh"

# Also copy bootstrap.sh + service to boot partition as fallback
cp "$REPO_DIR/bootstrap.sh"              "$MOUNT_DIR/adspace-bootstrap.sh"
cp "$REPO_DIR/adspace-bootstrap.service" "$MOUNT_DIR/adspace-bootstrap.service"

log "firstrun.sh written to boot partition"

# ── Unmount ───────────────────────────────────────────────────────────────────
sync
umount "$MOUNT_DIR"
rmdir "$MOUNT_DIR"
hdiutil detach "$DISK_DEV" > /dev/null 2>&1 || true

log ""
log "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
log "  Image ready: $OUTPUT_IMG"
log ""
log "  Flash with Raspberry Pi Imager:"
log "    - OS: Use Custom → select $OUTPUT_IMG"
log "    - Storage: your SD card"
log "    - In Settings:"
log "        Username: pi"
log "        Enable SSH (password auth)"
log "        Do NOT set WiFi — leave blank"
log "        Hostname: anything (bootstrap will rename it)"
log ""
log "  On first boot:"
log "    Boot 1: RPi firstrun runs, enables adspace-bootstrap.service"
log "    Boot 2: Bootstrap installs everything (~10 min, needs ethernet)"
log "    Boot 3: Kiosk is live at https://screen.adspace.so"
log "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
