import { buildStore, preferences, type TerminalStore } from "./store";
import { tauriBackend } from "./tauriBackend";
import { createXtermEngine } from "./xtermFactory";

let cached: Promise<TerminalStore> | null = null;

export function terminalStore(): Promise<TerminalStore> {
  cached ??= (async () => {
    const [shells, home] = await Promise.all([tauriBackend.shells(), tauriBackend.home()]);
    return buildStore({ backend: tauriBackend, createEngine: createXtermEngine, prefs: preferences, home, shells });
  })().catch((error: unknown) => {
    cached = null;
    throw error;
  });
  return cached;
}
