# AGENTS.md — AdSpace RPi Codebase Guide for AI Agents

This file is the authoritative reference for AI coding agents working on this repo.
Read it before making any changes. Follow the constraints — they exist because we hit these bugs.

---

## What this system is

A Raspberry Pi 5 that runs a digital signage kiosk (`https://screen.adspace.so`) when it has WiFi, and displays a setup page + WiFi hotspot when it doesn't. A technician connects their phone to the hotspot, submits WiFi credentials via a web form, and the Pi connects and boots into kiosk mode automatically.

One always-on systemd service (`adspace-watchdog`) drives all state transitions. Everything else is started or stopped by the watchdog.

---

## SSH access

```
Host: rpi5-4gb  (or IP directly)
User: aiagent
Key:  ~/.ssh/coding-agent

Shortcut (add to ~/.ssh/config):
  Host rpi-ai
      HostName rpi5-4gb
      User aiagent
      IdentityFile ~/.ssh/coding-agent
```

The `aiagent` user has scoped sudo (defined in `/etc/sudoers.d/aiagent`). You can:
- `sudo systemctl start/stop/restart/status adspace-*`
- `sudo journalctl`
- `sudo nmcli`
- `sudo mv /tmp/wifi-setup-api-new /opt/adspace/wifi-setup-api`
- `sudo chmod +x /opt/adspace/wifi-setup-api`
- `sudo tee /opt/adspace/watchdog.sh` (and other scripts)
- `sudo systemctl daemon-reload`

You cannot: install packages, modify systemd units, or edit files outside `/opt/adspace/` (use `adspace` user or ask a human for those operations).

---

## Deploying changes

### Frontend (React)
```bash
cd wifi-setup && make deploy
# Runs: pnpm build → rsync dist/ to adspace@rpi5-4gb:/opt/adspace/wifi-setup/dist
# IMPORTANT: rsync uses --delete (removes old bundles) and --exclude='config.json'
```

### Go API binary
```bash
# From repo root:
make deploy-api

# Or manually:
cd wifi-setup-api
GOOS=linux GOARCH=arm64 go build -o wifi-setup-api .
scp -i ~/.ssh/coding-agent wifi-setup-api aiagent@rpi5-4gb:/tmp/wifi-setup-api-new
ssh rpi-ai "sudo mv /tmp/wifi-setup-api-new /opt/adspace/wifi-setup-api \
         && sudo chmod +x /opt/adspace/wifi-setup-api \
         && sudo systemctl restart adspace-setup-api.service"
```

> **Never** use `adspace@rpi5-4gb` for deployment — that user requires password sudo.
> Always use `aiagent@rpi5-4gb` with the SSH key.

### Watchdog / shell scripts
Edit locally, then push to Pi:
```bash
ssh rpi-ai "sudo tee /opt/adspace/watchdog.sh" < watchdog.sh
ssh rpi-ai "sudo chmod +x /opt/adspace/watchdog.sh && sudo systemctl restart adspace-watchdog"
```

---

## Critical constraints — read before changing anything

### 1. `config.json` is NEVER deployed
`/opt/adspace/wifi-setup/dist/config.json` is written at runtime by `watchdog.sh`.
- `wifi-setup/public/config.json` is local dev only (fallback values)
- `rsync` in `wifi-setup/Makefile` uses `--exclude='config.json'`
- `.gitignore` excludes both paths
- **Do not add config.json to deploys, commits, or rsync commands**

### 2. wlan0 cannot AP and client simultaneously
When the hotspot is up, `wlan0` is in AP mode. You cannot:
- Run `nmcli dev wifi rescan` (hangs)
- Run `nmcli dev wifi list` (returns empty)
- Auto-connect to saved WiFi

The watchdog scans *before* starting the hotspot and saves to `/tmp/adspace-wifi-scan.json`.
The API reads from that file — it never scans live.

To attempt reconnection: bring hotspot down, wait 20s, check `nmcli con show --active`.

