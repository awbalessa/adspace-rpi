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
#   ./embed.sh ~/Downloads/2026-06-18-raspios-trixie-arm64-lite.img images/adspace-tv-v0.1.5.img
#
# REQUIREMENTS (Mac):
#   hdiutil — built into macOS, no install needed
#   openssl — built into macOS, no install needed
#
# HOW IT WORKS:
#   This RPi OS Trixie image uses cloud-init (not the firstboot/firstrun.sh
#   mechanism). We replace user-data with a cloud-init config that:
#     - Creates the pi user with a known password
#     - Enables SSH with password authentication
#     - Copies bootstrap.sh into /opt/adspace/ via write_files
#     - Installs and enables adspace-bootstrap.service via write_files
#     - Runs bootstrap.sh on first boot via runcmd
#
#   All files also placed on the boot partition so cloud-init can reference them.
#
# IDEMPOTENT: always starts fresh from the input image.
# =============================================================================

set -euo pipefail

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; NC='\033[0m'
log()  { echo -e "${GREEN}[embed]${NC} $*"; }
warn() { echo -e "${YELLOW}[embed]${NC} WARN: $*"; }
die()  { echo -e "${RED}[embed]${NC} ERROR: $*" >&2; exit 1; }

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# ── Credentials ───────────────────────────────────────────────────────────────
PI_PASSWORD="adspace"

# ── Args ──────────────────────────────────────────────────────────────────────
INPUT_IMG="${1:-}"
OUTPUT_IMG="${2:-${REPO_DIR}/images/adspace-tv.img}"

[[ -n "$INPUT_IMG" ]]  || die "Usage: ./embed.sh <rpios-lite.img> [output.img]"
[[ -f "$INPUT_IMG" ]]  || die "Input image not found: $INPUT_IMG"
[[ -f "$REPO_DIR/bootstrap.sh" ]] \
    || die "bootstrap.sh not found in repo root"
[[ -f "$REPO_DIR/adspace-bootstrap.service" ]] \
    || die "adspace-bootstrap.service not found in repo root"

log "Input:  $INPUT_IMG"
log "Output: $OUTPUT_IMG"

# ── Copy image ────────────────────────────────────────────────────────────────
log "Copying image..."
cp "$INPUT_IMG" "$OUTPUT_IMG"

# ── Attach + mount boot partition ─────────────────────────────────────────────
log "Attaching image..."
HDIUTIL_OUT=$(hdiutil attach "$OUTPUT_IMG" \
    -imagekey diskimage-class=CRawDiskImage -nomount 2>&1)

WHOLE_DISK=$(echo "$HDIUTIL_OUT" | awk 'NR==1{print $1}')
DISK_DEV=$(echo "$HDIUTIL_OUT"   | awk '/Windows_FAT/{print $1}' | head -1)

[[ -n "$DISK_DEV" ]] || {
    hdiutil detach "$WHOLE_DISK" 2>/dev/null || true
    die "Could not find FAT32 boot partition.\nhdiutil output:\n$HDIUTIL_OUT"
}

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

# ── Hash the password ─────────────────────────────────────────────────────────
HASHED=$(echo "$PI_PASSWORD" | openssl passwd -6 -stdin)

# ── Read bootstrap.sh and service file contents for embedding ─────────────────
BOOTSTRAP_CONTENT=$(cat "$REPO_DIR/bootstrap.sh")
SERVICE_CONTENT=$(cat "$REPO_DIR/adspace-bootstrap.service")

# ── Write cloud-init user-data ────────────────────────────────────────────────
# This image uses cloud-init (not firstboot/firstrun.sh).
# user-data is the correct and only mechanism that runs on first boot.
log "Writing cloud-init user-data..."
cat > "$MOUNT_DIR/user-data" << USERDATA
#cloud-config

# AdSpace — first boot provisioning via cloud-init

# Create pi user with known password and sudo access
users:
  - name: pi
    gecos: Pi User
    groups: [adm, dialout, cdrom, sudo, audio, video, plugdev, games, users, input, render, netdev, spi, i2c, gpio]
    sudo: ALL=(ALL) NOPASSWD:ALL
    shell: /bin/bash
    lock_passwd: false
    passwd: "${HASHED}"

# Enable SSH with password authentication
ssh_pwauth: true

# Write bootstrap.sh and service unit directly to the filesystem
write_files:
  - path: /opt/adspace/bootstrap.sh
    permissions: '0755'
    owner: root:root
    content: |
$(echo "$BOOTSTRAP_CONTENT" | sed 's/^/      /')

  - path: /etc/systemd/system/adspace-bootstrap.service
    permissions: '0644'
    owner: root:root
    content: |
$(echo "$SERVICE_CONTENT" | sed 's/^/      /')

# Enable SSH and bootstrap service, then run bootstrap
runcmd:
  - systemctl enable ssh
  - systemctl start ssh
  - systemctl enable adspace-bootstrap.service
  - systemctl start adspace-bootstrap.service
USERDATA

log "user-data written ($(wc -l < "$MOUNT_DIR/user-data") lines)"

log "Boot partition key files:"
ls -lh "$MOUNT_DIR/user-data" "$MOUNT_DIR/meta-data" 2>/dev/null || true

log "Unmounting..."

log ""
log "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
log "  Image ready: $OUTPUT_IMG"
log ""
log "  Flash with Raspberry Pi Imager — no customisation needed."
log "  pi user password: $PI_PASSWORD"
log ""
log "  On first boot (plug in ethernet):"
log "    Boot 1: cloud-init runs — creates pi user, enables SSH,"
log "            installs bootstrap.sh, starts adspace-bootstrap.service"
log "    ~10 min: bootstrap installs everything, registers Tailscale"
log "    After:   Kiosk is live at https://screen.adspace.so"
log "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
