PI_HOST := adspace@rpi5-4gb
PI_PATH := /opt/adspace/wifi-setup/dist

.PHONY: build deploy

build:
	pnpm build

deploy: build
	# Exclude config.json — the Pi's startup script writes the real one at runtime
	rsync -av --delete --exclude='config.json' dist/* $(PI_HOST):$(PI_PATH)
