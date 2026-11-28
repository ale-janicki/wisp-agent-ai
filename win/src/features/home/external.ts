import { useCallback } from "react";
import { useFeatureApi } from "../../shell/context";

export function useOpenExternal(): (url: string) => void {
  const api = useFeatureApi("home");
  return useCallback((url: string) => void api.post("/open", { url }).catch(() => {}), [api]);
}

export async function copyText(text: string): Promise<boolean> {
  try {
    await navigator.clipboard.writeText(text);
    return true;
  } catch {
    const area = document.createElement("textarea");
    area.value = text;
    document.body.appendChild(area);
    area.select();
    const ok = document.execCommand("copy");
    area.remove();
    return ok;
  }
}
