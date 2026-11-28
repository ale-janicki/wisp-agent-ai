import { useCallback, useState } from "react";
import { DEFAULT_FEATURE, featureById } from "../features/registry";

export const SELECTED_KEY = "wisp.tab";

const RENAMED: Record<string, string> = { memory: "brain", routines: "settings", conversation: "conversa", myMac: "mymac" };

function read(): string {
  try {
    const saved = localStorage.getItem(SELECTED_KEY);
    const id = saved ? (RENAMED[saved] ?? saved) : null;
    return featureById(id) ? id! : DEFAULT_FEATURE;
  } catch {
    return DEFAULT_FEATURE;
  }
}

export function useSelectedFeature(): [string, (id: string) => void] {
  const [selected, setSelected] = useState(read);
  const select = useCallback((id: string) => {
    if (!featureById(id)) return;
    setSelected(id);
    try {
      localStorage.setItem(SELECTED_KEY, id);
    } catch {}
  }, []);
  return [selected, select];
}
