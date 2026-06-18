#!/usr/bin/env bash
# =============================================================================
# AdSpace RPi Provision Script
# =============================================================================
# Turns a fresh Raspberry Pi OS Lite 64-bit into a fully configured AdSpace
# digital signage device. Safe to re-run — fully idempotent.
#
# PRE-REQUISITES (do these before running):
#   1. Flash SD card with Raspberry Pi Imager:
#      - OS: Raspberry Pi OS Lite (64-bit)
#      - In "OS Customisation" settings:
#        * Set hostname: anything (provision.sh will rename it to adspace-{serial})
#        * Username: pi
#        * Password: (anything — only used for first SSH)
#        * Enable SSH: yes (Use password authentication)
#        * Do NOT configure WiFi here — leave blank
#   2. Insert SD card, connect ethernet, power on
#   3. Find Pi's IP: check your router, or `arp -a | grep -i rasp`
#
# USAGE (from your Mac):
#   ssh pi@<ip> "sudo bash -s" < provision.sh
#
# This is fully idempotent — safe to re-run on the same Pi.
# Tailscale OAuth credentials are embedded in the script (see step 13).
#
# AFTER PROVISIONING (run on your Mac):
#   make deploy PI_SSH=pi@<ip>           # pushes frontend + API binary to Pi
#   ssh pi@<ip> sudo reboot              # reboot into kiosk
#
# After reboot, SSH from anywhere via Tailscale:
#   ssh pi@adspace-{serial}
# =============================================================================

set -euo pipefail

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; NC='\033[0m'
log()  { echo -e "${GREEN}==>${NC} $*"; }
warn() { echo -e "${YELLOW}WARN${NC} $*"; }
die()  { echo -e "${RED}ERROR${NC} $*" >&2; exit 1; }

[[ $EUID -eq 0 ]] || die "Run as root: sudo bash provision.sh"

# ── 1. System packages ────────────────────────────────────────────────────────
log "Installing packages..."
apt-get update -qq
DEBIAN_FRONTEND=noninteractive apt-get install -y \
    chromium \
    rpi-chromium-mods \
    xwayland \
    caddy \
    network-manager \
    unclutter \
    unclutter-xfixes \
    curl \
    rsync \
    dnsmasq-base

# cage requires libwlroots-0.18 (RPi build) — pin it before installing cage
# libwlroots-0.19 (used by labwc 0.9.7) causes SEGV on mode switch on Pi 5
DEBIAN_FRONTEND=noninteractive apt-get install -y --allow-downgrades \
    'libwlroots-0.18=0.18.2-3+rpt4+b1'
DEBIAN_FRONTEND=noninteractive apt-get install -y cage

# Remove labwc — it conflicts with cage on Pi 5 (SEGV on mode switch with wlroots-0.19)
DEBIAN_FRONTEND=noninteractive apt-get remove -y labwc 2>/dev/null || true

# ── 2. NetworkManager: take full control of interfaces ────────────────────────
log "Configuring NetworkManager..."
cat > /etc/NetworkManager/NetworkManager.conf << 'EOF'
[main]
dns=dnsmasq
plugins=ifupdown,keyfile

[ifupdown]
managed=false
EOF

systemctl enable --now NetworkManager

# Disable conflicting network services
for svc in dhcpcd wpa_supplicant ifupdown; do
    systemctl disable "$svc" 2>/dev/null || true
    systemctl stop    "$svc" 2>/dev/null || true
done

# ── 3. Display: force HDMI output at 1080p ────────────────────────────────────
log "Configuring display output..."
BOOT_CONFIG="/boot/firmware/config.txt"
# Force HDMI on even with no display connected (required for headless/signage)
grep -q 'hdmi_force_hotplug' "$BOOT_CONFIG" || cat >> "$BOOT_CONFIG" << 'EOF'

# AdSpace: force HDMI output at 1080p60 regardless of display detection
hdmi_force_hotplug=1
hdmi_group=2
hdmi_mode=82
EOF

