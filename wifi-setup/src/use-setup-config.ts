import { useEffect, useState } from "react";

export type SetupConfig = {
  hotspotSSID: string;
  hotspotPassword: string;
  setupURL: string;
};

const fallbackConfig: SetupConfig = {
  hotspotSSID: "Adspace-TV-12345678",
  hotspotPassword: "12345678",
  setupURL: "http://192.168.4.1",
};

export function useSetupConfig() {
  const [config, setConfig] = useState<SetupConfig>(fallbackConfig);

  useEffect(() => {
    fetch("/config.json", { cache: "no-store" })
      .then((res) => {
        if (!res.ok) throw new Error("missing config");
        return res.json();
      })
      .then(setConfig)
      .catch(() => setConfig(fallbackConfig));
  }, []);

  return config;
}
