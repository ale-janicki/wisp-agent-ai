import { invoke } from "@tauri-apps/api/core";
import { listen } from "@tauri-apps/api/event";

export type ShellMode = "pill" | "panel";

export type SidecarState =
  | { status: "preparing" }
  | { status: "ready"; port: number; token: string }
  | { status: "failed"; message: string };

export const inTauri = (): boolean => typeof window !== "undefined" && "__TAURI_INTERNALS__" in window;

export async function setMode(mode: ShellMode, focus = false): Promise<void> {
  if (inTauri()) await invoke("set_mode", { mode, focus });
}

export async function quit(): Promise<void> {
  if (inTauri()) await invoke("quit_app");
}

export function readSidecar(): Promise<SidecarState> {
  return invoke<SidecarState>("sidecar_info");
}

export async function listenShell(handlers: {
  onSidecar: (s: SidecarState) => void;
  onToggle: () => void;
  onOpen: () => void;
}): Promise<() => void> {
  const offs = await Promise.all([
    listen<SidecarState>("sidecar://state", (e) => handlers.onSidecar(e.payload)),
    listen("shell://toggle", () => handlers.onToggle()),
    listen("shell://open", () => handlers.onOpen()),
  ]);
  return () => offs.forEach((off) => off());
}
