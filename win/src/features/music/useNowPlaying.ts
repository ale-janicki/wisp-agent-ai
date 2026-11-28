import { useCallback, useEffect, useState } from "react";
import { useRichApi } from "../home/richApi";
import type { Now } from "./types";

const POLL_MS = 1000;

export function useNowPlaying() {
  const api = useRichApi("music");
  const [now, setNow] = useState<Now | null>(null);
  const [art, setArt] = useState<{ key: string; url: string | null } | null>(null);
  const key = now?.track?.key;

  const refresh = useCallback(() => api.get<Now>("/now").then(setNow).catch(() => {}), [api]);
  useEffect(() => {
    void refresh();
    const timer = setInterval(() => void refresh(), POLL_MS);
    return () => clearInterval(timer);
  }, [refresh]);

  useEffect(() => {
    if (!key) return;
    let alive = true;
    api
      .get<{ data_url: string | null }>("/artwork", { key })
      .then((r) => alive && setArt({ key, url: r.data_url }))
      .catch(() => {});
    return () => {
      alive = false;
    };
  }, [api, key]);

  const press = useCallback(
    (action: "previous" | "playpause" | "next") => void api.post("/control", { action }).then(refresh).catch(() => {}),
    [api, refresh],
  );
  const artwork = key && art?.key === key ? art.url : null;
  return { now, artwork, press };
}