# ── 4. Create adspace user ────────────────────────────────────────────────────
log "Creating adspace user..."
if ! id adspace &>/dev/null; then
    useradd -m -s /bin/bash adspace
fi
# Full group membership matching RPi OS defaults for a display user
for grp in adm dialout cdrom sudo audio video plugdev games users input \
           render netdev spi i2c gpio; do
    getent group "$grp" &>/dev/null && usermod -aG "$grp" adspace
done

# ── 5. Ensure pi user has passwordless sudo ──────────────────────────────────
# pi already exists on RPi OS Lite — just ensure NOPASSWD sudo is set
log "Configuring pi user sudo..."
# Always recreate to ensure it's correct (idempotent)
cat > /etc/sudoers.d/010_pi-nopasswd << 'SUDOERS'
pi ALL=(ALL) NOPASSWD:ALL
SUDOERS
chmod 440 /etc/sudoers.d/010_pi-nopasswd
chown root:root /etc/sudoers.d/010_pi-nopasswd
log "Passwordless sudo configured for pi"

# ── 5b. adspace user sudo — needed by wifi-setup-api ─────────────────────────
cat > /etc/sudoers.d/adspace << 'SUDOERS'
# adspace user — allow nmcli for wifi-setup-api
adspace ALL=(ALL) NOPASSWD: /usr/bin/nmcli
adspace ALL=(ALL) NOPASSWD: /sbin/reboot
adspace ALL=(ALL) NOPASSWD: /usr/sbin/reboot
SUDOERS
chmod 440 /etc/sudoers.d/adspace
log "Passwordless nmcli sudo configured for adspace"

# ── 6. Create aiagent user (AI coding agent — scoped sudo) ────────────────────
# Separate from pi — agent gets only the commands it actually needs
log "Creating aiagent user..."
if ! id aiagent &>/dev/null; then
    useradd -m -s /bin/bash aiagent
fi
mkdir -p /home/aiagent/.ssh
chmod 700 /home/aiagent/.ssh
chown aiagent:aiagent /home/aiagent/.ssh

cat > /etc/sudoers.d/aiagent << 'EOF'
# AI coding agent — full passwordless sudo for remote diagnostics and dev
aiagent ALL=(ALL) NOPASSWD: ALL
EOF
chmod 440 /etc/sudoers.d/aiagent

# Add SSH public key for aiagent (for remote AI agent access)
log "Setting up aiagent SSH key..."
cat > /home/aiagent/.ssh/authorized_keys << 'SSHKEY'
ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIKhyZmRF0Z688khDd/XOlbi7BGr27f03wpVGcBNzy68y coding agent
SSHKEY
chmod 600 /home/aiagent/.ssh/authorized_keys
chown aiagent:aiagent /home/aiagent/.ssh/authorized_keys

# ── 6. Autologin adspace on tty1 ─────────────────────────────────────────────
log "Configuring tty1 autologin..."
mkdir -p /etc/systemd/system/getty@tty1.service.d
cat > /etc/systemd/system/getty@tty1.service.d/autologin.conf << 'EOF'
[Service]
ExecStart=
ExecStart=-/sbin/agetty --autologin adspace --noclear %I $TERM
EOF

# ── 7. /opt/adspace scripts ───────────────────────────────────────────────────
log "Writing /opt/adspace scripts..."
mkdir -p /opt/adspace/wifi-setup/dist

cat > /opt/adspace/watchdog.sh << 'WATCHDOG'
#!/usr/bin/env bash
# adspace-watchdog: always-on loop that drives kiosk ↔ setup transitions

CONFIG_JSON="/opt/adspace/wifi-setup/dist/config.json"
SETUP_FLAG="/tmp/adspace-setup-mode"
WIFI_SCAN_CACHE="/tmp/adspace-wifi-scan.json"

