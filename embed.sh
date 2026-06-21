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
#   ./embed.sh ~/Downloads/2026-06-18-raspios-trixie-arm64-lite.img images/adspace-tv-v0.1.3.img
#
# REQUIREMENTS (Mac):
#   hdiutil — built into macOS, no install needed
#   openssl — built into macOS, no install needed
#
# WHAT IT DOES:
#   Mounts the FAT32 boot partition and writes:
#     custom.toml    — RPi OS Trixie native: sets pi user password + enables SSH
#     firstrun.sh    — copies bootstrap files into rootfs, enables service
#     adspace-bootstrap.sh       — full provisioning script
#     adspace-bootstrap.service  — systemd unit
#
# HOW IT WORKS:
#   RPi OS Trixie firstboot runs in this order:
#     1. Processes custom.toml  → sets pi password, enables SSH (rw, clean)
#     2. Runs firstrun.sh       → copies our files into rootfs, enables service
#     3. Reboots
#   Boot 2: adspace-bootstrap.service runs → full provisioning (~10 min)
#   Boot 3+: Normal kiosk/setup operation
#
# IDEMPOTENT: safe to re-run — always starts fresh from input image.
# =============================================================================

set -euo pipefail

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; NC='\033[0m'
log()  { echo -e "${GREEN}[embed]${NC} $*"; }
warn() { echo -e "${YELLOW}[embed]${NC} WARN: $*"; }
die()  { echo -e "${RED}[embed]${NC} ERROR: $*" >&2; exit 1; }

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# ── Pi SSH credentials baked into every image ─────────────────────────────────
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

# ── Copy image (always starts fresh from input) ───────────────────────────────
log "Copying image (this takes a moment)..."
cp "$INPUT_IMG" "$OUTPUT_IMG"

# ── Attach image, find FAT32 boot partition ───────────────────────────────────
log "Attaching image..."
HDIUTIL_OUT=$(hdiutil attach "$OUTPUT_IMG" \
    -imagekey diskimage-class=CRawDiskImage \
    -nomount 2>&1)

WHOLE_DISK=$(echo "$HDIUTIL_OUT" | awk 'NR==1{print $1}')
DISK_DEV=$(echo "$HDIUTIL_OUT"   | awk '/Windows_FAT/{print $1}' | head -1)

if [[ -z "$DISK_DEV" ]]; then
    hdiutil detach "$WHOLE_DISK" 2>/dev/null || true
    die "Could not find FAT32 boot partition.\nhdiutil output:\n$HDIUTIL_OUT"
fi

log "Boot partition device: $DISK_DEV"

# ── Mount ─────────────────────────────────────────────────────────────────────
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

# ── Hash password ─────────────────────────────────────────────────────────────
HASHED=$(echo "$PI_PASSWORD" | openssl passwd -6 -stdin)

# ── custom.toml — user credentials + SSH (RPi OS Trixie native) ──────────────
# Processed by RPi OS firstboot BEFORE firstrun.sh — runs with rw access,
# uses the proper userconf-pi mechanism. Does NOT conflict with firstrun.sh
# as long as firstrun.sh doesn't call userconf itself.
log "Writing custom.toml (pi credentials + SSH)..."
cat > "$MOUNT_DIR/custom.toml" << CUSTOMTOML
config_version = 1

[user]
name = "pi"
password = "${HASHED}"
password_encrypted = true

[ssh]
enabled = true
password_authentication = true
CUSTOMTOML

# ── firstrun.sh — copies bootstrap into rootfs, enables service ───────────────
# RPi OS runs this after custom.toml is applied, then deletes it and reboots.
# At this point the filesystem is read-write, so copies work fine.
log "Writing firstrun.sh..."
cat > "$MOUNT_DIR/firstrun.sh" << 'FIRSTRUN'
#!/bin/bash
# AdSpace firstrun — runs once on Boot 1.
# RPi OS deletes this file and reboots after it exits.
logger -t adspace-firstrun "AdSpace firstrun starting..."

BOOT="/boot/firmware"

mkdir -p /opt/adspace
cp "$BOOT/adspace-bootstrap.sh" /opt/adspace/bootstrap.sh
chmod +x /opt/adspace/bootstrap.sh

cp "$BOOT/adspace-bootstrap.service" /etc/systemd/system/adspace-bootstrap.service
systemctl daemon-reload
systemctl enable adspace-bootstrap.service

logger -t adspace-firstrun "adspace-bootstrap.service enabled — provisioning on next boot"
FIRSTRUN
chmod +x "$MOUNT_DIR/firstrun.sh"

# ── bootstrap.sh + service unit ───────────────────────────────────────────────
log "Copying bootstrap.sh and service unit..."
cp "$REPO_DIR/bootstrap.sh"              "$MOUNT_DIR/adspace-bootstrap.sh"
cp "$REPO_DIR/adspace-bootstrap.service" "$MOUNT_DIR/adspace-bootstrap.service"

log "Boot partition contents:"
ls -lh \
    "$MOUNT_DIR/custom.toml" \
    "$MOUNT_DIR/firstrun.sh" \
    "$MOUNT_DIR/adspace-bootstrap.sh" \
    "$MOUNT_DIR/adspace-bootstrap.service"

log "Unmounting..."
# trap EXIT handles cleanup

log ""
log "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
log "  Image ready: $OUTPUT_IMG"
log ""
log "  Flash with Raspberry Pi Imager — no customisation needed."
log "  pi user password: $PI_PASSWORD"
log ""
log "  On first boot (plug in ethernet):"
log "    Boot 1 (~1 min):   custom.toml sets pi password + SSH"
log "                       firstrun.sh copies bootstrap, enables service"
log "    Boot 2 (~10 min):  bootstrap installs everything, pulls from GitHub"
log "    Boot 3:            Kiosk is live at https://screen.adspace.so"
log "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