### 3. Always delete the SSID profile before re-connecting
`nmcli dev wifi connect` fails with `key-mgmt: property is missing` if a stale profile for that SSID exists. The API does:
```go
exec.Command("sudo", "nmcli", "con", "delete", body.SSID).Run()
```
before connecting. Do not remove this.

### 4. Hotspot must come down before WiFi connect
```go
exec.Command("sudo", "nmcli", "con", "down", "adspace-hotspot").Run()
time.Sleep(2 * time.Second)
```
This is required — wlan0 can't be AP and client at the same time. API restores hotspot if connect fails.

### 5. Use CPU serial, not machine-id, for SSID
`/etc/machine-id` is cloned identically when SD cards are copied for new Pis.
CPU serial is hardware-burned and unique per board:
```bash
grep Serial /proc/cpuinfo | awk '{print $3}' | tail -c 9
```
The watchdog uses this for `Adspace-TV-{cpu_serial}`.

### 6. Separate Chromium profiles
- Kiosk: `--user-data-dir=/home/adspace/.config/adspace-chromium`
- Setup: `--user-data-dir=/home/adspace/.config/adspace-setup-chromium --disk-cache-size=1`

Never merge these. Stale kiosk bundles bled into setup mode — this was a real bug.

### 7. Old JS bundles accumulate and break things
`rsync --delete` in `wifi-setup/Makefile` ensures stale bundles are removed on every deploy.
Do not remove the `--delete` flag.

### 8. adspace-kiosk.service has Restart=always but is boot-disabled
The watchdog calls `systemctl restart adspace-kiosk` explicitly.
If `adspace-kiosk` is enabled at boot AND `Restart=always`, it starts itself before watchdog is ready, causing race conditions. It's enabled (unit exists) but boot-disabled (not in WantedBy targets).

---

## File locations on Pi

