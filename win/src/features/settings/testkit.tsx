import { render } from "@testing-library/react";
import type { ReactNode } from "react";
import { createFeatureBus } from "../../api/featureEvents";
import { ShellContext } from "../../shell/context";
import { fakeFetch } from "../../test/fakes";
import type { DoctorCheck, SettingsState } from "./types";

export const info = { port: 4242, token: "tok" };

export const baseState = (over: Partial<SettingsState> = {}): SettingsState => ({
  version: "0.1.0",
  platform: "win32",
  engine: "claude",
  permission: { choice: "default", source: "standard", claude_mode: null, profile_is_link: false },
  paths: { wisp_dir: "~/Wisp", has_wisp_dir: false, brain: "C:/Users/x/Wisp/brain", brain_default: "~/Wisp/brain", brain_missing: false, brain_learn: true },
  profile: { name: "Wisp", user: "Bia", avatar: null },
  notices: { doNotDisturb: false, reply: true, telegram: true, reminder: true, update: true, approval: true, meeting: true, invite: true },
  blocks: { routines: true, hooks: true, commands: true },
  setup_finished: true,
  ...over,
});

export const check = (id: string, ok: boolean, over: Partial<DoctorCheck> = {}): DoctorCheck => ({ id, ok, summary: ok ? `${id} ok` : `${id} falta`, step: null, data: {}, ...over });

export const report = (step: string, status: "done" | "skipped" | "needs_user" | "failed" = "done", summary = "feito", over: object = {}) => ({
  step, status, summary, details: [{ command: `wisp setup ${step} --json`, exit: 0, output: "saída real" }], data: {}, ...over,
});

export type Routes = Parameters<typeof fakeFetch>[0];

export function renderWith(routes: Routes, ui: ReactNode, navigate: (id: string) => void = () => {}) {
  const fake = fakeFetch(routes);
  const view = render(
    <ShellContext.Provider value={{ info, session: null as never, draft: "", setDraft: () => {}, focusComposer: false, navigate, bus: createFeatureBus(), fetchImpl: fake.impl }}>
      {ui}
    </ShellContext.Provider>,
  );
  const posts = (path: string) => fake.calls.filter((c) => c.method === "POST" && c.path === path);
  return { ...view, calls: fake.calls, posts };
}
