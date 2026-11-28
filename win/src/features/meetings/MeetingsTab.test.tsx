import { act, render, screen, waitFor, within } from "@testing-library/react";
import userEvent from "@testing-library/user-event";
import { createFeatureBus, type FeatureBus } from "../../api/featureEvents";
import { ShellContext } from "../../shell/context";
import { fakeFetch } from "../../test/fakes";
import { MeetingsTab } from "./MeetingsTab";
import type { Copilot, Detail, MeetingsState, ModelItem, Row } from "./types";

const info = { port: 4242, token: "tok" };

const copilot = (over: Partial<Copilot> = {}): Copilot => ({
  assist: false,
  lookup: false,
  lookup_others: false,
  nudges: false,
  items: [],
  hits: [],
  nudge: null,
  metrics: null,
  checklist: [],
  prep: [],
  ...over,
});

const state = (over: Partial<MeetingsState> = {}): MeetingsState => ({
  phase: "idle",
  meeting: null,
  elapsed: 0,
  paused: false,
  sources: "both",
  source_labels: { both: "Microfone e áudio do computador", mic: "Só microfone", system: "Só áudio do computador" },
  warnings: [],
  levels: { mic: 0, system: 0 },
  lag: false,
  saving: null,
  message: null,
  live_model_ready: true,
  copilot: copilot(),
  processing: {},
  webhook_offers: {},
  ...over,
});

const row = (over: Partial<Row> = {}): Row => ({
  id: "m1",
  title: "Plano de lançamento",
  date_text: "01/05 13:30",
  duration_text: "2:05",
  badge: { label: "pronto", tone: "ready" },
  detail: null,
  notice: null,
  has_note: true,
  has_transcript: true,
  ...over,
});

const detail = (over: Partial<Detail> = {}, meta: Partial<Detail["meta"]> = {}): Detail => ({
  row: row(),
  meta: {
    status: "noted",
    failure: null,
    notice: null,
    brain_error: null,
    started_at: "2026-05-01T13:30:00Z",
    duration_s: 125,
    title: "Plano de lançamento",
    metrics: null,
    language: "pt",
    note_state: "generated",
    sources: "both",
    webhook_sent_at: null,
    ...meta,
  },
  note: "# Plano de lançamento\n\n## Resumo\n\nCombinamos a data.",
  lines: [
    { id: "eu-0", time: "0:01", speaker: "Você", text: "olá a todos", is_partial: false, is_mine: true, is_bookmark: false, is_pause: false },
    { id: "outros-2000", time: "0:02", speaker: "Outros", text: "bom dia", is_partial: false, is_mine: false, is_bookmark: false, is_pause: false },
  ],
  has_audio: true,
  brain: { label: "Salvar no brain", opens_note: false },
  job: null,
  webhook_offer: null,
  ...over,
});

const models = (installed = true): { items: ModelItem[]; attribution: string } => ({
  items: [
    { id: "small", label: "Whisper small (ao vivo)", license: "MIT", size_bytes: 483546902, role: "live", wanted: true, installed, downloading: false, progress: null, error: null },
    { id: "large-v3", label: "Whisper large-v3", license: "MIT", size_bytes: 3087284237, role: "refine", wanted: true, installed: false, downloading: false, progress: null, error: null },
  ],
  attribution: "Modelos Whisper da OpenAI (licença MIT).",
});

type Routes = Parameters<typeof fakeFetch>[0];

function setup(routes: Routes, bus: FeatureBus = createFeatureBus()) {
  const base: Routes = {
    "GET /api/meetings/state": () => state(),
    "GET /api/meetings/meetings": () => ({ items: [] }),
    "GET /api/meetings/models": () => models(),
    "GET /api/meetings/settings": () => settingsPayload(),
    ...routes,
  };
  const fake = fakeFetch(base);
  render(
    <ShellContext.Provider
      value={{ info, bus, fetchImpl: fake.impl, session: null as never, draft: "", setDraft: () => {}, focusComposer: false, navigate: () => {} }}
    >
      <MeetingsTab />
    </ShellContext.Provider>,
  );
  return { ...fake, bus };
}

