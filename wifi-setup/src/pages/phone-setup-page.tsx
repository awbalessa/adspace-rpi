import { useEffect, useState } from "react";

type Network = { ssid: string; signal: number };
type StatusType = "idle" | "connecting" | "success" | "error";

export function PhoneSetupPage() {
  const [networks, setNetworks] = useState<Network[]>([]);
  const [networksLoading, setNetworksLoading] = useState(true);
  const [manualMode, setManualMode] = useState(false);

  const [ssid, setSsid] = useState("");
  const [password, setPassword] = useState("");
  const [showPassword, setShowPassword] = useState(false);
  const [statusType, setStatusType] = useState<StatusType>("idle");
  const [statusMsg, setStatusMsg] = useState("");

  useEffect(() => {
    const controller = new AbortController();
    const timeout = setTimeout(() => controller.abort(), 8000);

    fetch("/api/networks", { signal: controller.signal })
      .then((r) => r.json())
      .then((data) => {
        const nets: Network[] = data.networks ?? [];
        setNetworks(nets);
        if (nets.length > 0) setSsid(nets[0].ssid);
      })
      .catch(() => {
        // timeout or error — fall through to manual input
      })
      .finally(() => {
        clearTimeout(timeout);
        setNetworksLoading(false);
      });
  }, []);

  async function submit(e: React.FormEvent) {
    e.preventDefault();

    if (!ssid.trim()) {
      setStatusType("error");
      setStatusMsg("Wi-Fi name is required.");
      return;
    }

    setStatusType("connecting");
    setStatusMsg("Attempting to connect — this may take a few seconds. Watch the screen.");

    try {
      await fetch("/api/wifi", {
        method: "POST",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify({ ssid, password }),
      });

      // The API returns 200 immediately — it doesn't wait to confirm the
      // connection. The screen switching to kiosk mode is the real confirmation.
      // Keep the "attempting" state so the technician knows to watch the screen.
      // If the connection fails, the hotspot will reappear within ~30 seconds.
      setStatusType("success");
      setStatusMsg("Attempting to connect — watch the screen. If the hotspot reappears, the password was wrong.");
    } catch {
      // Only fires if the request itself failed (hotspot dropped mid-request,
      // API unreachable, etc.) — not if the WiFi password was wrong.
      setStatusType("error");
      setStatusMsg("Request failed — try reconnecting to the hotspot and submitting again.");
    }
  }

  const busy = statusType === "connecting" || statusType === "success";
  const showDropdown = !networksLoading && networks.length > 0 && !manualMode;

  return (
    <main className="page">
      <section className="card">
        <h1>Connect to Wi-Fi</h1>
        <p>Connect this screen to the venue network.</p>

        <form onSubmit={submit}>
          <div className="field">
            <label htmlFor="ssid">Network</label>
            {networksLoading ? (
              <input
                id="ssid"
                value=""
                disabled
                placeholder="Scanning for networks..."
              />
            ) : showDropdown ? (
              <select
                id="ssid"
                value={ssid}
                onChange={(e) => setSsid(e.target.value)}
                disabled={busy}
              >
                {networks.map((n) => (
                  <option key={n.ssid} value={n.ssid}>
                    {n.ssid}
                  </option>
                ))}
              </select>
            ) : (
              <input
                id="ssid"
                value={ssid}
                onChange={(e) => setSsid(e.target.value)}
                placeholder="Network name"
                disabled={busy}
                autoCapitalize="none"
                autoCorrect="off"
                autoComplete="off"
                spellCheck={false}
              />
            )}
            {showDropdown && (
              <button
                type="button"
                className="btn-link"
                onClick={() => { setManualMode(true); setSsid(""); }}
              >
                Different network? Enter manually
              </button>
            )}
            {manualMode && networks.length > 0 && (
              <button
                type="button"
                className="btn-link"
                onClick={() => { setManualMode(false); setSsid(networks[0].ssid); }}
              >
                ← Back to scanned networks
              </button>
            )}
          </div>

          <div className="field">
            <label htmlFor="password">Password</label>
            <div className="password-wrap">
              <input
                id="password"
                type={showPassword ? "text" : "password"}
                value={password}
                onChange={(e) => setPassword(e.target.value)}
                placeholder="Leave blank if open network"
                disabled={busy}
                autoCapitalize="none"
                autoCorrect="off"
                autoComplete="off"
              />
              <button
                type="button"
                className="password-toggle"
                onClick={() => setShowPassword((v) => !v)}
                aria-label={showPassword ? "Hide password" : "Show password"}
              >
                {showPassword ? (
                  <svg width="18" height="18" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2" strokeLinecap="round" strokeLinejoin="round">
                    <path d="M17.94 17.94A10.07 10.07 0 0 1 12 20c-7 0-11-8-11-8a18.45 18.45 0 0 1 5.06-5.94"/>
                    <path d="M9.9 4.24A9.12 9.12 0 0 1 12 4c7 0 11 8 11 8a18.5 18.5 0 0 1-2.16 3.19"/>
                    <line x1="1" y1="1" x2="23" y2="23"/>
                  </svg>
                ) : (
                  <svg width="18" height="18" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2" strokeLinecap="round" strokeLinejoin="round">
                    <path d="M1 12s4-8 11-8 11 8 11 8-4 8-11 8-11-8-11-8z"/>
                    <circle cx="12" cy="12" r="3"/>
                  </svg>
                )}
              </button>
            </div>
          </div>

          <button type="submit" className="btn-primary" disabled={busy || networksLoading}>
            {busy ? "Connecting..." : "Connect screen"}
          </button>
        </form>

        {statusMsg && (
          <p className={`status ${statusType === "error" ? "error" : statusType === "success" ? "success" : ""}`}>
            {statusMsg}
          </p>
        )}
      </section>
    </main>
  );
}