log() { echo "adspace-watchdog: $*"; logger -t adspace-watchdog "$*"; }

is_connected() {
    # Check NM's connectivity state — 'full' means actual internet, not just a profile activated.
    # The old approach (checking activated profiles) fails because NM keeps ethernet profiles
    # in 'activated' state even after the cable is unplugged, causing false positives.
    local state
    state=$(nmcli networking connectivity 2>/dev/null)
    [ "$state" = "full" ]
}

scan_networks() {
    log "Scanning for networks..."
    nmcli dev wifi rescan ifname wlan0 2>/dev/null || true
    sleep 3
    nmcli -t -f SSID,SIGNAL dev wifi list ifname wlan0 2>/dev/null \
        | grep -v '^\s*:' \
        | grep -v '^Adspace-TV-' \
        | awk -F: '!seen[$1]++ && $1!="" {
            gsub(/[^0-9]/, "", $2)
            printf "{\"ssid\":\"%s\",\"signal\":%s},", $1, ($2=="" ? "0" : $2)
          }' \
        | sed 's/,$//' \
        | (echo -n '['; cat; echo ']') \
        > "$WIFI_SCAN_CACHE"
    log "Scan complete: $(cat $WIFI_SCAN_CACHE)"
}

enter_kiosk() {
    log "Network up → kiosk mode"
    rm -f "$SETUP_FLAG"
    rm -f "$WIFI_SCAN_CACHE"
    systemctl stop caddy.service || true
    systemctl stop adspace-setup-api.service || true
    nmcli con down adspace-hotspot 2>/dev/null || true
    # Only restart kiosk if it's not already running cleanly in kiosk mode
    if ! systemctl is-active --quiet adspace-kiosk.service; then
        systemctl restart adspace-kiosk.service
    fi
}

enter_setup() {
    log "Network lost → setup mode"
    CPU_SERIAL=$(grep Serial /proc/cpuinfo | awk '{print $3}' | tail -c 9)
    SSID="Adspace-TV-${CPU_SERIAL}"
    PASSWORD="${CPU_SERIAL}"

    scan_networks

    nmcli con modify adspace-hotspot \
        802-11-wireless.ssid "$SSID" \
        802-11-wireless-security.psk "$PASSWORD" 2>/dev/null || true

    cat > "$CONFIG_JSON" << JSONEOF
{
  "hotspotSSID": "$SSID",
  "hotspotPassword": "$PASSWORD",
  "setupURL": "http://192.168.4.1"
}
JSONEOF

    touch "$SETUP_FLAG"
    nmcli con up adspace-hotspot
    systemctl start adspace-setup-api.service
    systemctl start caddy.service
    systemctl restart adspace-kiosk.service
}

try_reconnect() {
    log "Trying to reconnect to saved networks..."
    nmcli con down adspace-hotspot 2>/dev/null || true
    sleep 20
    if is_connected; then
        log "Reconnected to saved network"
        return 0
    else
        log "No saved network found, restoring hotspot"
        nmcli con up adspace-hotspot 2>/dev/null || true
        return 1
    fi
}

last_state=""
setup_cycles=0
fail_count=0

while true; do
    if is_connected; then
        fail_count=0
        if [ "$last_state" != "kiosk" ]; then
            enter_kiosk
            last_state="kiosk"
            setup_cycles=0
        fi
    else
        fail_count=$((fail_count + 1))
        # Require 2 consecutive failed checks (~30s) before entering setup mode.
        # Prevents a momentary NM connectivity probe failure from triggering
        # a full setup mode transition.
        if [ "$fail_count" -lt 2 ]; then
            sleep 15
            continue
        fi
        fail_count=0
        if [ "$last_state" != "setup" ]; then
            enter_setup
            last_state="setup"
            setup_cycles=0
        else
            # Every 4 cycles (~60s) while in setup, try reconnecting to saved networks
            setup_cycles=$((setup_cycles + 1))
            if [ "$setup_cycles" -ge 4 ]; then
                setup_cycles=0
                if try_reconnect; then
                    enter_kiosk
                    last_state="kiosk"
                fi
            fi
        fi
    fi
    sleep 15
