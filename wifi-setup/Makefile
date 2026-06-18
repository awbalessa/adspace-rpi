PI_SSH  ?= $(error PI_SSH is required. Usage: make deploy PI_SSH=pi@adspace-{serial})
PI_PATH := /opt/adspace/wifi-setup/dist

.PHONY: build deploy

build:
	pnpm build

deploy: build
	# Exclude config.json — the Pi's watchdog writes the real one at runtime
	rsync -av --delete --exclude='config.json' dist/* $(PI_SSH):$(PI_PATH)
