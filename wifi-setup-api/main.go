package main

import (
	"context"
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

func runTimeout(timeout time.Duration, args ...string) (string, error) {
	ctx, cancel := context.WithTimeout(context.Background(), timeout)
	defer cancel()
	out, err := exec.CommandContext(ctx, args[0], args[1:]...).Output()
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

	// Respond immediately before dropping the hotspot.
	// The phone loses its connection to the Pi when the hotspot goes down,
	// so any response sent after that point is never received.
	// We return ok=true optimistically; if the connect fails, the watchdog
	// will restore setup mode within 15s.
	writeJSON(w, http.StatusOK, map[string]bool{"ok": true})

	// Flush response to the phone before we tear down the hotspot
	if f, ok := w.(http.Flusher); ok {
		f.Flush()
	}
	// Small delay to ensure the response is actually transmitted
	time.Sleep(500 * time.Millisecond)

	// Run the WiFi connect in a goroutine — HTTP handler returns immediately
	go func() {
		log.Printf("Connecting to WiFi SSID: %q", body.SSID)

		// Bring hotspot down — wlan0 can't be AP and client simultaneously
		exec.Command("sudo", "nmcli", "con", "down", "adspace-hotspot").Run()
		time.Sleep(2 * time.Second)

		// Delete stale profile for this SSID to avoid key-mgmt conflicts
		exec.Command("sudo", "nmcli", "con", "delete", body.SSID).Run()

		args := []string{"sudo", "nmcli", "dev", "wifi", "connect", body.SSID, "ifname", "wlan0"}
		if body.Password != "" {
			args = append(args, "password", body.Password)
		}

		if _, err := runTimeout(30*time.Second, args...); err != nil {
			log.Printf("WiFi connect failed for %q: %v — restoring hotspot", body.SSID, err)
			exec.Command("sudo", "nmcli", "con", "up", "adspace-hotspot").Run()
			return
		}

		log.Printf("WiFi connect succeeded for %q — watchdog will enter kiosk mode", body.SSID)
		// Remove setup mode flag — watchdog detects network is up within 15s
		// and handles teardown of hotspot/caddy/api and kiosk restart
		exec.Command("rm", "-f", "/tmp/adspace-setup-mode").Run()
	}()
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