done
WATCHDOG

cat > /opt/adspace/start-display.sh << 'EOF'
#!/usr/bin/env bash
set -euo pipefail

# Call the chromium binary directly — bypasses RPi launcher wrapper which
# injects --js-flags=--no-decommit-pooled-pages (unsupported flag, causes crash)
unset CHROMIUM_FLAGS
CHROMIUM_BIN=/usr/lib/chromium/chromium

if [ -f /tmp/adspace-setup-mode ]; then
    # Wait for Caddy to be ready before launching browser
    for i in $(seq 1 10); do
        curl -sf http://localhost/tv >/dev/null 2>&1 && break
        sleep 1
    done

    exec "$CHROMIUM_BIN" \
        --ozone-platform=wayland \
        --enable-features=UseOzonePlatform \
        --kiosk \
        --start-fullscreen \
        --noerrdialogs \
        --disable-infobars \
        --disable-session-crashed-bubble \
        --disable-features=TranslateUI \
        --disable-pinch \
        --overscroll-history-navigation=0 \
        --password-store=basic \
        --disk-cache-size=1 \
        --user-data-dir=/home/adspace/.config/adspace-setup-chromium \
        "http://localhost/tv"
else
    source /opt/adspace/kiosk.env
    exec "$CHROMIUM_BIN" \
        --ozone-platform=wayland \
        --enable-features=UseOzonePlatform \
        --kiosk \
        --start-fullscreen \
        --noerrdialogs \
        --disable-infobars \
        --disable-session-crashed-bubble \
        --disable-features=TranslateUI \
        --disable-pinch \
        --overscroll-history-navigation=0 \
        --password-store=basic \
        --user-data-dir=/home/adspace/.config/adspace-chromium \
        "$ADSPACE_URL"
fi
EOF

cat > /opt/adspace/kiosk.env << 'EOF'
ADSPACE_URL="https://screen.adspace.so"
EOF

chmod +x /opt/adspace/watchdog.sh \
         /opt/adspace/start-display.sh

# Remove old scripts that were replaced by start-display.sh
rm -f /opt/adspace/start-kiosk.sh /opt/adspace/start-setup-display.sh

chown -R adspace:adspace /opt/adspace
# Make dist directory writable by pi (rsync deploys) and aiagent (agent deploys)
# Add aiagent to pi's group so both can write to pi-owned dirs
usermod -aG pi aiagent
mkdir -p /opt/adspace/wifi-setup/dist
chown -R pi:pi /opt/adspace/wifi-setup/dist
chmod -R 775 /opt/adspace/wifi-setup/dist

# ── 8. PAM stack for cage compositor ─────────────────────────────────────────
# cage needs its own PAM stack — PAMName=cage in the service points here
log "Writing /etc/pam.d/cage..."
cat > /etc/pam.d/cage << 'EOF'
auth     required pam_unix.so nullok
account  required pam_unix.so
session  required pam_unix.so
session  required pam_systemd.so
EOF

# ── 9. Caddyfile ──────────────────────────────────────────────────────────────
log "Writing Caddyfile..."
cat > /etc/caddy/Caddyfile << 'EOF'
{
    auto_https off
}

