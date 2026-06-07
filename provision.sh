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
#   # With Tailscale (recommended — enables permanent remote SSH):
#   TAILSCALE_AUTH_KEY=tskey-auth-xxx \
#     ssh pi@<ip> "sudo --preserve-env=TAILSCALE_AUTH_KEY bash -s" < provision.sh
#
#   # Without Tailscale key (installs but doesn't authenticate):
#   ssh pi@<ip> "sudo bash -s" < provision.sh
#
# Get a Tailscale auth key:
#   https://login.tailscale.com/admin/settings/keys
#   → Generate key → Reusable: YES, Ephemeral: NO
#   One key works for all Pis.
#
# AFTER PROVISIONING (run on your Mac):
#   make deploy              # pushes frontend + API binary to Pi
#   ssh pi@<ip> sudo reboot  # reboot into kiosk
#
# After reboot, SSH via Tailscale (no key needed — Tailscale handles auth):
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
    labwc \
    wlr-randr \
    xwayland \
    caddy \
    network-manager \
    unclutter \
    unclutter-xfixes \
    curl \
    rsync \
    dnsmasq-base

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
if ! grep -q 'pi ALL=(ALL) NOPASSWD:ALL' /etc/sudoers.d/010_pi-nopasswd 2>/dev/null; then
    echo 'pi ALL=(ALL) NOPASSWD:ALL' > /etc/sudoers.d/010_pi-nopasswd
    chmod 440 /etc/sudoers.d/010_pi-nopasswd
fi

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
# AI coding agent — scoped to exactly what remote dev work needs
aiagent ALL=(ALL) NOPASSWD: /usr/bin/systemctl start adspace-*
aiagent ALL=(ALL) NOPASSWD: /usr/bin/systemctl stop adspace-*
aiagent ALL=(ALL) NOPASSWD: /usr/bin/systemctl restart adspace-*
aiagent ALL=(ALL) NOPASSWD: /usr/bin/systemctl status adspace-*
aiagent ALL=(ALL) NOPASSWD: /usr/bin/systemctl daemon-reload
aiagent ALL=(ALL) NOPASSWD: /usr/bin/journalctl
aiagent ALL=(ALL) NOPASSWD: /usr/bin/nmcli
aiagent ALL=(ALL) NOPASSWD: /bin/mv /tmp/wifi-setup-api-new /opt/adspace/wifi-setup-api
aiagent ALL=(ALL) NOPASSWD: /bin/chmod +x /opt/adspace/wifi-setup-api
aiagent ALL=(ALL) NOPASSWD: /usr/bin/tee /opt/adspace/watchdog.sh
aiagent ALL=(ALL) NOPASSWD: /usr/bin/tee /opt/adspace/start-kiosk.sh
aiagent ALL=(ALL) NOPASSWD: /usr/bin/tee /opt/adspace/start-setup-display.sh
aiagent ALL=(ALL) NOPASSWD: /usr/bin/tee /opt/adspace/kiosk.env
EOF
chmod 440 /etc/sudoers.d/aiagent

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
# adspace-watchdog: drives kiosk ↔ setup transitions based on network state.
# Runs as root via systemd. Polls every 15s.

CONFIG_JSON="/opt/adspace/wifi-setup/dist/config.json"
SETUP_FLAG="/tmp/adspace-setup-mode"
WIFI_SCAN_CACHE="/tmp/adspace-wifi-scan.json"

log() { echo "adspace-watchdog: $*"; logger -t adspace-watchdog "$*"; }

is_connected() {
    nmcli -t -f NAME,TYPE,STATE con show --active 2>/dev/null \
        | grep -v "^adspace-hotspot:" \
        | grep -qE ":(802-3-ethernet|802-11-wireless):activated$"
}

scan_networks() {
    log "Scanning for networks (before hotspot starts)..."
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
    log "Scan done: $(cat $WIFI_SCAN_CACHE)"
}

enter_kiosk() {
    log "Network up → entering kiosk mode"
    rm -f "$SETUP_FLAG"
    rm -f "$WIFI_SCAN_CACHE"
    systemctl stop caddy.service || true
    systemctl stop adspace-setup-api.service || true
    nmcli con down adspace-hotspot 2>/dev/null || true
    systemctl restart adspace-kiosk.service
}

enter_setup() {
    log "No network → entering setup mode"
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
    log "Attempting reconnect to saved networks..."
    nmcli con down adspace-hotspot 2>/dev/null || true
    sleep 20
    if is_connected; then
        log "Reconnected to saved network"
        return 0
    fi
    log "No saved network found — restoring hotspot"
    nmcli con up adspace-hotspot 2>/dev/null || true
    return 1
}

last_state=""
setup_cycles=0

while true; do
    if is_connected; then
        if [ "$last_state" != "kiosk" ]; then
            enter_kiosk
            last_state="kiosk"
            setup_cycles=0
        fi
    else
        if [ "$last_state" != "setup" ]; then
            enter_setup
            last_state="setup"
            setup_cycles=0
        else
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

cat > /opt/adspace/start-kiosk.sh << 'EOF'
#!/usr/bin/env bash
set -euo pipefail
source /opt/adspace/kiosk.env
sleep 3
unclutter -idle 0 -root &
exec "$ADSPACE_BROWSER" \
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
EOF

cat > /opt/adspace/start-setup-display.sh << 'EOF'
#!/usr/bin/env bash
set -euo pipefail
sleep 3
unclutter -idle 0 -root &
exec chromium \
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
EOF

cat > /opt/adspace/kiosk.env << 'EOF'
ADSPACE_URL="https://screen.adspace.so"
ADSPACE_BROWSER="chromium"
EOF