| Path | Purpose |
|------|---------|
| `/opt/adspace/watchdog.sh` | Main control loop — do not edit in place, push from repo |
| `/opt/adspace/start-kiosk.sh` | Launched by labwc autostart in kiosk mode |
| `/opt/adspace/start-setup-display.sh` | Launched by labwc autostart in setup mode |
| `/opt/adspace/kiosk.env` | `ADSPACE_URL` and `ADSPACE_BROWSER` env vars |
| `/opt/adspace/wifi-setup-api` | Compiled Go binary, served on :3000 |
| `/opt/adspace/wifi-setup/dist/` | Built React app, served by Caddy on :80 |
| `/opt/adspace/wifi-setup/dist/config.json` | Runtime-written by watchdog — never deploy |
| `/home/adspace/.config/labwc/autostart` | Branches on setup flag, launches correct Chromium |
| `/etc/caddy/Caddyfile` | Serves :80, proxies /api/*, captive portal redirects |
| `/etc/systemd/system/adspace-watchdog.service` | Starts on boot |
| `/etc/systemd/system/adspace-kiosk.service` | labwc session on tty1, boot-disabled |
| `/etc/systemd/system/adspace-setup-api.service` | Go API, started by watchdog only |
| `/tmp/adspace-setup-mode` | Flag: exists = setup mode, absent = kiosk mode |
| `/tmp/adspace-wifi-scan.json` | WiFi scan cache from before hotspot started |

---

## State machine

```
          ┌──────────────┐
          │   WATCHDOG   │  polls every 15s
          └──────┬───────┘
                 │
    ┌────────────▼────────────┐
    │     is_connected()?     │
    └────┬──────────────┬─────┘
         │ YES          │ NO
         ▼              ▼
   enter_kiosk()   enter_setup()
   ─────────────   ─────────────
   stop caddy      scan_networks()
   stop api        update hotspot SSID
   down hotspot    write config.json
   restart kiosk   touch setup flag
                   up hotspot
                   start api + caddy
                   restart kiosk

   In setup mode, every ~60s:
   try_reconnect() → down hotspot → wait 20s → check connection
                  → if connected: enter_kiosk()
                  → if not: restore hotspot
```

---

## Service dependency map

```
systemd boot
    └── adspace-watchdog.service (starts on boot)
            ├── adspace-kiosk.service   (watchdog: systemctl restart)
            ├── adspace-setup-api.service (watchdog: systemctl start/stop)
            └── caddy.service           (watchdog: systemctl start/stop)

adspace-kiosk.service
    └── labwc (Wayland compositor)
            └── /home/adspace/.config/labwc/autostart
                    ├── [setup mode]  → start-setup-display.sh → chromium → http://localhost/tv
                    └── [kiosk mode]  → start-kiosk.sh         → chromium → https://screen.adspace.so
```

---

## API reference

Both endpoints are served by the Go binary on `:3000`, proxied through Caddy on `:80`.

### `GET /api/networks`
Returns cached WiFi scan from before hotspot started.
```json
{ "networks": [{ "ssid": "Office WiFi", "signal": 85 }, ...] }
```
Returns `{ "networks": [] }` if no cache exists.

### `POST /api/wifi`
Connect to a WiFi network. Tears down hotspot first.
```json
// Request
{ "ssid": "Office WiFi", "password": "hunter2" }

// Success (200)
{ "ok": true }

// Error (400)
{ "error": "could not connect to network" }
```
On success: watchdog detects network within 15s → enters kiosk mode.
On error: hotspot is restored so phone can retry.

---

## Debugging workflows

### Check current mode
```bash
ssh rpi-ai "[ -f /tmp/adspace-setup-mode ] && echo SETUP || echo KIOSK"
```

### Watch everything live
```bash
make logs
# or:
ssh rpi-ai "sudo journalctl -u adspace-watchdog -u adspace-kiosk -u adspace-setup-api -f"
```

### Force into setup mode (for testing)
```bash
ssh rpi-ai "sudo nmcli con delete 'NetworkName' && sudo systemctl restart adspace-watchdog"
```

### Force into kiosk mode
```bash
ssh rpi-ai "sudo rm -f /tmp/adspace-setup-mode && sudo systemctl restart adspace-watchdog"
```

### Check WiFi scan cache
```bash
ssh rpi-ai "cat /tmp/adspace-wifi-scan.json"
```

### Check what nmcli knows
```bash
ssh rpi-ai "sudo nmcli con show"
ssh rpi-ai "sudo nmcli con show --active"
```

### Check Caddy is serving correctly
```bash
# From a device on the hotspot (192.168.4.x):
curl http://192.168.4.1/config.json
curl http://192.168.4.1/api/networks
```

### Chromium won't start / blank screen
```bash
ssh rpi-ai "sudo journalctl -u adspace-kiosk --no-pager -n 50"
# If crash-looping: GPU not ready yet, check RestartSec and ExecStartPre in kiosk service
# Check GPU device:
ssh rpi-ai "ls /dev/dri/"
```

### API not running
```bash
ssh rpi-ai "sudo systemctl status adspace-setup-api"
ssh rpi-ai "ss -tlnp | grep 3000"
```

---

## Common mistakes to avoid

| Mistake | Why it breaks |
|---------|--------------|
| Deploying `config.json` | Pi's runtime SSID gets overwritten with dev defaults |
| Using `adspace@` for deploy SCP | That user needs password sudo, SCP fails |
| Removing `--delete` from rsync | Old JS bundles accumulate, Chromium loads wrong one |
| Scanning WiFi while hotspot is up | `nmcli rescan` hangs indefinitely |
| Not deleting SSID profile before connect | `key-mgmt: property is missing` error |
| Using `/etc/machine-id` for SSID | All cloned Pis get identical SSIDs |
| Merging Chromium profiles | Stale kiosk cache appears in setup page |
| Enabling adspace-kiosk at boot | Starts before watchdog, race condition, wrong mode |
