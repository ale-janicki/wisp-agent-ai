import { screen, waitFor, within } from "@testing-library/react";
import userEvent from "@testing-library/user-event";
import { vi } from "vitest";
import { HomeTab } from "./HomeTab";
import { mountInShell, recordingFetch, type Seen } from "./testShell";

const EMPTY = "Abra o Spotify ou o Music para ver o que está tocando";
const TRACK = { player: "Spotify", title: "Garota de Ipanema", artist: "Tom Jobim", album: "", is_playing: true, position: 12, duration: 200, key: "k1" };
const at = (h: number, m: number) => new Date(2026, 11, 3, h, m).getTime() / 1000;

type Setup = { profile?: unknown; now?: unknown; usage?: unknown; conversations?: unknown; extra?: (c: Seen) => unknown };

function mount(setup: Setup = {}) {
  const send = vi.fn();
  const open = vi.fn();
  const navigate = vi.fn();
  const setDraft = vi.fn();
  const { impl, seen } = recordingFetch((c) => {
    const custom = setup.extra?.(c);
    if (custom !== undefined) return custom;
    switch (`${c.method} ${c.path}`) {
      case "GET /api/home/profile":
        return setup.profile ?? { user: "Maria da Silva", first_name: "Maria", persona: "Pip", language: "pt-BR" };
      case "GET /api/home/usage":
        return setup.usage ?? { limits: null, tokens: { today: 0, week: 0 } };
      case "GET /api/home/conversations":
        return setup.conversations ?? { items: [], total: 0 };
      case "GET /api/music/now":
        return setup.now ?? { track: null, empty: EMPTY };
      case "GET /api/music/artwork":
        return { data_url: null };
      default:
        return c.method === "POST" ? { ok: true } : undefined;
    }
  });
  const session = { state: { currentId: null, status: {}, conversations: [] }, send, open, stop: vi.fn(), newConversation: vi.fn(), answer: vi.fn() } as never;
  const view = mountInShell(<HomeTab />, { fetchImpl: impl, session, navigate, setDraft, draft: "" });
  return { ...view, seen, send, open, navigate, setDraft };
}

describe("Início", () => {
  it("greets the user by the first name from the wisp profile", async () => {
    mount();
    expect(await screen.findByRole("heading", { name: "Olá, Maria!" })).toBeInTheDocument();
    expect(screen.getByText("Escreva para o Pip")).toBeInTheDocument();
  });

  it("greets without a name when the profile cannot be read, never inventing one", async () => {
    mount({ extra: (c) => (c.path === "/api/home/profile" ? new Response("x", { status: 500 }) : undefined) });
    expect(await screen.findByRole("heading", { name: "Olá!" })).toBeInTheDocument();
    expect(screen.getByText("Escreva para o Wisp")).toBeInTheDocument();
  });

  it("sends what is typed to a conversation and opens the Conversa tab", async () => {
    const { send, navigate } = mount();
    await screen.findByRole("heading", { name: /Olá/ });
    const field = screen.getByPlaceholderText(/Pergunte ao/);
    await userEvent.type(field, "oi");
    await userEvent.keyboard("{Enter}");
    expect(send).toHaveBeenCalledWith("oi");
    expect(navigate).toHaveBeenCalledWith("conversa");
  });
});

describe("Início: Música tile", () => {
  it("shows what is playing and its player", async () => {
    mount({ now: { track: TRACK, empty: EMPTY } });
    const tile = await screen.findByRole("region", { name: "Música" });
    expect(await within(tile).findByText("Garota de Ipanema")).toBeInTheDocument();
    expect(within(tile).getByText("Tom Jobim")).toBeInTheDocument();
    expect(within(tile).getByText("Spotify")).toBeInTheDocument();
    expect(within(tile).getByRole("button", { name: "Pausar" })).toBeInTheDocument();
  });

  it("says what to do when nothing plays", async () => {
    mount();
    const tile = await screen.findByRole("region", { name: "Música" });
    expect(await within(tile).findByText(EMPTY)).toBeInTheDocument();
  });
});