const settingsPayload = () => ({
  values: { webhookEnabled: false, webhookSigns: false, limitMinutes: 120, autoSummary: true, language: "pt", postCallEngine: "whisperLargeV3", cleanupDays: 0 },
  languages: [
    { id: "pt", label: "Português (BR)" },
    { id: "en", label: "English" },
  ],
  engines: [
    { id: "whisperLargeV3", label: "Whisper large-v3 (recomendado)" },
    { id: "off", label: "Desligado (só o ao vivo)" },
  ],
  limit_choices: [30, 60, 120],
  cleanup_choices: [7, 14, 30],
  recordings_path: "C:\\Wisp\\reunioes",
  webhook: { url_set: false, masked_url: null, secret_set: false, enabled: false, signs: false },
  brain_search: true,
});

describe("Reuniões tab", () => {
  it("lists past meetings newest first with their status and says when there are none", async () => {
    setup({
      "GET /api/meetings/meetings": () => ({
        items: [row(), row({ id: "m0", title: "Antiga", badge: { label: "transcrevendo", tone: "working" }, date_text: "30/04 09:00", duration_text: "—" })],
      }),
    });
    const list = await screen.findAllByRole("listitem");
    expect(list.map((el) => within(el).getByText(/Plano|Antiga/).textContent)).toEqual(["Plano de lançamento", "Antiga"]);
    expect(within(list[0]!).getByText("pronto")).toBeInTheDocument();
    expect(within(list[1]!).getByText("transcrevendo")).toBeInTheDocument();
  });

  it("shows skeleton rows until the first scan and then 'Nenhuma reunião ainda.'", async () => {
    setup({});
    expect(await screen.findByText("Nenhuma reunião ainda.")).toBeInTheDocument();
    expect(screen.queryByLabelText("Carregando reuniões")).not.toBeInTheDocument();
  });

  it("starts a recording, shows the timer and the live lines with a grey partial, then stops it", async () => {
    const user = userEvent.setup();
    let phase: "idle" | "recording" = "idle";
    const { calls, bus } = setup({
      "GET /api/meetings/state": () => state({ phase }),
      "POST /api/meetings/record/start": () => {
        phase = "recording";
        return state({ phase: "recording", meeting: "m9", elapsed: 7 });
      },
      "POST /api/meetings/record/stop": () => {
        phase = "idle";
        return state({ message: { text: "Gravação salva (0:07)", tone: "info" } });
      },
    });
    await user.click(await screen.findByRole("button", { name: "Gravar" }));
    await waitFor(() => expect(calls.some((c) => c.method === "POST" && c.path === "/api/meetings/record/start")).toBe(true));
    expect(await screen.findByRole("button", { name: /Parar/ })).toBeInTheDocument();
    expect(screen.getByLabelText("Tempo de gravação")).toHaveTextContent("0:07");
    expect(screen.getByText("Ainda sem fala")).toBeInTheDocument();

    act(() => {
      bus.emit({
        feature: "meetings",
        type: "transcript",
        lines: [
          { id: "eu-1000", time: "0:01", speaker: "Você", text: "vamos começar", is_partial: false, is_mine: true, is_bookmark: false, is_pause: false },
          { id: "outros-partial", time: "0:03", speaker: "Outros", text: "…", is_partial: true, is_mine: false, is_bookmark: false, is_pause: false },
        ],
      });
    });
    const log = await screen.findByRole("log", { name: "Transcrição ao vivo" });
    expect(within(log).getByText("vamos começar")).toBeInTheDocument();
    expect(within(log).getByText("…").closest("div")?.className).toMatch(/partial/);

    await user.click(screen.getByRole("button", { name: /Parar/ }));
    expect(await screen.findByText("Gravação salva (0:07)")).toBeInTheDocument();
  });

  it("shows the recorder warnings, the lag notice and lets the user mark a moment", async () => {
    const user = userEvent.setup();
    const { calls } = setup({
      "GET /api/meetings/state": () =>
        state({ phase: "recording", meeting: "m9", warnings: ["o microfone parou"], lag: true }),
      "POST /api/meetings/record/bookmark": () => state({ phase: "recording", meeting: "m9" }),
    });
    expect(await screen.findByText("o microfone parou")).toBeInTheDocument();
    expect(screen.getByText("Transcrição atrasada")).toBeInTheDocument();
    await user.click(screen.getByRole("button", { name: "Marcar momento" }));
    await waitFor(() => expect(calls.some((c) => c.path === "/api/meetings/record/bookmark")).toBe(true));
  });

  it("pauses and resumes", async () => {
    const user = userEvent.setup();
    let paused = false;
    const { calls } = setup({
      "GET /api/meetings/state": () => state({ phase: "recording", meeting: "m9", paused }),
      "POST /api/meetings/record/pause": () => {
        paused = true;
        return state({ phase: "recording", meeting: "m9", paused: true });
      },
      "POST /api/meetings/record/resume": () => state({ phase: "recording", meeting: "m9" }),
    });
    await user.click(await screen.findByRole("button", { name: "Pausar" }));
    await user.click(await screen.findByRole("button", { name: "Retomar" }));
    expect(calls.filter((c) => c.method === "POST").map((c) => c.path)).toEqual(["/api/meetings/record/pause", "/api/meetings/record/resume"]);
  });

  it("remembers the source choice through the sidecar", async () => {
    const user = userEvent.setup();
    const { calls } = setup({
      "PUT /api/meetings/record/sources": (body) => state({ sources: (body as { sources: "mic" }).sources }),
    });
    await user.selectOptions(await screen.findByLabelText("Fonte do áudio"), "mic");
    await waitFor(() => expect(calls.find((c) => c.method === "PUT")?.body).toEqual({ sources: "mic" }));
  });

  it("opens a meeting: title, status line, the note rendered, the transcript on the other tab", async () => {
    const user = userEvent.setup();
    setup({
      "GET /api/meetings/meetings": () => ({ items: [row()] }),
      "GET /api/meetings/meetings/m1": () => detail(),
    });
    await user.click(await screen.findByRole("listitem"));
    expect(await screen.findByRole("heading", { name: "Plano de lançamento", level: 2 })).toBeInTheDocument();
    expect(screen.getByText("01/05 13:30 · 2:05 · pronto")).toBeInTheDocument();
    expect(screen.getByRole("heading", { name: "Resumo" })).toBeInTheDocument();
    expect(screen.getByRole("button", { name: "Salvar no brain" })).toBeInTheDocument();
    await user.click(screen.getByRole("tab", { name: "Transcrição" }));
    expect(screen.getByText("olá a todos")).toBeInTheDocument();
    expect(screen.getByText("Outros")).toBeInTheDocument();
  });

  it("offers 'Gerar nota' for a transcript without a note and 'Cancelar nota' while it is written", async () => {
    const user = userEvent.setup();
    let working = false;
    const { calls } = setup({
      "GET /api/meetings/meetings": () => ({ items: [row({ has_note: false, badge: { label: "transcrito", tone: "ready" } })] }),
      "GET /api/meetings/meetings/m1": () =>
        detail(
          { note: null, row: row({ has_note: false, badge: { label: "transcrito", tone: "ready" } }), job: working ? { kind: "process", stage: "writing_note", fraction: null } : null },
          { status: "transcribed" },
        ),
      "POST /api/meetings/meetings/m1/note": () => {
        working = true;
        return detail({ note: null, job: { kind: "process", stage: "writing_note", fraction: null } }, { status: "transcribed" });
      },
      "POST /api/meetings/meetings/m1/cancel": () => ({ ok: true }),
    });
    await user.click(await screen.findByRole("listitem"));
    await user.click(await screen.findByRole("button", { name: "Gerar nota" }));
    expect(await screen.findByRole("button", { name: "Cancelar nota" })).toBeInTheDocument();
    expect(screen.getByRole("status")).toHaveTextContent("Gerando a nota");
    await user.click(screen.getByRole("button", { name: "Cancelar nota" }));
    await waitFor(() => expect(calls.some((c) => c.path === "/api/meetings/meetings/m1/cancel")).toBe(true));
  });

  it("shows a failed note as one plain line with 'Tentar de novo'", async () => {
    const user = userEvent.setup();
    const { calls } = setup({
      "GET /api/meetings/meetings": () => ({ items: [row()] }),
      "GET /api/meetings/meetings/m1": () => detail({}, { failure: "nota não gerada: a IA local não está pronta: sem modelo", note_state: "raw" }),
      "POST /api/meetings/meetings/m1/retry": () => detail(),
    });
    await user.click(await screen.findByRole("listitem"));
    const alert = await screen.findByRole("alert");
    expect(alert).toHaveTextContent("A nota não foi gerada. Tente de novo.");
    expect(alert).toHaveAttribute("title", "nota não gerada: a IA local não está pronta: sem modelo");
    await user.click(within(alert).getByRole("button", { name: "Tentar de novo" }));
    await waitFor(() => expect(calls.some((c) => c.path === "/api/meetings/meetings/m1/retry")).toBe(true));
  });

  it("offers 'Melhorar transcrição' when the sparse-speech notice is set", async () => {
    const user = userEvent.setup();
    const { calls } = setup({
      "GET /api/meetings/meetings": () => ({ items: [row()] }),
      "GET /api/meetings/meetings/m1": () => detail({}, { notice: "Pouca fala detectada nesta gravação. Refiz a transcrição com mais sensibilidade; confira o texto." }),
      "POST /api/meetings/meetings/m1/improve": () => detail(),
    });
    await user.click(await screen.findByRole("listitem"));
    const note = await screen.findByRole("note");
    expect(note).toHaveTextContent("Pouca fala detectada");
    await user.click(within(note).getByRole("button", { name: "Melhorar transcrição" }));
    await waitFor(() => expect(calls.some((c) => c.path === "/api/meetings/meetings/m1/improve")).toBe(true));
  });

  it("the '…' menu has the other actions", async () => {
    const user = userEvent.setup();
    const { calls } = setup({
      "GET /api/meetings/meetings": () => ({ items: [row()] }),
      "GET /api/meetings/meetings/m1": () => detail(),
      "POST /api/meetings/meetings/m1/note": () => detail(),
      "POST /api/meetings/meetings/m1/open-folder": () => ({ ok: true }),
    });
    await user.click(await screen.findByRole("listitem"));
    await user.click(await screen.findByRole("button", { name: "Mais ações" }));
    expect(screen.getAllByRole("menuitem").map((el) => el.textContent)).toEqual([
      "Copiar",
      "Abrir pasta",
      "Gerar nota de novo",
      "Melhorar transcrição",
    ]);
    await user.click(screen.getByRole("menuitem", { name: "Abrir pasta" }));
    await waitFor(() => expect(calls.some((c) => c.path === "/api/meetings/meetings/m1/open-folder")).toBe(true));
  });

  it("shows the model card with download, progress and cancel while the live model is missing", async () => {
    const user = userEvent.setup();
    let downloading = false;
    const { calls, bus } = setup({
      "GET /api/meetings/models": () => {
        const m = models(false);
        if (downloading) m.items[0] = { ...m.items[0]!, downloading: true, progress: 0.4 };
        return m;
      },
      "POST /api/meetings/models/small/download": () => {
        downloading = true;
        return models(false);
      },
      "POST /api/meetings/models/small/cancel": () => {
        downloading = false;
        return models(false);
      },
    });
    const card = await screen.findByRole("region", { name: "Modelos de transcrição" });
    expect(within(card).getByText(/Whisper small/)).toBeInTheDocument();
    expect(within(card).queryByText(/large-v3/)).not.toBeInTheDocument();
    expect(within(card).getByText(/461 MB/)).toBeInTheDocument();
    expect(within(card).getByText(/licença MIT/)).toBeInTheDocument();
    await user.click(within(card).getByRole("button", { name: "Baixar" }));
    const bar = await within(card).findByLabelText(/Baixando Whisper small/);
    expect(bar).toHaveAttribute("value", "0.4");
    act(() => bus.emit({ feature: "meetings", type: "model", id: "small", progress: 0.4 }));
    await user.click(within(card).getByRole("button", { name: "Cancelar" }));
    await waitFor(() => expect(calls.some((c) => c.path === "/api/meetings/models/small/cancel")).toBe(true));
  });

  it("shows the webhook offer with the exact bytes behind an expander and sends only after Permitir", async () => {
    const user = userEvent.setup();
    const offer = { id: "m1", host: "hooks.example.org", masked_url: "https://hooks.example.org/•••", preview: "Combinamos a data.\n1 tópico(s) · 1 ação(ões)", size: "312 B", signed: true, body: '{"a":1}', formatted: '{\n  "a": 1\n}' };
    const { calls } = setup({
      "GET /api/meetings/state": () => state({ webhook_offers: { m1: offer } }),
      "POST /api/meetings/meetings/m1/webhook/confirm": () => ({ confirm: "nonce-1" }),
      "POST /api/meetings/meetings/m1/webhook/allow": () => ({ ok: true }),
    });
    const card = await screen.findByRole("region", { name: "Enviar para o webhook" });
    expect(within(card).getByText("https://hooks.example.org/•••")).toBeInTheDocument();
    expect(within(card).getByText(/Combinamos a data/)).toBeInTheDocument();
    expect(within(card).queryByText('{"a":1}')).not.toBeInTheDocument();
    await user.click(within(card).getByRole("button", { name: "Conteúdo exato" }));
    expect(within(card).getByText('{"a":1}')).toBeInTheDocument();
    expect(calls.some((c) => c.path.endsWith("/webhook/allow"))).toBe(false);
    await user.click(within(card).getByRole("button", { name: "Permitir" }));
    await waitFor(() => expect(calls.some((c) => c.path === "/api/meetings/meetings/m1/webhook/allow")).toBe(true));
    const sent = calls.filter((c) => c.path.includes("/webhook/")).map((c) => [c.path.split("/webhook/")[1], c.body]);
    expect(sent).toEqual([["confirm", {}], ["allow", { confirm: "nonce-1" }]]);
  });

  it("copilot: toggles start off, a suggestion and a nudge show up, the checklist can be ticked", async () => {
    const user = userEvent.setup();
    const live = state({
      phase: "recording",
      meeting: "m9",
      copilot: copilot({
        assist: true,
        items: [{ id: "pergunte-x", kind: "pergunte", label: "Pergunte", text: "Qual é o prazo?" }],
        nudge: { kind: "monologue", text: "Monólogo de 3 min" },
        checklist: [{ id: "p0", text: "Revisar proposta", done: false }],
        metrics: { duration_s: 60, silence_s: 5, you: { words: 40, speaking_s: 30, wpm: 80, questions: 1, longest_monologue_s: 12 }, others: { words: 10, speaking_s: 10, wpm: 60, questions: 0, longest_monologue_s: 5 } },
      }),
    });
    const { calls } = setup({
      "GET /api/meetings/state": () => live,
      "PUT /api/meetings/copilot": () => copilot(),
      "POST /api/meetings/copilot/nudge/dismiss": () => copilot(),
      "PUT /api/meetings/copilot/checklist/p0": () => ({ checklist: [] }),
    });
    expect(await screen.findByText("Monólogo de 3 min")).toBeInTheDocument();
    expect(screen.getByText(/Qual é o prazo/)).toBeInTheDocument();
    expect(screen.getByText("Você 75% · Outros 25%")).toBeInTheDocument();
    await user.click(screen.getByLabelText("Avisos de conversa"));
    await waitFor(() => expect(calls.find((c) => c.method === "PUT" && c.path === "/api/meetings/copilot")?.body).toEqual({ nudges: true }));
    await user.click(screen.getByLabelText("Revisar proposta"));
    await waitFor(() => expect(calls.find((c) => c.path.endsWith("/checklist/p0"))?.body).toEqual({ done: true }));
    await user.click(screen.getByRole("button", { name: "Dispensar aviso" }));
    await waitFor(() => expect(calls.some((c) => c.path.endsWith("/nudge/dismiss"))).toBe(true));
  });

  it("brain lookups are offered only when the CLI has the search command", async () => {
    const live = state({ phase: "recording", meeting: "m9" });
    setup({
      "GET /api/meetings/state": () => live,
      "GET /api/meetings/settings": () => ({ ...settingsPayload(), brain_search: false }),
    });
    await screen.findByRole("complementary", { name: "Copiloto" });
    expect(screen.queryByText("Buscar nomes citados")).not.toBeInTheDocument();
  });

  it("prepares a meeting from a typed description and lists what the engine returned", async () => {
    const user = userEvent.setup();
    let prep: { id: string; text: string; done: boolean }[] = [];
    const { calls } = setup({
      "GET /api/meetings/state": () => state({ copilot: copilot({ prep }) }),
      "POST /api/meetings/copilot/prep": () => {
        prep = [{ id: "p0", text: "Revisar proposta", done: false }];
        return { checklist: prep };
      },
    });
    await user.type(await screen.findByLabelText("Assunto"), "Kickoff");
    await user.click(screen.getByRole("button", { name: "Preparar" }));
    await waitFor(() => expect(calls.find((c) => c.path.endsWith("/copilot/prep"))?.body).toEqual({ title: "Kickoff", description: "" }));
    expect(await screen.findByText("Revisar proposta")).toBeInTheDocument();
  });

  it("shows why a start failed (the sidecar puts it in the state) and lets the user dismiss it", async () => {
    const user = userEvent.setup();
    const reason = "O Windows não deixou o Wisp usar o microfone: libere em Configurações > Privacidade e segurança > Microfone";
    const { calls, bus } = setup({ "POST /api/meetings/record/message/dismiss": () => state() });
    await user.click(await screen.findByRole("button", { name: "Gravar" }));
    await waitFor(() => expect(calls.some((c) => c.path.endsWith("/record/start"))).toBe(true));
    act(() => bus.emit({ feature: "meetings", type: "state", state: state({ message: { text: reason, tone: "error" } }) }));
    const alert = await screen.findByRole("alert");
    expect(alert).toHaveTextContent("Privacidade e segurança");
    expect(screen.queryByText(/start -> 404/)).not.toBeInTheDocument();
    await user.click(within(alert).getByRole("button", { name: "Dispensar" }));
    await waitFor(() => expect(calls.some((c) => c.path.endsWith("/message/dismiss"))).toBe(true));
  });

  it("opens the settings page from the gear and writes a change", async () => {
    const user = userEvent.setup();
    const { calls } = setup({ "PUT /api/meetings/settings": () => ({ ...settingsPayload(), values: { ...settingsPayload().values, language: "en" } }) });
    await user.click(await screen.findByRole("button", { name: "Ajustes das reuniões" }));
    expect(await screen.findByRole("heading", { name: "Ajustes das reuniões" })).toBeInTheDocument();
    expect(screen.getByText(/As gravações ficam em C:\\Wisp\\reunioes/)).toBeInTheDocument();
    await user.selectOptions(screen.getByLabelText("Idioma das reuniões"), "en");
    await waitFor(() => expect(calls.find((c) => c.method === "PUT" && c.path === "/api/meetings/settings")?.body).toEqual({ language: "en" }));
    await user.click(screen.getByRole("button", { name: "Voltar" }));
    expect(screen.queryByRole("heading", { name: "Ajustes das reuniões" })).not.toBeInTheDocument();
  });

  it("listing, state and models reload when the sidecar says the library changed", async () => {
    let items: Row[] = [];
    const { bus } = setup({ "GET /api/meetings/meetings": () => ({ items }) });
    expect(await screen.findByText("Nenhuma reunião ainda.")).toBeInTheDocument();
    items = [row()];
    act(() => bus.emit({ feature: "meetings", type: "meetings" }));
    expect(await screen.findByText("Plano de lançamento")).toBeInTheDocument();
  });

  it("loads the recording only when asked, with the token, and plays it", async () => {
    const user = userEvent.setup();
    const created: Blob[] = [];
    URL.createObjectURL = (blob: Blob | MediaSource) => {
      created.push(blob as Blob);
      return "blob:audio";
    };
    URL.revokeObjectURL = () => {};
    const { calls } = setup({
      "GET /api/meetings/meetings": () => ({ items: [row()] }),
      "GET /api/meetings/meetings/m1": () => detail(),
      "GET /api/meetings/meetings/m1/audio": () => "RIFF",
    });
    await user.click(await screen.findByRole("listitem"));
    await screen.findByRole("heading", { name: "Plano de lançamento", level: 2 });
    expect(calls.some((c) => c.path.endsWith("/audio"))).toBe(false);
    await user.click(screen.getByRole("button", { name: "Ouvir a gravação" }));
    expect(await screen.findByLabelText("Gravação")).toHaveAttribute("src", "blob:audio");
    expect(calls.find((c) => c.path.endsWith("/audio"))?.auth).toBe("Bearer tok");
  });
});
