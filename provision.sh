#!/usr/bin/env bash
# =============================================================================
# AdSpace RPi Provision Script
# =============================================================================
# Run ONCE on a fresh Raspberry Pi OS Lite 64-bit (Debian Trixie/Bookworm).
# Safe to re-run — fully idempotent. Same input → same output, no side effects.
#
# Usage (from your Mac):
#   ssh pi@<ip> "sudo bash -s" < provision.sh
#
# Pre-requisites on the Pi:
#   - RPi OS Lite 64-bit, fresh flash
#   - SSH enabled (create /boot/ssh file or use Raspberry Pi Imager)
#   - Internet access (to install packages)
#
# What this does:
#   1.  Creates 'adspace' user with correct groups
#   2.  Creates 'aiagent' user with scoped sudoers for remote agent access
#   3.  Installs deps: chromium, labwc, caddy, network-manager, unclutter
#   4.  Configures autologin for adspace on tty1
#   5.  Writes /opt/adspace/{watchdog.sh,start-kiosk.sh,start-setup-display.sh,kiosk.env}
#   6.  Writes labwc autostart
#   7.  Writes Caddyfile
#   8.  Installs systemd units: adspace-kiosk, adspace-watchdog, adspace-setup-api
#   9.  Creates adspace-hotspot nmcli profile (SSID/password set at runtime by watchdog)
#   10. Enables adspace-watchdog (only service that starts on boot)
#
# After running this script, deploy the frontend + API binary:
#   make deploy        (from repo root on your Mac)
#
# Then reboot the Pi:
#   ssh pi@<ip> sudo reboot
# =============================================================================

set -euo pipefail

# ── Colours ───────────────────────────────────────────────────────────────────
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; NC='\033[0m'
log()  { echo -e "${GREEN}==>${NC} $*"; }
warn() { echo -e "${YELLOW}WARN${NC} $*"; }
die()  { echo -e "${RED}ERROR${NC} $*" >&2; exit 1; }

[[ $EUID -eq 0 ]] || die "Run as root: sudo bash provision.sh"

# ── 1. Create adspace user ────────────────────────────────────────────────────
log "Creating adspace user..."
if ! id adspace &>/dev/null; then
    useradd -m -s /bin/bash adspace
fi
# Ensure correct group membership (idempotent)
for grp in video render audio input plugdev; do
    getent group "$grp" &>/dev/null && usermod -aG "$grp" adspace
done

# ── 2. Create aiagent user (scoped remote management) ─────────────────────────
log "Creating aiagent user..."
if ! id aiagent &>/dev/null; then
    useradd -m -s /bin/bash aiagent
fi
mkdir -p /home/aiagent/.ssh
chmod 700 /home/aiagent/.ssh
chown aiagent:aiagent /home/aiagent/.ssh

# Scoped sudoers — only what the agent actually needs
cat > /etc/sudoers.d/aiagent << 'EOF'
# AdSpace AI agent — scoped remote management access
aiagent ALL=(ALL) NOPASSWD: \
    /usr/bin/systemctl start adspace-*, \
    /usr/bin/systemctl stop adspace-*, \
    /usr/bin/systemctl restart adspace-*, \
    /usr/bin/systemctl status adspace-*, \
    /usr/bin/journalctl, \
    /usr/bin/nmcli, \
    /bin/mv /tmp/wifi-setup-api-new /opt/adspace/wifi-setup-api, \
    /bin/chmod +x /opt/adspace/wifi-setup-api, \
    /usr/bin/tee /opt/adspace/watchdog.sh, \
    /usr/bin/tee /opt/adspace/start-kiosk.sh, \
    /usr/bin/tee /opt/adspace/start-setup-display.sh, \
    /usr/bin/tee /opt/adspace/kiosk.env, \
    /bin/systemctl daemon-reload
EOF
chmod 440 /etc/sudoers.d/aiagent

# ── 3. Install dependencies ───────────────────────────────────────────────────
log "Installing packages..."
apt-get update -qq
DEBIAN_FRONTEND=noninteractive apt-get install -y \
    chromium \
    labwc \
    caddy \
    network-manager \
    unclutter \
    curl \
    rsync

# Ensure NetworkManager is running
systemctl enable --now NetworkManager

# Disable dhcpcd if present (conflicts with NetworkManager)
systemctl disable dhcpcd 2>/dev/null || true
systemctl stop dhcpcd 2>/dev/null || true

# ── 4. Autologin adspace on tty1 ─────────────────────────────────────────────
log "Configuring tty1 autologin..."
mkdir -p /etc/systemd/system/getty@tty1.service.d
cat > /etc/systemd/system/getty@tty1.service.d/autologin.conf << 'EOF'
[Service]
ExecStart=
ExecStart=-/sbin/agetty --autologin adspace --noclear %I $TERM
EOF