chmod +x /opt/adspace/watchdog.sh \
         /opt/adspace/start-kiosk.sh \
         /opt/adspace/start-setup-display.sh
chown -R adspace:adspace /opt/adspace

# ── 8. labwc autostart ────────────────────────────────────────────────────────
log "Writing labwc autostart..."
mkdir -p /home/adspace/.config/labwc
cat > /home/adspace/.config/labwc/autostart << 'EOF'
#!/bin/sh
if [ -f /tmp/adspace-setup-mode ]; then
    /opt/adspace/start-setup-display.sh
else
    /opt/adspace/start-kiosk.sh
fi
EOF
chmod +x /home/adspace/.config/labwc/autostart
chown -R adspace:adspace /home/adspace/.config

# ── 9. Caddyfile ──────────────────────────────────────────────────────────────
log "Writing Caddyfile..."
cat > /etc/caddy/Caddyfile << 'EOF'
{
    auto_https off
}

:80 {
    # Captive portal — redirect OS WiFi probes to setup page
    handle /hotspot-detect.html        { redir http://192.168.4.1/ 302 }
    handle /library/test/success.html  { redir http://192.168.4.1/ 302 }
    handle /generate_204               { redir http://192.168.4.1/ 302 }
    handle /gen_204                    { redir http://192.168.4.1/ 302 }
    handle /connecttest.txt            { redir http://192.168.4.1/ 302 }
    handle /redirect                   { redir http://192.168.4.1/ 302 }

    # WiFi setup API
    handle /api/* {
        reverse_proxy localhost:3000
    }

    # Runtime config — never cached
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

# Caddy started by watchdog only — not on boot
systemctl disable caddy.service 2>/dev/null || true

# ── 10. Systemd units ─────────────────────────────────────────────────────────
log "Installing systemd units..."

cat > /etc/systemd/system/adspace-kiosk.service << 'EOF'
[Unit]
Description=AdSpace Wayland Kiosk
After=systemd-user-sessions.service dev-dri-card1.device
Wants=dev-dri-card1.device

[Service]
User=adspace
PAMName=login
TTYPath=/dev/tty1
TTYReset=yes
TTYVHangup=yes
TTYVTDisallocate=yes
StandardInput=tty
StandardOutput=journal
StandardError=journal
WorkingDirectory=/home/adspace

Environment=XDG_SESSION_TYPE=wayland
Environment=WLR_RENDERER=gles2
Environment=WLR_DRM_DEVICES=/dev/dri/card1

ExecStartPre=/bin/sh -c 'until [ -e /dev/dri/card1 ]; do sleep 0.5; done'
ExecStart=/usr/bin/labwc

Restart=always
RestartSec=5
StartLimitIntervalSec=60
StartLimitBurst=5

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

# ── 11. Hostname from CPU serial ──────────────────────────────────────────────
log "Setting hostname..."
CPU_SERIAL=$(grep Serial /proc/cpuinfo | awk '{print $3}' | tail -c 9)
NEW_HOSTNAME="adspace-${CPU_SERIAL}"
OLD_HOSTNAME=$(hostname)
if [ "$OLD_HOSTNAME" != "$NEW_HOSTNAME" ]; then
    hostnamectl set-hostname "$NEW_HOSTNAME"
    sed -i "s/127\.0\.1\.1\s.*$/127.0.1.1\t$NEW_HOSTNAME/" /etc/hosts 2>/dev/null || true
    grep -q '127.0.1.1' /etc/hosts || echo -e "127.0.1.1\t$NEW_HOSTNAME" >> /etc/hosts
    log "Hostname: $OLD_HOSTNAME → $NEW_HOSTNAME"
else
    log "Hostname already $NEW_HOSTNAME"
fi

# ── 12. adspace-hotspot nmcli profile ────────────────────────────────────────
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

# ── 13. Tailscale ─────────────────────────────────────────────────────────────
log "Installing Tailscale..."
if ! command -v tailscale &>/dev/null; then
    curl -fsSL https://tailscale.com/install.sh | sh
else
    log "Tailscale already installed — skipping"
fi

systemctl enable --now tailscaled

if [ -n "${TAILSCALE_AUTH_KEY:-}" ]; then
    log "Authenticating Tailscale as ${NEW_HOSTNAME}..."
    tailscale up \
        --auth-key="${TAILSCALE_AUTH_KEY}" \
        --hostname="${NEW_HOSTNAME}" \
        --accept-routes \
        --ssh
    log "Tailscale authenticated — SSH available at: ssh pi@${NEW_HOSTNAME}"
else
    warn "TAILSCALE_AUTH_KEY not set — Tailscale installed but not authenticated."
    warn "To authenticate later:  sudo tailscale up --auth-key=tskey-auth-xxx"
fi

# ── Done ──────────────────────────────────────────────────────────────────────
log ""
log "────────────────────────────────────────────────────────────────"
log "✓  Provision complete!"
log ""
log "   Hostname:  ${NEW_HOSTNAME}"
if command -v tailscale &>/dev/null; then
    TS_IP=$(tailscale ip -4 2>/dev/null || echo "not authenticated yet")
    log "   Tailscale: ${TS_IP}"
fi
log ""
log "   Next — run on your Mac:"
log ""
log "   1. Deploy the app:"
log "      make deploy"
log ""
log "   2. Reboot:"
log "      ssh pi@$(hostname -I | awk '{print $1}') sudo reboot"
log ""
log "   3. After reboot, SSH via Tailscale (no key needed):"
log "      ssh pi@${NEW_HOSTNAME}"
log "────────────────────────────────────────────────────────────────"
