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
#   ./embed.sh ~/Downloads/2026-06-18-raspios-trixie-arm64-lite.img ~/Downloads/adspace-tv-v0.1.1.img
#
# REQUIREMENTS (Mac):
#   hdiutil — built into macOS, no install needed
#   openssl — built into macOS, no install needed
#
# WHAT IT DOES:
#   1. Copies the input image to the output path
#   2. Attaches the image via hdiutil, mounts the FAT32 boot partition
#   3. Writes to the boot partition:
#      - ssh                        (empty file — enables SSH on boot)
#      - userconf.txt               (pi user with hashed password)
#      - firstrun.sh                (RPi OS runs this once on Boot 1 as root)
#      - adspace-bootstrap.sh       (copy of bootstrap.sh)
#      - adspace-bootstrap.service  (copy of service unit)
#   4. firstrun.sh copies bootstrap files into rootfs and enables the service
#   5. On Boot 2, adspace-bootstrap.service runs bootstrap.sh (~10 min)
#
# IDEMPOTENT: safe to re-run on the same output image — just overwrites files.
#
# BOOT SEQUENCE on a flashed Pi:
#   Boot 1: RPi OS firstrun.sh runs → copies files into rootfs,
#            enables adspace-bootstrap.service → reboots
#   Boot 2: adspace-bootstrap.service runs → full provisioning → reboots
#   Boot 3+: Normal kiosk/setup operation
# =============================================================================

set -euo pipefail

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; NC='\033[0m'
log()  { echo -e "${GREEN}[embed]${NC} $*"; }
warn() { echo -e "${YELLOW}[embed]${NC} WARN: $*"; }
die()  { echo -e "${RED}[embed]${NC} ERROR: $*" >&2; exit 1; }

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# ── Pi SSH credentials baked into every image ─────────────────────────────────
# Password for the pi user — used for initial SSH before Tailscale connects.
# Bootstrap sets up aiagent (key-only) and pi (passwordless sudo) on first boot.
PI_PASSWORD="adspace"

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

# ── Copy image (idempotent — always starts fresh from input) ──────────────────
log "Copying image (this takes a moment)..."
cp "$INPUT_IMG" "$OUTPUT_IMG"

# ── Attach image and find the FAT32 boot partition device ────────────────────
log "Attaching image..."
HDIUTIL_OUT=$(hdiutil attach "$OUTPUT_IMG" \
    -imagekey diskimage-class=CRawDiskImage \
    -nomount 2>&1)

WHOLE_DISK=$(echo "$HDIUTIL_OUT" | awk 'NR==1{print $1}')
DISK_DEV=$(echo "$HDIUTIL_OUT"   | awk '/Windows_FAT/{print $1}' | head -1)

if [[ -z "$DISK_DEV" ]]; then
    hdiutil detach "$WHOLE_DISK" 2>/dev/null || true
    die "Could not find FAT32 boot partition in image.\nhdiutil output:\n$HDIUTIL_OUT"
fi

log "Boot partition device: $DISK_DEV"

# ── Mount the boot partition ──────────────────────────────────────────────────
MOUNT_DIR=$(mktemp -d)

cleanup() {
    sync 2>/dev/null || true
    umount "$MOUNT_DIR" 2>/dev/null || diskutil unmount force "$DISK_DEV" 2>/dev/null || true
    rmdir  "$MOUNT_DIR" 2>/dev/null || true
    hdiutil detach "$WHOLE_DISK" 2>/dev/null || true
}
trap cleanup EXIT

mount_msdos "$DISK_DEV" "$MOUNT_DIR" \
    || die "Could not mount boot partition ($DISK_DEV)"

log "Mounted at $MOUNT_DIR"

# ── SSH enable (idempotent — touch is safe to re-run) ────────────────────────
log "Enabling SSH..."
touch "$MOUNT_DIR/ssh"

# ── pi user password (idempotent — overwrites userconf.txt each time) ─────────
log "Writing pi user credentials..."
HASHED=$(echo "$PI_PASSWORD" | openssl passwd -6 -stdin)
echo "pi:${HASHED}" > "$MOUNT_DIR/userconf.txt"

# ── firstrun.sh ───────────────────────────────────────────────────────────────
# RPi OS Lite runs /boot/firmware/firstrun.sh automatically on Boot 1 as root,
# then deletes it and reboots. We use it to copy our files into the rootfs and
# enable adspace-bootstrap.service.
log "Writing firstrun.sh..."
cat > "$MOUNT_DIR/firstrun.sh" << FIRSTRUN
#!/bin/bash
# AdSpace firstrun — runs once on Boot 1 via RPi OS firstrun mechanism.
# Copies bootstrap.sh into rootfs and enables adspace-bootstrap.service.
# RPi OS deletes this file and reboots after it exits.

set -euo pipefail
logger -t adspace-firstrun "Starting AdSpace firstrun setup..."

BOOT="/boot/firmware"

# Set pi user password (userconf.txt is skipped when firstrun.sh is present)
echo "pi:${HASHED}" | chpasswd -e
logger -t adspace-firstrun "pi user password set"

# Enable SSH
systemctl enable ssh 2>/dev/null || true

# Copy bootstrap script into rootfs
mkdir -p /opt/adspace
cp "\$BOOT/adspace-bootstrap.sh" /opt/adspace/bootstrap.sh
chmod +x /opt/adspace/bootstrap.sh
logger -t adspace-firstrun "bootstrap.sh copied to /opt/adspace/"

# Copy and enable the service unit
cp "\$BOOT/adspace-bootstrap.service" /etc/systemd/system/adspace-bootstrap.service
systemctl daemon-reload
systemctl enable adspace-bootstrap.service
logger -t adspace-firstrun "adspace-bootstrap.service enabled — will run on next boot"
FIRSTRUN
chmod +x "$MOUNT_DIR/firstrun.sh"

# ── bootstrap.sh + service unit ───────────────────────────────────────────────
log "Copying bootstrap.sh and service unit to boot partition..."
cp "$REPO_DIR/bootstrap.sh"              "$MOUNT_DIR/adspace-bootstrap.sh"
cp "$REPO_DIR/adspace-bootstrap.service" "$MOUNT_DIR/adspace-bootstrap.service"

log "Boot partition contents:"
ls -lh \
    "$MOUNT_DIR/ssh" \
    "$MOUNT_DIR/userconf.txt" \
    "$MOUNT_DIR/firstrun.sh" \
    "$MOUNT_DIR/adspace-bootstrap.sh" \
    "$MOUNT_DIR/adspace-bootstrap.service"

# ── Unmount + detach (via trap) ───────────────────────────────────────────────
log "Unmounting..."
# trap EXIT handles cleanup

# ── Done ──────────────────────────────────────────────────────────────────────
log ""
log "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
log "  Image ready: $OUTPUT_IMG"
log ""
log "  Flash with Raspberry Pi Imager:"
log "    OS: Use Custom → select $OUTPUT_IMG"
log "    Storage: your SD card"
log "    OS Customisation: skip — SSH + pi user are already baked in"
log ""
log "  pi user password: $PI_PASSWORD"
log ""
log "  On first boot (plug in ethernet):"
log "    Boot 1 (~1 min):   firstrun.sh runs, enables bootstrap service"
log "    Boot 2 (~10 min):  bootstrap installs everything, pulls from GitHub"
log "    Boot 3:            Kiosk is live at https://screen.adspace.so"
log "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
