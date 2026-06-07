package main

import (
	"encoding/json"
	"log"
	"net/http"
	"os"
	"os/exec"
	"strings"
	"time"
)

// ── helpers ──────────────────────────────────────────────────────────────────

func run(args ...string) (string, error) {
	out, err := exec.Command(args[0], args[1:]...).Output()
	return strings.TrimSpace(string(out)), err
}

func writeJSON(w http.ResponseWriter, status int, v any) {
	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(status)
	json.NewEncoder(w).Encode(v)
}

// ── GET /api/networks ───────────────────────────────────────────────────────

type Network struct {
	SSID   string `json:"ssid"`
	Signal int    `json:"signal"`
}

const scanCachePath = "/tmp/adspace-wifi-scan.json"

func networksHandler(w http.ResponseWriter, r *http.Request) {
	// Serve the scan cache written by watchdog before hotspot started.
	// wlan0 is in AP mode so live scanning is not possible.
	data, err := os.ReadFile(scanCachePath)
	if err != nil || len(data) == 0 {
		writeJSON(w, http.StatusOK, map[string]any{"networks": []Network{}})
		return
	}

	var networks []Network
	if err := json.Unmarshal(data, &networks); err != nil {
		writeJSON(w, http.StatusOK, map[string]any{"networks": []Network{}})
		return
	}

	writeJSON(w, http.StatusOK, map[string]any{"networks": networks})
}

// ── POST /api/wifi ────────────────────────────────────────────────────────────

type WifiRequest struct {
	SSID     string `json:"ssid"`
	Password string `json:"password"`
}

func wifiHandler(w http.ResponseWriter, r *http.Request) {
	var body WifiRequest
	if err := json.NewDecoder(r.Body).Decode(&body); err != nil || body.SSID == "" {
		writeJSON(w, http.StatusBadRequest, map[string]string{"error": "ssid required"})
		return
	}

	// Hotspot is on wlan0 — must bring it down before we can connect as a client
	exec.Command("sudo", "nmcli", "con", "down", "adspace-hotspot").Run()
	time.Sleep(2 * time.Second)

	// Delete only the existing profile for this specific SSID if it exists
	// (avoids key-mgmt conflicts without wiping other saved networks)
	exec.Command("sudo", "nmcli", "con", "delete", body.SSID).Run()

	args := []string{"sudo", "nmcli", "dev", "wifi", "connect", body.SSID, "ifname", "wlan0"}
	if body.Password != "" {
		args = append(args, "password", body.Password)
	}

	if _, err := run(args...); err != nil {
		// Restore hotspot so the phone can reconnect and try again
		exec.Command("sudo", "nmcli", "con", "up", "adspace-hotspot").Run()
		writeJSON(w, http.StatusBadRequest, map[string]string{"error": "could not connect to network"})
		return
	}

	// Remove setup mode flag — watchdog will detect network is up
	// and handle tearing down hotspot/caddy/api and restarting kiosk
	exec.Command("rm", "-f", "/tmp/adspace-setup-mode").Run()

	writeJSON(w, http.StatusOK, map[string]bool{"ok": true})
}

// ── main ──────────────────────────────────────────────────────────────────────

func main() {
	mux := http.NewServeMux()
	mux.HandleFunc("GET /api/networks", networksHandler)
	mux.HandleFunc("POST /api/wifi", wifiHandler)

	log.Println("Adspace setup API listening on :3000")
	if err := http.ListenAndServe(":3000", mux); err != nil {
		log.Fatal(err)
	}
}
