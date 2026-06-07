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
