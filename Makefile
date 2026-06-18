# AdSpace RPi — root Makefile
#
# ── Full device setup (new Pi) ─────────────────────────────────────────
#   make flash IP=192.168.1.50
#
# ── Day-to-day deploy (existing Pi) ───────────────────────────────
#   make deploy PI_SSH=pi@adspace-{serial}              — frontend + API
#   make deploy-front PI_SSH=pi@adspace-{serial}        — frontend only
#   make deploy-api PI_SSH=pi@adspace-{serial}          — API binary only
#   make logs PI_SSH=pi@adspace-{serial}                — tail all logs
#   make ssh PI_SSH=pi@adspace-{serial}                 — open shell

PI_SSH    ?= $(error PI_SSH is required. Usage: make deploy PI_SSH=pi@adspace-{serial})
SSH       := ssh $(PI_SSH)
SCP       := scp

.PHONY: flash deploy deploy-front deploy-api logs ssh

# ── Full flash (provision + deploy + reboot) ──────────────────────────
flash:
	@[[ -n "$(IP)" ]] || (echo "Usage: make flash IP=<pi-ip>"; exit 1)
	@bash flash.sh "$(IP)"

# ── Day-to-day deploy ──────────────────────────────────────────────
deploy: deploy-front deploy-api

deploy-front:
	$(MAKE) -C wifi-setup deploy

deploy-api:
	cd wifi-setup-api && GOOS=linux GOARCH=arm64 go build -o wifi-setup-api .
	$(SSH) "sudo systemctl stop adspace-setup-api.service || true"
	$(SCP) wifi-setup-api/wifi-setup-api $(PI_SSH):/tmp/wifi-setup-api-new
	$(SSH) "sudo mv /tmp/wifi-setup-api-new /opt/adspace/wifi-setup-api \
	     && sudo chown adspace:adspace /opt/adspace/wifi-setup-api \
	     && sudo chmod +x /opt/adspace/wifi-setup-api \
	     && sudo systemctl start adspace-setup-api.service"

logs:
	$(SSH) "sudo journalctl -u adspace-watchdog -u adspace-kiosk -u adspace-setup-api -f"

ssh:
	$(SSH)
