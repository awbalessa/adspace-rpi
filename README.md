# AdSpace RPi — Digital Signage OS

This repo contains everything needed to turn a **Raspberry Pi 5** into an AdSpace digital signage device — from first boot to a fully self-managing kiosk that handles WiFi setup, network loss recovery, and remote management.

---

## Table of Contents

1. [How it works](#how-it-works)
2. [Repository layout](#repository-layout)
3. [Pi file layout](#pi-file-layout)
4. [Quick start — provisioning a new Pi](#quick-start--provisioning-a-new-pi)
5. [Day-to-day development](#day-to-day-development)
6. [Connecting to the Pi](#connecting-to-the-pi)
7. [Debugging](#debugging)
8. [Golden image (fleet provisioning)](#golden-image-fleet-provisioning)
9. [Architecture decisions](#architecture-decisions)

---

## How it works

### Normal boot (WiFi already configured)
```
Boot → adspace-watchdog starts
     → detects network (ethernet or WiFi)
     → calls enter_kiosk()
     → starts adspace-kiosk (labwc → Chromium → https://screen.adspace.so)
```

### First boot / no network
```
Boot → adspace-watchdog starts
     → no network detected
     → scans for nearby WiFi networks (before hotspot starts)
     → brings up adspace-hotspot (AP on wlan0, SSID = Adspace-TV-{cpu_serial})
     → starts Caddy + setup API
     → starts adspace-kiosk (labwc → Chromium → http://localhost/tv)
     → TV shows QR code + hotspot credentials

Technician connects phone to Adspace-TV-xxxxxxxx
     → opens http://192.168.4.1
     → sees WiFi setup page with scanned networks (or manual input)
     → submits credentials

API receives credentials
     → brings down hotspot
     → connects wlan0 to the submitted network
     → watchdog detects network up within 15s
     → calls enter_kiosk() → TV switches to kiosk URL
```

### Network loss recovery
```
WiFi drops → watchdog detects no network → enter_setup()
Every ~60s in setup mode → try_reconnect():
     → brings hotspot down for 20s
     → NetworkManager attempts saved WiFi profiles
     → if connected: enter_kiosk()
     → if not: restore hotspot, keep showing setup screen
```

---

## Repository layout

```
rpi/
├── provision.sh              # Run once on fresh Pi — installs everything
├── watchdog.sh               # Source copy of /opt/adspace/watchdog.sh
├── start-kiosk.sh            # Source copy of /opt/adspace/start-kiosk.sh
├── start-setup-display.sh    # Source copy of /opt/adspace/start-setup-display.sh
├── kiosk.env                 # Source copy of /opt/adspace/kiosk.env
├── Makefile                  # Root: deploy, logs, ssh targets
│
├── wifi-setup/               # React frontend (TV page + phone setup page)
│   ├── src/
│   │   ├── App.tsx           # Router: /tv → TvSetupPage, / → PhoneSetupPage
│   │   ├── pages/
│   │   │   ├── tv-setup-page.tsx      # TV display: QR code + hotspot creds
│   │   │   └── phone-setup-page.tsx   # Phone: network dropdown + manual input
│   │   └── use-setup-config.ts        # Fetches /config.json (written by watchdog)
│   ├── public/
│   │   ├── config.json       # LOCAL DEV ONLY — never deployed (rsync excludes it)
│   │   └── Logo.svg
│   └── Makefile              # pnpm build + rsync to Pi
│
└── wifi-setup-api/           # Go HTTP API (runs on Pi :3000)
    ├── main.go               # GET /api/networks, POST /api/wifi
    └── Makefile              # Cross-compile arm64 + deploy
```

---

## Pi file layout

```
/opt/adspace/
├── watchdog.sh               # Main control loop (run by systemd as root)
├── start-kiosk.sh            # Launches Chromium in kiosk mode → screen.adspace.so
├── start-setup-display.sh    # Launches Chromium in kiosk mode → localhost/tv
├── kiosk.env                 # ADSPACE_URL and ADSPACE_BROWSER vars
├── wifi-setup-api            # Compiled Go binary (serves :3000)
└── wifi-setup/
    └── dist/                 # Built React app (served by Caddy on :80)
        ├── index.html
        ├── assets/
        └── config.json       # Written at runtime by watchdog — NOT in git

/home/adspace/.config/labwc/
└── autostart                 # Branches on /tmp/adspace-setup-mode flag

/etc/caddy/Caddyfile          # Serves :80, proxies /api/* to :3000, captive portal
/etc/systemd/system/
├── adspace-watchdog.service  # Starts on boot, controls everything else
├── adspace-kiosk.service     # labwc Wayland session on tty1
└── adspace-setup-api.service # Go API, started by watchdog only

/tmp/adspace-setup-mode       # Flag file — exists = setup mode, absent = kiosk
/tmp/adspace-wifi-scan.json   # WiFi scan cache (written before hotspot starts)
```

---

## Quick start — provisioning a new Pi

### Requirements
- Raspberry Pi 5 (4GB or 8GB)
- SD card flashed with **RPi OS Lite 64-bit** (Debian Trixie/Bookworm)
- SSH enabled on the Pi (add empty `/boot/ssh` file, or use Raspberry Pi Imager)
- Pi connected to internet via ethernet for initial setup
- Mac with Go installed (`brew install go`) and pnpm (`brew install pnpm`)

### Step 1 — Get a Tailscale auth key
Go to [tailscale.com/admin/settings/keys](https://login.tailscale.com/admin/settings/keys) → Generate auth key.
- ✅ Reusable (so you can use the same key for every Pi)
- ✅ Ephemeral: No (devices should persist)
- Tag: `adspace-pi` (optional but useful for filtering)

### Step 2 — Run provision script
```bash
# From this repo on your Mac — pass the Tailscale key as an env var:
TAILSCALE_AUTH_KEY=tskey-auth-xxx \
  ssh pi@<pi-ip-address> "sudo --preserve-env=TAILSCALE_AUTH_KEY bash -s" < provision.sh
```

This is fully idempotent — safe to re-run. If you omit the key, Tailscale is installed but not authenticated (you can auth manually later with `sudo tailscale up --auth-key=...`).

### Step 3 — Add your SSH key to aiagent
```bash
# Copy your key so you can SSH as aiagent going forward
ssh-copy-id -i ~/.ssh/your-key aiagent@<pi-ip-address>
```

### Step 4 — Deploy the app
```bash
# Build + deploy frontend and API binary
make deploy
```

### Step 5 — Reboot and verify
```bash
ssh aiagent@<pi-ip-address> sudo reboot
```

On reboot:
- **With ethernet**: Pi boots straight into kiosk → `screen.adspace.so`
- **Without ethernet**: Pi boots into setup screen, hotspot `Adspace-TV-{serial}` appears

---

## Day-to-day development

### Deploy everything
```bash
make deploy
```

### Deploy frontend only
```bash
make deploy-front
# or: cd wifi-setup && make deploy
```

### Deploy API only
```bash
make deploy-api
```

### Tail live logs
```bash
make logs
```

### Open SSH session
```bash
make ssh
```

### Local frontend dev
```bash
cd wifi-setup
pnpm dev
# Opens http://localhost:5173
# / → phone setup page
# /tv → TV display page
# Uses wifi-setup/public/config.json for local config (not deployed to Pi)
```

---

## Connecting to the Pi

### SSH
```bash
# Via hostname (requires Pi on Tailscale or same network)
ssh -i ~/.ssh/coding-agent aiagent@rpi5-4gb

# Via IP
ssh -i ~/.ssh/coding-agent aiagent@<ip>

# Shortcut alias (add to ~/.ssh/config):
Host rpi-ai
    HostName rpi5-4gb
    User aiagent
    IdentityFile ~/.ssh/coding-agent
```

Then: `ssh rpi-ai`

### Tailscale (remote access)
The Pi is enrolled in Tailscale as `rpi5-4gb`. Once on the Tailscale network you can SSH from anywhere:
```bash
ssh aiagent@rpi5-4gb
```

### Hotspot (setup mode)
When the Pi has no network:
- **SSID**: `Adspace-TV-{first 8 chars of CPU serial}`
- **Password**: same as SSID suffix
- **Setup page**: http://192.168.4.1 (opens automatically on most phones as captive portal)
- **TV page**: http://192.168.4.1/tv

---

## Debugging

### Check system state
```bash
# What mode is the Pi in right now?
ssh rpi-ai "[ -f /tmp/adspace-setup-mode ] && echo SETUP || echo KIOSK"

# What's connected?
ssh rpi-ai "nmcli con show --active"

# Watchdog live log
ssh rpi-ai "sudo journalctl -u adspace-watchdog -f"

# Kiosk service log
ssh rpi-ai "sudo journalctl -u adspace-kiosk -f"

# API log
ssh rpi-ai "sudo journalctl -u adspace-setup-api -f"

# All adspace logs together
make logs
```

### Force setup mode (for testing)
```bash
ssh rpi-ai "sudo nmcli con delete 'YourNetwork' && sudo systemctl restart adspace-watchdog"
```

### Force kiosk mode
```bash
ssh rpi-ai "sudo rm -f /tmp/adspace-setup-mode && sudo systemctl restart adspace-watchdog"
```

### Restart everything cleanly
```bash
ssh rpi-ai "sudo systemctl restart adspace-watchdog"
```

### Check what's on disk vs what's deployed
```bash
ssh rpi-ai "ls -la /opt/adspace/wifi-setup/dist/assets/"
```

### API not responding
```bash
ssh rpi-ai "sudo systemctl status adspace-setup-api"
# Check if caddy is running
ssh rpi-ai "sudo systemctl status caddy"
# Check port 3000
ssh rpi-ai "ss -tlnp | grep 3000"
```

### Chromium caching stale files
Both Chromium profiles use `--disk-cache-size=1` (setup) or are wiped manually (kiosk).
To wipe kiosk profile:
```bash
ssh rpi-ai "sudo rm -rf /home/adspace/.config/adspace-chromium"
```

---

## Testing provision.sh (without reflashing)

Before cutting a golden image, test the full provision on your dev Pi by deprovisioning and reprovisioning in place. Faster than reflashing, catches all the same issues.

```bash
# Step 1 — Wipe all adspace config (simulates a fresh Pi)
ssh pi@<ip> "sudo bash -s" < deprovision.sh

# Step 2 — Reprovision from scratch
ssh pi@<ip> "sudo bash -s" < provision.sh

# Step 3 — Deploy the app
make deploy

# Step 4 — Reboot and verify
ssh aiagent@<ip> sudo reboot
```

**What to verify after reboot:**
- [ ] With ethernet plugged in: TV shows `screen.adspace.so` within 30s
- [ ] Ethernet unplugged + no saved WiFi: setup screen appears, hotspot `Adspace-TV-{serial}` visible
- [ ] Phone connects to hotspot → opens `http://192.168.4.1` → WiFi form with network dropdown
- [ ] Submit valid WiFi creds → TV transitions to kiosk within 15s
- [ ] Unplug ethernet, saved WiFi in range: Pi auto-reconnects within 60s
- [ ] `make logs` shows clean watchdog transitions

---

## Pi naming

Each Pi gets a hostname based on its CPU serial number during provisioning:
```
adspace-{8-char cpu serial}    e.g. adspace-4d919699
```

This is **hardware-burned and unique per board** — safe for SD card cloning (unlike `/etc/machine-id` which gets cloned identically).

Once a Pi is installed at a venue, rename it:
```bash
ssh aiagent@adspace-4d919699 "sudo bash -s" < rename-device.sh adspace-dubai-mall-01
```

After rename + reboot, SSH via Tailscale from anywhere:
```bash
ssh aiagent@adspace-dubai-mall-01
```

**Naming convention:**
```
adspace-{city/venue}-{2-digit index}
adspace-dubai-mall-01
adspace-riyadh-airport-01
adspace-cairo-downtown-02
```

---

## Golden image (fleet provisioning)

Once a Pi is provisioned and verified, clone its SD card to flash all future Pis instantly.

### Clone SD card to image (on the Pi itself)
```bash
# Find the SD card device
ssh rpi-ai "lsblk"

# Clone (run on a Mac/Linux machine with the SD card inserted, or via Pi)
sudo dd if=/dev/mmcblk0 of=adspace-golden.img bs=4M status=progress conv=fsync
```

### Shrink the image (optional, saves space)
```bash
# Install pishrink on your Mac/Linux
curl -sL https://raw.githubusercontent.com/Drewsif/PiShrink/master/pishrink.sh | sudo bash -s adspace-golden.img
```

### Flash to a new SD card
Use **Balena Etcher** (GUI) or:
```bash
sudo dd if=adspace-golden.img of=/dev/sdX bs=4M status=progress conv=fsync
```

### Important: machine-id after cloning
The watchdog uses **CPU serial** (hardware-burned, unique per Pi) for the hotspot SSID — not `/etc/machine-id`. This means cloned images automatically get unique SSIDs. No post-flash configuration needed.

---

## Architecture decisions

### Single watchdog, not many services
One `adspace-watchdog.service` (polling loop) controls all transitions. Simpler than a web of oneshot services with `After=`/`Wants=` dependencies that are hard to reason about.

### labwc as Wayland compositor
RPi5 uses the Pi GPU driver which works best with Wayland. labwc is lightweight, stable, and starts Chromium via its `autostart` file. The autostart script branches on `/tmp/adspace-setup-mode` to decide which Chromium to launch.

### Separate Chromium profiles
- Kiosk: `adspace-chromium` — persists cache between sessions
- Setup: `adspace-setup-chromium` with `--disk-cache-size=1` — never caches, always shows fresh build

This prevents a stale kiosk JS bundle from bleeding into the setup page (a real bug we hit).

### WiFi scan before hotspot starts
`wlan0` can't be AP and WiFi client simultaneously. The watchdog scans and caches results to `/tmp/adspace-wifi-scan.json` *before* bringing up the hotspot. The API serves from this cache instantly.

### CPU serial for SSID uniqueness
`/etc/machine-id` is identical on all Pi clones. CPU serial (`/proc/cpuinfo`) is hardware-burned and unique per board — safe to use even after SD card cloning.

### Hotspot-down reconnect loop
Every ~60s in setup mode, the watchdog briefly brings down the hotspot to let NetworkManager reconnect to any previously saved WiFi. Handles the case where a known network comes back in range after setup mode was entered.

### config.json never deployed
The Pi writes `/opt/adspace/wifi-setup/dist/config.json` at runtime (hotspot SSID, password, URL). The repo's `public/config.json` is local-dev only. rsync uses `--exclude='config.json'` and `.gitignore` excludes it.
