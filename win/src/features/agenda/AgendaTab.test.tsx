import { act, screen, waitFor, within } from "@testing-library/react";
import userEvent from "@testing-library/user-event";
import { failure, mountInShell, recordingFetch, type Seen } from "../home/testShell";
import { AgendaTab } from "./AgendaTab";
import type { ApiEvent, Quick, Status } from "./types";

const NOW = new Date(2026, 11, 3, 10, 0);
const status = (over: Partial<Status> = {}): Status => ({ storage: true, has_client: true, connected: true, email: "eu@exemplo.com", connecting: false, error: null, ...over });

const event = (over: Partial<ApiEvent> = {}): ApiEvent => ({
  id: "ev1",
  title: "Alinhamento",
  start: new Date(2026, 11, 3, 10, 0).toISOString(),
  end: new Date(2026, 11, 3, 11, 0).toISOString(),
  all_day: false,
  time_zone: null,
  location: "Sala 3",
  notes: "Pauta da semana",
  html_link: null,
  meeting: { provider: "Google Meet", url: "https://meet.google.com/abc-defg" },
  attendees: [
    { name: "Chefe", email: "chefe@exemplo.com", status: "accepted", organizer: true, me: false },
    { name: "eu@exemplo.com", email: "eu@exemplo.com", status: "needsAction", organizer: false, me: true },
  ],
  my_status: "needsAction",
  declined: false,
  can_respond: true,
  recurring: false,
  busy: true,
  cancelled: false,
  ...over,
});

type Setup = { status?: Status; events?: ApiEvent[]; extra?: (c: Seen) => unknown };

function mount(setup: Setup = {}) {
  const state = { status: setup.status ?? status(), events: setup.events ?? [event()] };
  const { impl, seen } = recordingFetch((c) => {
    const custom = setup.extra?.(c);
    if (custom !== undefined) return custom;
    const key = `${c.method} ${c.path}`;
    if (key === "GET /api/agenda/status") return state.status;
    if (key === "GET /api/agenda/events") return { items: state.events };
    if (c.method === "POST" || c.method === "PUT" || c.method === "DELETE") return { ok: true };
    return undefined;
  });
  const view = mountInShell(<AgendaTab now={() => NOW} />, { fetchImpl: impl });
  const fetched = () => seen.filter((c) => c.path === "/api/agenda/events" && c.method === "GET").map((c) => {
    const q = new URLSearchParams(c.query);
    return [new Date(q.get("start")!), new Date(q.get("end")!)] as const;
  });
  return { ...view, seen, state, fetched };
}

describe("Agenda: connecting Google", () => {
  it("asks for the OAuth client file first, with the steps, and keeps it in the sidecar", async () => {
    const { seen } = mount({ status: status({ has_client: false, connected: false, email: null }) });
    expect(await screen.findByText("Conecte sua conta do Google")).toBeInTheDocument();
    expect(screen.getByText(/Crie um cliente OAuth do tipo App para computador/)).toBeInTheDocument();
    await userEvent.click(screen.getByRole("button", { name: "Salvar credenciais" }));
    expect(seen.some((c) => c.method === "PUT")).toBe(false);
    await userEvent.type(screen.getByLabelText("Conteúdo do credentials.json"), "{{}");
    await userEvent.click(screen.getByRole("button", { name: "Salvar credenciais" }));
    await waitFor(() => expect(seen).toContainEqual({ method: "PUT", path: "/api/agenda/client", query: "", body: { credentials: "{}" } }));
  });

  it("shows the sidecar's reason when the file is not a desktop client", async () => {
    mount({
      status: status({ has_client: false, connected: false }),
      extra: (c) => (c.method === "PUT" ? failure(400, "Esse é um cliente da web. Crie um cliente do tipo \"App para computador\" no Google Cloud.") : undefined),
    });
    await userEvent.type(await screen.findByLabelText("Conteúdo do credentials.json"), "x");
    await userEvent.click(screen.getByRole("button", { name: "Salvar credenciais" }));
    expect(await screen.findByRole("alert")).toHaveTextContent("Esse é um cliente da web");
  });

  it("opens the browser login and waits for the sidecar to announce the result", async () => {
    const { seen, state, bus } = mount({ status: status({ connected: false, email: null }) });
    await userEvent.click(await screen.findByRole("button", { name: /^Conectar Google/ }));
    await waitFor(() => expect(seen).toContainEqual({ method: "POST", path: "/api/agenda/connect", query: "", body: {} }));
    state.status = status({ connected: false, connecting: true });
    act(() => bus.emit({ feature: "agenda", type: "auth", state: "connecting" }));
    expect(await screen.findByText("Termine o login no navegador; o Wisp espera até 5 minutos.")).toBeInTheDocument();
    await userEvent.click(screen.getByRole("button", { name: "Cancelar" }));
    await waitFor(() => expect(seen.some((c) => c.path === "/api/agenda/cancel")).toBe(true));
    state.status = status();
    act(() => bus.emit({ feature: "agenda", type: "auth", state: "connected", message: null }));
    expect(await screen.findByRole("button", { name: /Alinhamento/ })).toBeInTheDocument();
  });

  it("shows why a login failed", async () => {
    mount({ status: status({ connected: false, error: "O login do Google expirou; clique em Conectar Google de novo." }) });
    expect(await screen.findByText("O login do Google expirou; clique em Conectar Google de novo.")).toBeInTheDocument();
  });

  it("says Google storage needs Windows when the sidecar cannot protect the token", async () => {
    mount({ status: status({ storage: false, has_client: false, connected: false }) });
    expect(await screen.findByText("Guardar o login do Google só funciona no Windows.")).toBeInTheDocument();
  });
});

