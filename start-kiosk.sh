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
