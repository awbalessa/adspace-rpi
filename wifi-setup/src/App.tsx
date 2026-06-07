import "./App.css";
import { PhoneSetupPage } from "./pages/phone-setup-page";
import { TvSetupPage } from "./pages/tv-setup-page";

export default function App() {
  return window.location.pathname === "/tv" ? (
    <TvSetupPage />
  ) : (
    <PhoneSetupPage />
  );
}
