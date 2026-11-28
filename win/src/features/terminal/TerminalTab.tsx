import { useEffect, useState } from "react";
import { inTauri } from "../../shell/bridge";
import { TabMessage } from "../../shell/TabCard";
import { terminalStore } from "./liveStore";
import type { TerminalStore } from "./store";
import { TerminalView } from "./TerminalView";

export function TerminalTab() {
  const [store, setStore] = useState<TerminalStore | null>(null);
  const [error, setError] = useState<string | null>(null);

  useEffect(() => {
    if (!inTauri()) {
      setError("O terminal só roda no app do Wisp.");
      return;
    }
    let alive = true;
    terminalStore()
      .then((ready) => {
        ready.workspace.openFirstIfNeeded();
        if (alive) setStore(ready);
      })
      .catch((reason: unknown) => {
        if (alive) setError(`Não abriu o terminal: ${reason instanceof Error ? reason.message : String(reason)}`);
      });
    return () => {
      alive = false;
    };
  }, []);

  if (error) return <TabMessage text={error} />;
  if (!store) return <TabMessage text="Abrindo o terminal…" />;
  return <TerminalView store={store} />;
}