# ── 5. /opt/adspace scripts ───────────────────────────────────────────────────
log "Writing /opt/adspace scripts..."
mkdir -p /opt/adspace/wifi-setup/dist

# watchdog.sh
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

    # Scan while wlan0 is still a client (before hotspot takes over the interface)
    scan_networks

    # Update hotspot profile with this device's unique SSID
    nmcli con modify adspace-hotspot \
        802-11-wireless.ssid "$SSID" \
        802-11-wireless-security.psk "$PASSWORD" 2>/dev/null || true

    # Write config.json for the TV setup page to read
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
    # Briefly drop hotspot so NetworkManager can attempt saved WiFi connections.
    # wlan0 can't be AP and client simultaneously.
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
            # Every ~60s in setup mode, try reconnecting to previously saved networks
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

# start-kiosk.sh
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

# start-setup-display.sh
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

# kiosk.env
cat > /opt/adspace/kiosk.env << 'EOF'
ADSPACE_URL="https://screen.adspace.so"
ADSPACE_BROWSER="chromium"
EOF

chmod +x /opt/adspace/watchdog.sh \
         /opt/adspace/start-kiosk.sh \
         /opt/adspace/start-setup-display.sh
chown -R adspace:adspace /opt/adspace

# ── 6. labwc autostart ────────────────────────────────────────────────────────
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

# ── 7. Caddyfile ──────────────────────────────────────────────────────────────
log "Writing Caddyfile..."
cat > /etc/caddy/Caddyfile << 'EOF'
{
    auto_https off
}

:80 {
    # Captive portal — redirect OS probes to setup page
    handle /hotspot-detect.html        { redir http://192.168.4.1/ 302 }
    handle /library/test/success.html  { redir http://192.168.4.1/ 302 }
    handle /generate_204               { redir http://192.168.4.1/ 302 }
    handle /gen_204                    { redir http://192.168.4.1/ 302 }
    handle /connecttest.txt            { redir http://192.168.4.1/ 302 }
    handle /redirect                   { redir http://192.168.4.1/ 302 }

    # API
    handle /api/* {
        reverse_proxy localhost:3000
    }

    # Runtime config — never cached
    handle /config.json {
        root * /opt/adspace/wifi-setup/dist
        header Cache-Control "no-store, no-cache, must-revalidate"
        file_server
    }

    # React SPA
    handle {
        root * /opt/adspace/wifi-setup/dist
        try_files {path} /index.html
        file_server
    }
}
EOF

# Caddy is started by watchdog only — not on boot
systemctl disable caddy.service 2>/dev/null || true

# ── 8. Systemd units ──────────────────────────────────────────────────────────
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

# Wait for GPU device to be available before starting
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

# Only watchdog starts on boot — it controls everything else
systemctl enable  adspace-watchdog.service
systemctl enable  adspace-kiosk.service     # unit exists, but watchdog calls systemctl restart
systemctl disable adspace-kiosk.service     # ... so don't auto-start independently
systemctl disable adspace-setup-api.service 2>/dev/null || true

# ── 9. Set hostname from CPU serial ─────────────────────────────────────────
log "Setting hostname from CPU serial..."
CPU_SERIAL=$(grep Serial /proc/cpuinfo | awk '{print $3}' | tail -c 9)
NEW_HOSTNAME="adspace-${CPU_SERIAL}"
OLD_HOSTNAME=$(hostname)
if [ "$OLD_HOSTNAME" != "$NEW_HOSTNAME" ]; then
    hostnamectl set-hostname "$NEW_HOSTNAME"
    sed -i "s/127\.0\.1\.1\s.*$/127.0.1.1\t$NEW_HOSTNAME/" /etc/hosts 2>/dev/null || true
    grep -q '127.0.1.1' /etc/hosts || echo "127.0.1.1\t$NEW_HOSTNAME" >> /etc/hosts
    log "Hostname set to $NEW_HOSTNAME (was $OLD_HOSTNAME)"
else
    log "Hostname already $NEW_HOSTNAME — no change"
fi

# ── 10. adspace-hotspot nmcli profile ────────────────────────────────────────
log "Creating adspace-hotspot nmcli profile..."
# Delete and recreate — idempotent
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

log ""
log "────────────────────────────────────────────────────────"
log "✓  Provision complete!"
log ""
log "Next steps:"
log "  1. From your Mac, deploy the app:  make deploy"
log "  2. Reboot the Pi:                  ssh <user>@<ip> sudo reboot"
log "  3. Verify kiosk boots correctly"
log "  4. If this is for a golden image:  sudo bash clone-image.sh"
log "────────────────────────────────────────────────────────"
