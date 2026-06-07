# AdSpace RPi — root Makefile
# Builds and deploys both the frontend and Go API to the Pi.
#
# Targets:
#   make deploy              — build + deploy everything
#   make deploy-front        — frontend only
#   make deploy-api          — Go API only
#   make logs                — tail watchdog + kiosk logs on Pi
#   make ssh                 — open SSH session to Pi
#
# Override target Pi (e.g. for a new device):
#   make deploy PI_SSH=adspace@192.168.1.50

PI_SSH    ?= adspace@rpi5-4gb
PI_KEY    := ~/.ssh/coding-agent
SSH       := ssh -i $(PI_KEY) $(PI_SSH)
SCP       := scp -i $(PI_KEY)

.PHONY: deploy deploy-front deploy-api logs ssh

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
