import { useCallback, useEffect, useRef, useState } from "react";
import { useShell } from "../../shell/context";
import { createCall, MeetingsError } from "./api";
import { ensureTrayWatcher } from "./tray";
import type { Detail, Line, MeetingsState, ModelItem, Row, SettingsPayload, Sources } from "./types";

export type Toast = { text: string; tone: "info" | "error" };

const reason = (error: unknown): string => (error instanceof Error ? error.message : String(error));

export function useMeetings() {
  const { info, bus, fetchImpl } = useShell();
  ensureTrayWatcher(bus);
  const call = useRef(createCall(info, fetchImpl));
  call.current = createCall(info, fetchImpl);
  const [state, setState] = useState<MeetingsState | null>(null);
  const [rows, setRows] = useState<Row[] | null>(null);
  const [lines, setLines] = useState<Line[]>([]);
  const [selected, setSelected] = useState<string | null>(null);
  const [detail, setDetail] = useState<Detail | null>(null);
  const [models, setModels] = useState<{ items: ModelItem[]; attribution: string }>({ items: [], attribution: "" });
  const [settings, setSettings] = useState<SettingsPayload | null>(null);
  const [toast, setToast] = useState<Toast | null>(null);
  const selectedRef = useRef<string | null>(null);
  selectedRef.current = selected;

  const fail = useCallback((error: unknown) => setToast({ text: reason(error), tone: "error" }), []);

  const loadState = useCallback(async () => setState(await call.current<MeetingsState>("GET", "/state")), []);
  const loadRows = useCallback(async () => setRows((await call.current<{ items: Row[] }>("GET", "/meetings")).items), []);
  const loadModels = useCallback(
    async () => setModels(await call.current<{ items: ModelItem[]; attribution: string }>("GET", "/models")),
    [],
  );
  const loadSettings = useCallback(async () => setSettings(await call.current<SettingsPayload>("GET", "/settings")), []);
  const loadDetail = useCallback(async (id: string | null) => {
    if (!id) return setDetail(null);
    try {
      const got = await call.current<Detail>("GET", `/meetings/${encodeURIComponent(id)}`);
      if (selectedRef.current === id) setDetail(got);
    } catch {
      if (selectedRef.current === id) setDetail(null);
    }
  }, []);

  useEffect(() => {
    void Promise.all([loadState(), loadRows(), loadModels(), loadSettings()]).catch(fail);
  }, [loadState, loadRows, loadModels, loadSettings, fail]);

  useEffect(
    () =>
      bus.subscribe("meetings", (event) => {
        switch (event.type) {
          case "state":
            setState(event.state as MeetingsState);
            break;
          case "transcript":
            setLines(event.lines as Line[]);
            break;
          case "meetings":
            void loadRows().catch(fail);
            void loadDetail(selectedRef.current);
            break;
          case "meeting":
            if (event.id === selectedRef.current) void loadDetail(selectedRef.current);
            break;
          case "model":
          case "models":
            void loadModels().catch(fail);
            break;
          case "notice":
            setToast({ text: String(event.message), tone: "error" });
            break;
          case "webhook_result":
            setToast(
              event.ok ? { text: "Webhook enviado.", tone: "info" } : { text: String(event.message ?? "o envio falhou"), tone: "error" },
            );
            void loadDetail(selectedRef.current);
            break;
        }
      }),
    [bus, loadRows, loadDetail, loadModels, fail],
  );

  useEffect(() => {
    if (state?.phase === "idle") setLines([]);
  }, [state?.phase]);

  useEffect(() => {
    void loadDetail(selected);
  }, [selected, loadDetail]);

  const run = useCallback(
    async <T,>(method: string, path: string, body?: unknown): Promise<T | undefined> => {
      try {
        return await call.current<T>(method, path, body ?? {});
      } catch (error) {
        if (!(error instanceof MeetingsError && path === "/record/start")) fail(error);
        return undefined;
      }
    },
    [fail],
  );

  const act = useCallback(
    async (method: string, path: string, body?: unknown) => {
      const got = await run<MeetingsState | Detail | undefined>(method, path, body);
      if (got && "phase" in got) setState(got);
      else if (got && "row" in got && selectedRef.current === got.row.id) setDetail(got);
      return got;
    },
    [run],
  );

  return {
    state,
    rows,
    lines,
    selected,
    detail,
    models,
    settings,
    toast,
    dismissToast: () => setToast(null),
    select: (id: string | null) => setSelected(id),
    start: async () => {
      setSelected(null);
      await act("POST", "/record/start", {});
    },
    stop: () => act("POST", "/record/stop"),
    pause: () => act("POST", "/record/pause"),
    resume: () => act("POST", "/record/resume"),
    bookmark: () => act("POST", "/record/bookmark", {}),
    setSources: (sources: Sources) => act("PUT", "/record/sources", { sources }),
    dismissMessage: () => act("POST", "/record/message/dismiss"),
    generateNote: (id: string) => act("POST", `/meetings/${encodeURIComponent(id)}/note`),
    cancelNote: (id: string) => act("POST", `/meetings/${encodeURIComponent(id)}/cancel`),
    improve: (id: string) => act("POST", `/meetings/${encodeURIComponent(id)}/improve`),
    retry: (id: string) => act("POST", `/meetings/${encodeURIComponent(id)}/retry`),
    saveToBrain: (id: string) => act("POST", `/meetings/${encodeURIComponent(id)}/brain`, {}),
    openBrainNote: (id: string) => act("POST", `/meetings/${encodeURIComponent(id)}/open-brain-note`),
    openFolder: (id: string) => act("POST", `/meetings/${encodeURIComponent(id)}/open-folder`),
    allowWebhook: async (id: string) => {
      const got = await run<{ confirm: string }>("POST", `/meetings/${encodeURIComponent(id)}/webhook/confirm`);
      if (got?.confirm) await act("POST", `/meetings/${encodeURIComponent(id)}/webhook/allow`, { confirm: got.confirm });
    },
    dismissWebhook: (id: string) => act("POST", `/meetings/${encodeURIComponent(id)}/webhook/dismiss`),
    downloadModel: async (id: string) => {
      await run("POST", `/models/${encodeURIComponent(id)}/download`);
      await loadModels();
    },
    cancelModel: async (id: string) => {
      await run("POST", `/models/${encodeURIComponent(id)}/cancel`);
      await loadModels();
    },
    putSettings: async (changes: Record<string, unknown>) => {
      const got = await run<SettingsPayload>("PUT", "/settings", changes);
      if (got) setSettings(got);
      await loadModels();
    },
    putWebhook: async (changes: Record<string, unknown>) => {
      await run("PUT", "/webhook", changes);
      await loadSettings();
    },
    revealSecret: async () => (await run<{ secret: string | null }>("GET", "/webhook/secret"))?.secret ?? null,
    setCopilot: (changes: Record<string, boolean>) => act("PUT", "/copilot", changes),
    dismissNudge: () => act("POST", "/copilot/nudge/dismiss"),
    prepare: async (title: string, description: string) => {
      await act("POST", "/copilot/prep", { title, description });
      await loadState();
    },
    toggleCheck: async (id: string, done: boolean) => {
      await run("PUT", `/copilot/checklist/${encodeURIComponent(id)}`, { done });
      await loadState();
    },
    reloadSettings: loadSettings,
    info,
    fetchImpl,
  };
}

export type Meetings = ReturnType<typeof useMeetings>;
