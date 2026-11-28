import { invoke } from "@tauri-apps/api/core";
import type { FeatureBus } from "../../api/featureEvents";
import { inTauri } from "../../shell/bridge";

export async function setRecording(active: boolean): Promise<void> {
  if (inTauri()) await invoke("set_recording", { active });
}

const watched = new WeakSet<FeatureBus>();

export function ensureTrayWatcher(bus: FeatureBus, report: (active: boolean) => void | Promise<void> = setRecording): void {
  if (watched.has(bus)) return;
  watched.add(bus);
  let last = false;
  bus.subscribe("meetings", (event) => {
    if (event.type !== "state") return;
    const phase = (event.state as { phase?: string } | undefined)?.phase;
    const active = phase === "recording";
    if (active === last) return;
    last = active;
    void Promise.resolve(report(active)).catch(() => {});
  });
}