describe("Agenda: views", () => {
  it("opens on the week of today and asks the sidecar for exactly those seven days", async () => {
    const { fetched } = mount();
    expect(await screen.findByRole("button", { name: /Alinhamento/ })).toBeInTheDocument();
    expect(screen.getByText("Dezembro de 2026")).toBeInTheDocument();
    expect(screen.getAllByRole("columnheader")).toHaveLength(7);
    expect(fetched()[0]).toEqual([new Date(2026, 10, 29), new Date(2026, 11, 6)]);
  });

  it("switches to day and month views and moves with the arrows and Hoje", async () => {
    const { fetched } = mount();
    await screen.findByRole("button", { name: /Alinhamento/ });
    await userEvent.click(screen.getByRole("tab", { name: "Dia" }));
    expect(screen.getByText("Quinta-feira, 3 de dezembro")).toBeInTheDocument();
    expect(screen.getAllByRole("columnheader")).toHaveLength(1);
    await userEvent.click(screen.getByRole("button", { name: "Próximo" }));
    expect(screen.getByText("Sexta-feira, 4 de dezembro")).toBeInTheDocument();
    await userEvent.click(screen.getByRole("button", { name: "Hoje" }));
    expect(screen.getByText("Quinta-feira, 3 de dezembro")).toBeInTheDocument();
    await userEvent.click(screen.getByRole("tab", { name: "Mês" }));
    expect(await screen.findByText("Dezembro de 2026")).toBeInTheDocument();
    await userEvent.click(screen.getByRole("button", { name: "Próximo" }));
    expect(screen.getByText("Janeiro de 2027")).toBeInTheDocument();
    await waitFor(() => expect(fetched().at(-1)).toEqual([new Date(2026, 11, 27), new Date(2027, 1, 7)]));
  });

  it("shows all-day events above the grid and truncates a crowded month day with +N mais", async () => {
    const day = (n: number, id: string) => event({ id, title: `Evento ${n}`, start: new Date(2026, 11, 3, 8 + n, 0).toISOString(), end: new Date(2026, 11, 3, 8 + n, 30).toISOString() });
    mount({
      events: [event({ id: "all", title: "Retiro", all_day: true, start: "2026-12-03", end: "2026-12-03", meeting: null }), day(1, "a"), day(2, "b"), day(3, "c"), day(4, "d"), day(5, "e")],
    });
    expect(await screen.findByRole("button", { name: /Retiro/ })).toBeInTheDocument();
    await userEvent.click(screen.getByRole("tab", { name: "Mês" }));
    expect(await screen.findByText("+3 mais")).toBeInTheDocument();
  });

  it("explains an empty failure with the sidecar's own words", async () => {
    mount({ extra: (c) => (c.path === "/api/agenda/events" ? failure(409, "Conecte o Google em Ajustes > Integrações para responder.") : undefined) });
    expect(await screen.findByRole("alert")).toHaveTextContent("Conecte o Google em Ajustes > Integrações para responder.");
  });
});

