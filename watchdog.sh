#!/usr/bin/env bash
# adspace-watchdog: always-on loop that drives kiosk ↔ setup transitions

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

restart_display() {
    # Kill children first so labwc isn't holding GPU resources when it exits
    pkill -x chromium 2>/dev/null || true
    pkill -f start-kiosk.sh 2>/dev/null || true
    pkill -f start-setup-display.sh 2>/dev/null || true
    pkill -x unclutter 2>/dev/null || true
    # Wait for chromium GPU process to fully release DRM/GPU resources
    sleep 5
    # Kill labwc by PID from the service cgroup — handles (labwc) zombie name
    LABWC_PID=$(systemctl show adspace-kiosk.service -p MainPID --value 2>/dev/null || echo "")
    if [ -n "$LABWC_PID" ] && [ "$LABWC_PID" != "0" ]; then
        kill -TERM "$LABWC_PID" 2>/dev/null || kill -KILL "$LABWC_PID" 2>/dev/null || true
    fi
}

enter_kiosk() {
    log "Network up → kiosk mode"
    rm -f "$SETUP_FLAG"
    rm -f "$WIFI_SCAN_CACHE"
    systemctl stop caddy.service || true
    systemctl stop adspace-setup-api.service || true
    nmcli con down adspace-hotspot 2>/dev/null || true
    restart_display
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
    restart_display
}

try_reconnect() {
    # Briefly bring hotspot down to let NM try saved WiFi networks
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
