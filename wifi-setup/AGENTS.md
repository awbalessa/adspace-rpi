# AGENTS.md

## What this project is

`wifi-setup` is the Wi-Fi onboarding web UI for a Raspberry Pi-powered **AdSpace** digital signage device. When a new screen is installed, the Pi boots into hotspot mode and serves this app so a technician can connect the device to the venue's Wi-Fi network.

The app has two distinct views, routed by URL path (no router library — just `window.location.pathname`):

### `/tv` — TV display view
Shown on the screen/TV attached to the Pi. Displays:
- A primary `WIFI:` scheme QR code — scanning it auto-joins the Pi's hotspot and triggers the OS captive portal popup, which opens the setup page automatically
- The hotspot SSID and password in text for manual connection
- A smaller fallback URL QR (`http://192.168.4.1`) for cases where the captive portal doesn't fire automatically

### `/` — Phone setup view
A mobile-friendly form served over the Pi's hotspot at `192.168.4.1`. The technician:
1. Scans the primary QR on the TV → phone joins hotspot → captive portal opens this page automatically
2. Selects the venue Wi-Fi from a dropdown (populated from `GET /api/networks`)
3. Enters the password (show/hide toggle)
4. Submits — POSTs `{ ssid, password }` to `/api/wifi`, which connects the Pi and starts the kiosk

## Tech stack

- **React 19** + **TypeScript**
- **Vite** — dev server and build tool
- **qrcode.react** — QR code generation in the TV view
- **pnpm** — package manager

## Project structure

```
src/
  App.tsx                  # Route: /tv → TvSetupPage, else → PhoneSetupPage
  main.tsx                 # React entry point
  App.css                  # All styles
  index.css                # CSS variables + base reset
  use-setup-config.ts      # Hook: fetches /config.json, falls back to defaults
  pages/
    tv-setup-page.tsx      # TV view — WIFI: QR + credentials + fallback URL QR
    phone-setup-page.tsx   # Phone view — network dropdown, password toggle
public/
  config.json              # Runtime config written by the Pi startup script
  favicon.svg
  icons.svg
```

## Runtime configuration

`public/config.json` is written by `/opt/adspace/startup-router.sh` on the Pi before the setup service starts. **Key names must exactly match the `SetupConfig` TypeScript type.** Required shape:

```json
{
  "hotspotSSID": "AdSpace-TV-XXXXXXXX",
  "hotspotPassword": "XXXXXXXX",
  "setupURL": "http://192.168.4.1"
}
```

If the file is missing or malformed, the app falls back to hardcoded defaults.

## API contract

Both endpoints are provided by the Go API in `../wifi-setup-api`, proxied through Caddy.

```
GET  /api/networks  → { networks: [{ ssid: string, signal: number }] }
POST /api/wifi      → { ssid, password }  →  { ok: true } or 400
```

## Development

```bash
pnpm install
pnpm dev        # Dev server at http://localhost:5173
pnpm build      # Type-check + Vite build → dist/
pnpm preview    # Preview the built output
pnpm lint       # ESLint
```

- TV view: `http://localhost:5173/tv`
- Phone view: `http://localhost:5173/`

The `/api/*` calls will 404 in dev unless you run the Go API locally or add a Vite proxy to `vite.config.ts`. The network dropdown gracefully falls back to a plain text input if the API is unreachable.

## Deployment

Built output goes to `dist/`. The Pi's startup script writes `dist/config.json` and Caddy serves the `dist/` folder. Deploy with:

```bash
pnpm build
scp -r dist/ adspace@rpi5-4gb:/opt/adspace/wifi-setup/dist
```
