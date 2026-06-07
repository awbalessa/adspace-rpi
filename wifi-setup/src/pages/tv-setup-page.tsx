import { QRCodeCanvas } from "qrcode.react";
import { useSetupConfig } from "../use-setup-config";

export function TvSetupPage() {
  const config = useSetupConfig();

  const wifiQR = `WIFI:T:WPA;S:${config.hotspotSSID};P:${config.hotspotPassword};;`;

  return (
    <main className="tv-page">
      <img src="/Logo.svg" alt="Adspace" className="tv-logo" />
      <div className="tv-header">
        <p className="tv-step">Setup required</p>
        <h1>Connect your phone to set up this screen</h1>
        <p className="tv-subtitle">
          Scan the QR code with your phone camera — the setup page will open
          automatically.
        </p>
      </div>

      <div className="tv-grid">
        {/* Primary: scan to join hotspot */}
        <div className="tv-card tv-card-primary">
          <p className="tv-card-step">Step 1</p>
          <p className="tv-card-label">Scan with your phone camera</p>
          <div className="tv-qr-wrap">
            <QRCodeCanvas value={wifiQR} size={260} marginSize={2} />
          </div>
          <p className="tv-card-hint">
            Joins the network and opens setup automatically
          </p>
        </div>

        {/* Manual fallback */}
        <div className="tv-card">
          <p className="tv-card-step">Or connect manually</p>
          <p className="tv-card-label">Join this Wi-Fi network</p>

          <div className="tv-credential">
            <span className="tv-credential-label">Network</span>
            <span className="tv-credential-value">{config.hotspotSSID}</span>
          </div>

          <div className="tv-credential">
            <span className="tv-credential-label">Password</span>
            <span className="tv-credential-value">{config.hotspotPassword}</span>
          </div>

          <div className="tv-divider" />

          <p className="tv-card-label" style={{ marginBottom: 16 }}>
            Then open this on your phone
          </p>
          <div className="tv-fallback-row">
            <QRCodeCanvas value={config.setupURL} size={100} marginSize={1} />
            <span className="tv-credential-value">{config.setupURL}</span>
          </div>
        </div>
      </div>
    </main>
  );
}
