import { describe, expect, it, vi } from "vitest";
import { createFeatureBus } from "../../api/featureEvents";
import { ensureTrayWatcher, setRecording } from "./tray";
import type { MeetingsState } from "./types";

const state = (phase: MeetingsState["phase"]) => ({ feature: "meetings", type: "state", state: { phase } });

describe("tray recording indicator", () => {
  it("tells the shell when a recording starts and when it ends, once per change", () => {
    const bus = createFeatureBus();
    const report = vi.fn();
    ensureTrayWatcher(bus, report);
    bus.emit(state("idle"));
    bus.emit(state("starting"));
    bus.emit(state("recording"));
    bus.emit(state("recording"));
    bus.emit(state("finishing"));
    bus.emit(state("idle"));
    expect(report.mock.calls.map((c) => c[0])).toEqual([true, false]);
  });

  it("keeps watching after the tab is gone and never registers twice on one bus", () => {
    const bus = createFeatureBus();
    const report = vi.fn();
    ensureTrayWatcher(bus, report);
    ensureTrayWatcher(bus, report);
    bus.emit(state("recording"));
    expect(report).toHaveBeenCalledTimes(1);
  });

  it("is a no-op outside the Tauri shell", async () => {
    await expect(setRecording(true)).resolves.toBeUndefined();
  });
});