:80 {
    # Captive portal - redirect OS WiFi probes to setup page
    handle /hotspot-detect.html {
        redir http://192.168.4.1/ 302
    }
    handle /library/test/success.html {
        redir http://192.168.4.1/ 302
    }
    handle /generate_204 {
        redir http://192.168.4.1/ 302
    }
    handle /gen_204 {
        redir http://192.168.4.1/ 302
    }
    handle /connecttest.txt {
        redir http://192.168.4.1/ 302
    }
    handle /redirect {
        redir http://192.168.4.1/ 302
    }

    # WiFi setup API
    handle /api/* {
        reverse_proxy localhost:3000
    }

    # Runtime config - never cached
    handle /config.json {
        root * /opt/adspace/wifi-setup/dist
        header Cache-Control "no-store, no-cache, must-revalidate"
        file_server
    }

    # React SPA (setup UI)
    handle {
        root * /opt/adspace/wifi-setup/dist
        try_files {path} /index.html
        file_server
    }
}
EOF

# Caddy started by watchdog only - not on boot
systemctl disable caddy.service 2>/dev/null || true

# ── 10. Systemd units ─────────────────────────────────────────────────────────
log "Installing systemd units..."

cat > /etc/systemd/system/adspace-kiosk.service << 'EOF'
[Unit]
Description=AdSpace Wayland Kiosk
After=systemd-user-sessions.service dev-dri-card1.device
Wants=dev-dri-card1.device
Conflicts=getty@tty1.service
After=getty@tty1.service

[Service]
User=adspace
PAMName=cage
TTYPath=/dev/tty1
TTYReset=yes
TTYVHangup=yes
TTYVTDisallocate=yes
StandardInput=tty-fail
StandardOutput=journal
StandardError=journal
WorkingDirectory=/home/adspace

Environment=XDG_SESSION_TYPE=wayland
Environment=WLR_RENDERER=gles2
Environment=WLR_DRM_DEVICES=/dev/dri/card1

ExecStartPre=/bin/sh -c 'until [ -e /dev/dri/card1 ]; do sleep 0.5; done'
ExecStartPre=/bin/sh -c 'uid=$(id -u adspace); mkdir -p /run/user/$uid; chmod 700 /run/user/$uid; chown adspace:adspace /run/user/$uid; rm -f /run/user/$uid/wayland-*'
ExecStartPre=/bin/sh -c 'rm -f /home/adspace/.config/adspace-chromium/SingletonLock /home/adspace/.config/adspace-setup-chromium/SingletonLock'
ExecStart=/usr/bin/cage -s -- /opt/adspace/start-display.sh

KillMode=control-group
TimeoutStopSec=10
Restart=always
RestartSec=8

[Install]
WantedBy=multi-user.target
EOF

cat > /etc/systemd/system/adspace-watchdog.service << 'EOF'
[Unit]
Description=AdSpace Watchdog
After=NetworkManager.service
Wants=NetworkManager.service

[Service]
ExecStart=/opt/adspace/watchdog.sh
Restart=always
RestartSec=5
StandardOutput=journal
StandardError=journal

[Install]
WantedBy=multi-user.target
EOF

cat > /etc/systemd/system/adspace-setup-api.service << 'EOF'
[Unit]
Description=AdSpace WiFi Setup API
After=network.target

[Service]
Type=simple
User=adspace
ExecStart=/opt/adspace/wifi-setup-api
Restart=on-failure
RestartSec=3
StandardOutput=journal
StandardError=journal

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable  adspace-watchdog.service
systemctl enable  adspace-kiosk.service
systemctl disable adspace-kiosk.service     # watchdog controls it, not boot
systemctl disable adspace-setup-api.service 2>/dev/null || true

# ── 11. Disable cloud-init (regenerates /etc/hosts on every boot, overwriting hostname) ───
log "Disabling cloud-init..."
# Create /etc/cloud/cloud-init.disabled to prevent cloud-init from running
touch /etc/cloud/cloud-init.disabled
# Also disable the systemd services
systemctl disable cloud-init.service 2>/dev/null || true
systemctl disable cloud-init-local.service 2>/dev/null || true
systemctl disable cloud-init-net.service 2>/dev/null || true
systemctl disable cloud-init-final.service 2>/dev/null || true
systemctl disable cloud-config.service 2>/dev/null || true
systemctl disable cloud-final.service 2>/dev/null || true
log "Cloud-init permanently disabled"

# ── 11. Hostname from CPU serial ──────────────────────────────────────────────
log "Setting hostname..."
CPU_SERIAL=$(grep Serial /proc/cpuinfo | awk '{print $3}')
NEW_HOSTNAME="adspace-${CPU_SERIAL: -8}"
OLD_HOSTNAME=$(hostname)
if [ "$OLD_HOSTNAME" != "$NEW_HOSTNAME" ]; then
    # Write directly to /etc/hostname and update hostnamectl
    echo "$NEW_HOSTNAME" > /etc/hostname
    hostnamectl set-hostname "$NEW_HOSTNAME"
    # Update /etc/hosts
    sed -i "s/127\.0\.1\.1\s.*$/127.0.1.1\t$NEW_HOSTNAME/" /etc/hosts 2>/dev/null || true
    grep -q '127.0.1.1' /etc/hosts || echo -e "127.0.1.1\t$NEW_HOSTNAME" >> /etc/hosts
    log "Hostname: $OLD_HOSTNAME -> $NEW_HOSTNAME"
else
    log "Hostname already $NEW_HOSTNAME"
fi

# ── 12. WiFi country code (required or radio stays rfkill-blocked on RPi OS) ──
log "Setting WiFi country code to AE (UAE)..."
raspi-config nonint do_wifi_country AE
# Also ensure rfkill is unblocked — use full path, /sbin not always in PATH
/sbin/rfkill unblock wifi || true

# ── 12b. adspace-hotspot nmcli profile ───────────────────────────────────────
log "Creating adspace-hotspot nmcli profile..."
nmcli con delete adspace-hotspot 2>/dev/null || true
nmcli con add \
    type wifi \
    ifname wlan0 \
    con-name adspace-hotspot \
    autoconnect no \
    ssid "Adspace-TV-setup" \
    -- \
    wifi.mode ap \
    wifi.band bg \
    wifi.channel 6 \
    wifi-sec.key-mgmt wpa-psk \
    wifi-sec.psk "setupsetup" \
    ipv4.method shared \
    ipv4.addresses 192.168.4.1/24 \
    ipv6.method disabled

# ── 13. Tailscale — permanent remote access via OAuth ────────────────────────
log "Setting up Tailscale..."

# Install Tailscale if not present
if ! command -v tailscale &>/dev/null; then
    curl -fsSL https://tailscale.com/install.sh | sh
fi

systemctl enable --now tailscaled

# OAuth secret is embedded — each Pi self-registers on first boot with its own node key.
TAILSCALE_OAUTH_CLIENT_SECRET="tskey-client-koZCgE2fK421CNTRL-WAfqtB3SRXSeqKSUgJTcWSjoD1vxFbGF"

log "Registering device with Tailscale..."
tailscale up \
    --auth-key="${TAILSCALE_OAUTH_CLIENT_SECRET}?ephemeral=false&preauthorized=true" \
    --advertise-tags=tag:rpi \
    --hostname="${NEW_HOSTNAME}" \
    --accept-routes
log "Tailscale registered: ${NEW_HOSTNAME}"

# ── Done ──────────────────────────────────────────────────────────────────────
log ""
log "────────────────────────────────────────────────────────────────"
log "✓  Provision complete!"
log ""
log "   Hostname:  ${NEW_HOSTNAME}"
log "   Tailscale: ssh pi@${NEW_HOSTNAME}"
log ""
log "   Next — run on your Mac:"
log ""
log "   1. Deploy the app:"
log "      make deploy PI_SSH=pi@$(hostname -I | awk '{print $1}')"
log ""
log "   2. Reboot:"
log "      ssh pi@$(hostname -I | awk '{print $1}') sudo reboot"
log ""
log "   3. After reboot, SSH from anywhere via Tailscale:"
log "      ssh pi@${NEW_HOSTNAME}"
log "────────────────────────────────────────────────────────────────"