describe("Início: Uso do Claude tile", () => {
  it("shows both limits with their renewal and how old the reading is", async () => {
    const nowSeconds = Date.now() / 1000;
    mount({
      usage: {
        limits: {
          captured_at: nowSeconds - 300,
          rows: [
            { kind: "session", state: "used", percent: 80, resets_at: at(14, 30), severity: "warning" },
            { kind: "week", state: "renewed" },
          ],
        },
        tokens: { today: 1200, week: 30_000 },
      },
    });
    const tile = await screen.findByRole("region", { name: "Uso do Claude" });
    expect(await within(tile).findByText("Sessão 80%")).toBeInTheDocument();
    expect(within(tile).getByText("· renova 14:30")).toBeInTheDocument();
    expect(within(tile).getByText("Semana renovado")).toBeInTheDocument();
    expect(within(tile).getByText("atualizado há 5 min")).toBeInTheDocument();
    expect(within(tile).getByText("Hoje 1,2 mil tokens · 7 dias 30 mil tokens")).toBeInTheDocument();
    expect(within(tile).getByRole("progressbar", { name: "Sessão" })).toHaveAttribute("aria-valuenow", "80");
  });

  it("says to open Claude Code when there is no limit file", async () => {
    mount();
    const tile = await screen.findByRole("region", { name: "Uso do Claude" });
    expect(await within(tile).findByText("Abra o Claude Code para ler o limite")).toBeInTheDocument();
  });

  it("marks a week limit's renewal with the weekday", async () => {
    mount({ usage: { limits: { captured_at: Date.now() / 1000, rows: [{ kind: "week", state: "used", percent: 95, resets_at: at(9, 5), severity: "critical" }] }, tokens: null } });
    const tile = await screen.findByRole("region", { name: "Uso do Claude" });
    expect(await within(tile).findByText("· renova qui 09:05")).toBeInTheDocument();
  });
});

describe("Início: Conversas tile", () => {
  const now = new Date();
  const iso = (d: Date) => d.toISOString();
  const yesterday = new Date(now.getFullYear(), now.getMonth(), now.getDate() - 1, 18, 5);

  it("lists the newest conversations with date and preview and opens one", async () => {
    const { open, navigate } = mount({
      conversations: {
        total: 7,
        items: [
          { id: "c1", title: "Plano da semana", updated_at: iso(new Date(now.getFullYear(), now.getMonth(), now.getDate(), 9, 30)), preview: "Segunda: revisar", telegram: false, engine: "claude" },
          { id: "c2", title: "Ideias", updated_at: iso(yesterday), preview: null, telegram: true, engine: "claude" },
        ],
      },
    });
    const tile = await screen.findByRole("region", { name: "Conversas" });
    expect(await within(tile).findByText("Plano da semana")).toBeInTheDocument();
    expect(within(tile).getByText("7")).toBeInTheDocument();
    expect(within(tile).getByText("hoje, 09:30")).toBeInTheDocument();
    expect(within(tile).getByText("ontem, 18:05")).toBeInTheDocument();
    expect(within(tile).getByText("Segunda: revisar")).toBeInTheDocument();
    await userEvent.click(within(tile).getByRole("button", { name: /Plano da semana/ }));
    expect(open).toHaveBeenCalledWith("c1");
    expect(navigate).toHaveBeenCalledWith("conversa");
  });

  it("says there are none yet", async () => {
    mount();
    const tile = await screen.findByRole("region", { name: "Conversas" });
    expect(await within(tile).findByText("Nenhuma conversa ainda")).toBeInTheDocument();
  });

  it("does not show the Notificações tile, which needs the Tasks tab", async () => {
    mount();
    await screen.findByRole("region", { name: "Conversas" });
    expect(screen.queryByRole("region", { name: "Notificações" })).not.toBeInTheDocument();
    await waitFor(() => expect(screen.getAllByRole("region")).toHaveLength(3));
  });
});