describe("Agenda: event detail and RSVP", () => {
  async function open(setup: Setup = {}) {
    const view = mount(setup);
    await userEvent.click(await screen.findByRole("button", { name: /Alinhamento/ }));
    return { ...view, panel: await screen.findByRole("complementary", { name: "Evento" }) };
  }

  it("shows when, where, who and the notes", async () => {
    const { panel } = await open();
    expect(within(panel).getByRole("heading", { name: "Alinhamento" })).toBeInTheDocument();
    expect(within(panel).getByText("qui., 3 de dez. · 10:00–11:00")).toBeInTheDocument();
    expect(within(panel).getByText("Sala 3")).toBeInTheDocument();
    expect(within(panel).getByText("Pauta da semana")).toBeInTheDocument();
    expect(within(panel).getByText("Convidados")).toBeInTheDocument();
    expect(within(panel).getByText("Chefe")).toBeInTheDocument();
    await userEvent.click(within(panel).getByRole("button", { name: "Fechar" }));
    expect(screen.queryByRole("complementary", { name: "Evento" })).not.toBeInTheDocument();
  });

  it("joins the meeting through the sidecar", async () => {
    const { panel, seen } = await open();
    await userEvent.click(within(panel).getByRole("button", { name: "Entrar" }));
    await waitFor(() => expect(seen).toContainEqual({ method: "POST", path: "/api/home/open", query: "", body: { url: "https://meet.google.com/abc-defg" } }));
  });

  it("answers an invitation with Sim, Talvez or Não and reloads", async () => {
    const { panel, seen, fetched } = await open();
    expect(within(panel).getByText("Vai?")).toBeInTheDocument();
    const before = fetched().length;
    await userEvent.click(within(panel).getByRole("radio", { name: "Talvez" }));
    await waitFor(() => expect(seen).toContainEqual({ method: "POST", path: "/api/agenda/events/ev1/rsvp", query: "", body: { choice: "tentative" } }));
    await waitFor(() => expect(fetched().length).toBeGreaterThan(before));
  });

  it("shows the Mac's sentence when Google refuses the answer", async () => {
    const { panel } = await open({ extra: (c) => (c.path.endsWith("/rsvp") ? failure(409, "Esta conta do Google não está entre os convidados do evento.") : undefined) });
    await userEvent.click(within(panel).getByRole("radio", { name: "Sim" }));
    expect(await within(panel).findByRole("alert")).toHaveTextContent("Esta conta do Google não está entre os convidados do evento.");
  });

  it("has no RSVP for an event the user organises", async () => {
    const { panel } = await open({ events: [event({ can_respond: false, my_status: "accepted" })] });
    expect(within(panel).queryByText("Vai?")).not.toBeInTheDocument();
  });

  it("asks before deleting and warns when guests will be told", async () => {
    const { panel, seen } = await open();
    await userEvent.click(within(panel).getByRole("button", { name: "Apagar" }));
    expect(screen.getByText("Apagar \"Alinhamento\"?")).toBeInTheDocument();
    expect(screen.getByText(/1 convidado receberá um cancelamento\. Isso não pode ser desfeito/)).toBeInTheDocument();
    await userEvent.click(screen.getByRole("button", { name: "Cancelar" }));
    expect(seen.some((c) => c.method === "DELETE")).toBe(false);
    await userEvent.click(within(panel).getByRole("button", { name: "Apagar" }));
    await userEvent.click(within(screen.getByRole("dialog")).getByRole("button", { name: "Apagar" }));
    await waitFor(() => expect(seen).toContainEqual({ method: "DELETE", path: "/api/agenda/events/ev1", query: "", body: undefined }));
  });
});

describe("Agenda: quick create", () => {
  const parsed: Quick = {
    title: "Almoço",
    start: new Date(2026, 11, 4, 13, 0).toISOString(),
    end: new Date(2026, 11, 4, 14, 0).toISOString(),
    all_day: false,
    location: "Centro",
    calendar_name: null,
    has_date: true,
    has_time: true,
  };

  it("previews what the sentence means and creates the event", async () => {
    const { seen } = mount({ extra: (c) => (c.path === "/api/agenda/parse" ? { event: parsed } : undefined) });
    await screen.findByRole("button", { name: /Alinhamento/ });
    await userEvent.click(screen.getByRole("button", { name: "Novo evento" }));
    const field = screen.getByPlaceholderText("almoço amanhã 13h por 1h · reunião sexta 10-11 no calendário Trabalho");
    await userEvent.type(field, "almoço amanhã 13h @ Centro");
    expect(await screen.findByText("Almoço · sex., 4 de dez. · 13:00–14:00 · Centro")).toBeInTheDocument();
    await userEvent.click(screen.getByRole("button", { name: "Criar" }));
    await waitFor(() =>
      expect(seen).toContainEqual({
        method: "POST",
        path: "/api/agenda/events",
        query: "",
        body: { title: "Almoço", start: parsed.start, end: parsed.end, all_day: false, location: "Centro" },
      }),
    );
    await waitFor(() => expect(field).toHaveValue(""));
  });

  it("creates an all-day event from a date alone, sending dates", async () => {
    const day: Quick = { ...parsed, title: "", start: "2026-12-20", end: "2026-12-20", all_day: true, location: null, has_time: false };
    const { seen } = mount({ extra: (c) => (c.path === "/api/agenda/parse" ? { event: day } : undefined) });
    await screen.findByRole("button", { name: /Alinhamento/ });
    await userEvent.click(screen.getByRole("button", { name: "Novo evento" }));
    await userEvent.type(screen.getByPlaceholderText(/almoço amanhã/), "20/12{enter}");
    await waitFor(() =>
      expect(seen).toContainEqual({ method: "POST", path: "/api/agenda/events", query: "", body: { title: "Sem título", start: "2026-12-20", end: "2026-12-20", all_day: true } }),
    );
  });
});

describe("Agenda: side panel", () => {
  it("keeps the Mac's reminder block with its empty state and lets the user disconnect", async () => {
    const { seen } = mount();
    await screen.findByRole("button", { name: /Alinhamento/ });
    await userEvent.click(screen.getByRole("button", { name: "Calendários, lembretes e fusos" }));
    const side = screen.getByRole("complementary", { name: "Calendários e lembretes" });
    expect(within(side).getByText("eu@exemplo.com")).toBeInTheDocument();
    expect(within(side).getByText("Lembretes de hoje")).toBeInTheDocument();
    expect(within(side).getByText("Nada para hoje")).toBeInTheDocument();
    await userEvent.click(within(side).getByRole("button", { name: "Desconectar" }));
    await waitFor(() => expect(seen.some((c) => c.path === "/api/agenda/signout")).toBe(true));
  });
});
