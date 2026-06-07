# AdSpace RPi — root Makefile
#
# ── Full device setup (new Pi) ─────────────────────────────────────────
#   make flash IP=192.168.1.50 TS_KEY=tskey-auth-xxx
#
# ── Day-to-day deploy (existing Pi) ───────────────────────────────
#   make deploy              — frontend + API to dev Pi
#   make deploy-front        — frontend only
#   make deploy-api          — API binary only
#   make logs                — tail all adspace logs
#   make ssh                 — open shell on dev Pi
#
# Override target Pi:
#   make deploy PI_SSH=adspace@192.168.1.50

PI_SSH    ?= pi@adspace-4d919699
PI_KEY    := ~/.ssh/coding-agent
SSH       := ssh -i $(PI_KEY) $(PI_SSH)
SCP       := scp -i $(PI_KEY)

.PHONY: flash deploy deploy-front deploy-api logs ssh

# ── Full flash (provision + deploy + reboot) ──────────────────────────
flash:
	@[[ -n "$(IP)" ]] || (echo "Usage: make flash IP=<pi-ip> TS_KEY=<tailscale-key>"; exit 1)
	@bash flash.sh "$(IP)" "$(TS_KEY)"

# ── Day-to-day deploy ──────────────────────────────────────────────
deploy: deploy-front deploy-api

deploy-front:
	$(MAKE) -C wifi-setup deploy

deploy-api:
	cd wifi-setup-api && GOOS=linux GOARCH=arm64 go build -o wifi-setup-api .
	$(SSH) "sudo systemctl stop adspace-setup-api.service || true"
	$(SCP) wifi-setup-api/wifi-setup-api $(PI_SSH):/tmp/wifi-setup-api-new
	$(SSH) "sudo mv /tmp/wifi-setup-api-new /opt/adspace/wifi-setup-api \
	     && sudo chmod +x /opt/adspace/wifi-setup-api \
	     && sudo systemctl start adspace-setup-api.service"

logs:
	$(SSH) "sudo journalctl -u adspace-watchdog -u adspace-kiosk -u adspace-setup-api -f"

ssh:
	ssh -i $(PI_KEY) $(PI_SSH)
