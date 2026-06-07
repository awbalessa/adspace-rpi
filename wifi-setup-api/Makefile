PI_SSH  := aiagent@rpi5-4gb
PI_KEY  := ~/.ssh/coding-agent
SSH     := ssh -i $(PI_KEY) $(PI_SSH)
SCP     := scp -i $(PI_KEY)
BINARY  := wifi-setup-api

.PHONY: build deploy

build:
	GOOS=linux GOARCH=arm64 go build -o $(BINARY) .

deploy: build
	$(SSH) "sudo systemctl stop adspace-setup-api.service || true"
	$(SCP) $(BINARY) $(PI_SSH):/tmp/wifi-setup-api-new
	$(SSH) "sudo mv /tmp/wifi-setup-api-new /opt/adspace/$(BINARY) \
	     && sudo chmod +x /opt/adspace/$(BINARY) \
	     && sudo systemctl start adspace-setup-api.service"
