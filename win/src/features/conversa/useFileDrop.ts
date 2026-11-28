import { useEffect, useState } from "react";

const inTauri = () => typeof window !== "undefined" && "__TAURI_INTERNALS__" in window;

export function useFileDrop(onPaths: (paths: string[]) => void, enabled: boolean): boolean {
  const [dropping, setDropping] = useState(false);

  useEffect(() => {
    if (!enabled || !inTauri()) return;
    let dead = false;
    let off: (() => void) | undefined;
    void import("@tauri-apps/api/webview")
      .then(({ getCurrentWebview }) =>
        getCurrentWebview().onDragDropEvent((event) => {
          const payload = event.payload;
          if (payload.type === "enter" || payload.type === "over") setDropping(true);
          else if (payload.type === "leave") setDropping(false);
          else if (payload.type === "drop") {
            setDropping(false);
            if (payload.paths.length > 0) onPaths(payload.paths);
          }
        }),
      )
      .then((unlisten) => (dead ? unlisten() : (off = unlisten)))
      .catch(() => undefined);
    return () => {
      dead = true;
      off?.();
    };
  }, [enabled, onPaths]);

  return dropping;
}
