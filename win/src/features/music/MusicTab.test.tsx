import { act, screen, waitFor, within } from "@testing-library/react";
import userEvent from "@testing-library/user-event";
import { afterEach, vi } from "vitest";
import { failure, mountInShell, recordingFetch, type Seen } from "../home/testShell";
import { MusicTab } from "./MusicTab";
import type { Status } from "./types";

const status = (over: Partial<Status> = {}): Status => ({
  storage: true,
  has_client_id: true,
  client_id: "cid",
  signed_in: true,
  signing_in: false,
  error: null,
  media: true,
  ...over,
});

const TRACK = { player: "Spotify", title: "Garota de Ipanema", artist: "Tom Jobim", album: "Álbum", is_playing: true, position: 12, duration: 200, key: "k1" };
const EMPTY = "Abra o Spotify ou o Music para ver o que está tocando";
const PLAYLISTS = [
  { id: "p1", name: "Bossa", uri: "spotify:playlist:p1", image: null, owner: "Eu", track_count: 2, collaborative: false },
  { id: "p2", name: "Rock", uri: "spotify:playlist:p2", image: null, owner: null, track_count: null, collaborative: false },
];
const TRACKS = [
  { uri: "spotify:track:t1", name: "Chega de Saudade", artists: "João Gilberto", duration_ms: 205_000, image: null },
  { uri: "spotify:track:t2", name: "Desafinado", artists: "João Gilberto", duration_ms: 61_000, image: null },
];

type Overrides = { status?: Status; now?: unknown; extra?: (c: Seen) => unknown };

function mount(over: Overrides = {}) {
  const state = { status: over.status ?? status(), now: over.now ?? { track: TRACK, empty: EMPTY } };
  const { impl, seen } = recordingFetch((c) => {
    const custom = over.extra?.(c);
    if (custom !== undefined) return custom;
    const key = `${c.method} ${c.path}`;
    if (key === "GET /api/music/status") return state.status;
    if (key === "GET /api/music/now") return state.now;
    if (key === "GET /api/music/artwork") return { data_url: "data:image/png;base64,ART" };
    if (key === "GET /api/music/playlists") return { items: PLAYLISTS };
    if (key === "GET /api/music/playlists/p1/tracks") return { items: TRACKS };
    if (c.method === "POST" || c.method === "PUT") return { ok: true };
    return undefined;
  });
  const view = mountInShell(<MusicTab />, { fetchImpl: impl });
  return { ...view, seen, state };
}

afterEach(() => vi.useRealTimers());

describe("Música tab: now playing", () => {
  it("shows what is playing with the Mac's compact card", async () => {
    mount();
    expect(await screen.findByText("Garota de Ipanema")).toBeInTheDocument();
    expect(screen.getByText("no Spotify")).toBeInTheDocument();
    expect(screen.getByText("Tom Jobim")).toBeInTheDocument();
    expect(screen.getByText("0:12")).toBeInTheDocument();
    expect(screen.getByText("-3:08")).toBeInTheDocument();
    await waitFor(() => expect(screen.getByAltText("Capa do álbum")).toHaveAttribute("src", "data:image/png;base64,ART"));
  });

  it("says what to do when nothing plays", async () => {
    mount({ now: { track: null, empty: EMPTY } });
    expect(await screen.findByText(EMPTY)).toBeInTheDocument();
  });

  it("sends previous, play/pause and next to the system session", async () => {
    const { seen } = mount();
    await screen.findByText("Garota de Ipanema");
    await userEvent.click(screen.getByRole("button", { name: "Anterior" }));
    await userEvent.click(screen.getByRole("button", { name: "Pausar" }));
    await userEvent.click(screen.getByRole("button", { name: "Próxima" }));
    const sent = seen.filter((c) => c.path === "/api/music/control").map((c) => c.body);
    expect(sent).toEqual([{ action: "previous" }, { action: "playpause" }, { action: "next" }]);
  });

  it("offers Tocar when paused and refreshes the track every second", async () => {
    vi.useFakeTimers({ toFake: ["setInterval", "clearInterval", "setTimeout", "clearTimeout"] });
    const { state } = mount({ now: { track: { ...TRACK, is_playing: false }, empty: EMPTY } });
    const advance = (ms: number) =>
      act(async () => {
        await vi.advanceTimersByTimeAsync(ms);
      });
    await advance(0);
    expect(screen.getByRole("button", { name: "Tocar" })).toBeInTheDocument();
    state.now = { track: { ...TRACK, title: "Outra", position: 70 }, empty: EMPTY };
    await advance(1000);
    expect(screen.getByText("Outra")).toBeInTheDocument();
    expect(screen.getByText("1:10")).toBeInTheDocument();
  });
});

describe("Música tab: connecting Spotify", () => {
  it("walks a first-time user through the four steps and saves the Client ID", async () => {
    const { seen } = mount({ status: status({ signed_in: false, has_client_id: false, client_id: "" }) });
    await userEvent.click(await screen.findByRole("button", { name: /Conectar Spotify/ }));
    expect(screen.getByText("Antes, crie seu app no Spotify em 4 passos.")).toBeInTheDocument();
    expect(screen.getByText("http://127.0.0.1:43821/callback")).toBeInTheDocument();
    expect(screen.getByText(/Em developer.spotify.com\/dashboard, clique em Create app/)).toBeInTheDocument();
    await userEvent.type(screen.getByLabelText("Spotify Client ID"), "abc123");
    await userEvent.click(screen.getByRole("button", { name: "Salvar" }));
    await waitFor(() => expect(seen).toContainEqual({ method: "PUT", path: "/api/music/client", query: "", body: { client_id: "abc123" } }));
  });

  it("starts the login in the browser, waits, and lands on the playlists when the sidecar says connected", async () => {
    const { seen, state, bus } = mount({ status: status({ signed_in: false }) });
    await userEvent.click(await screen.findByRole("button", { name: /Conectar Spotify/ }));
    expect(screen.getByText("Suas playlists, busca e fila, tocando no seu Spotify.")).toBeInTheDocument();
    await waitFor(() => expect(seen).toContainEqual({ method: "POST", path: "/api/music/connect", query: "", body: {} }));
    state.status = status({ signed_in: false, signing_in: true });
    act(() => bus.emit({ feature: "music", type: "auth", state: "connecting" }));
    expect(await screen.findByText("Conectando ao Spotify…")).toBeInTheDocument();
    expect(screen.getByText("Termine o login no navegador; o Wisp espera até 5 minutos.")).toBeInTheDocument();
    await userEvent.click(screen.getByRole("button", { name: "Cancelar" }));
    await waitFor(() => expect(seen.some((c) => c.path === "/api/music/cancel")).toBe(true));
    state.status = status();
    act(() => bus.emit({ feature: "music", type: "auth", state: "connected", message: null }));
    expect(await screen.findByText("Bossa")).toBeInTheDocument();
  });

  it("shows why a login failed", async () => {
    mount({ status: status({ signed_in: false, error: "O login do Spotify expirou; clique em Conectar Spotify de novo." }) });
    expect(await screen.findByText("O login do Spotify expirou; clique em Conectar Spotify de novo.")).toBeInTheDocument();
  });
});

describe("Música tab: Spotify library", () => {
  it("lists playlists with their size and the count in the header", async () => {
    mount();
    expect(await screen.findByText("Bossa")).toBeInTheDocument();
    expect(screen.getByText("2 músicas")).toBeInTheDocument();
    expect(screen.getByText("Playlist")).toBeInTheDocument();
    expect(screen.getByText("2 playlists")).toBeInTheDocument();
  });

  it("opens a playlist, plays it or one track, and queues a track", async () => {
    const { seen } = mount();
    await userEvent.click(await screen.findByRole("button", { name: /^Bossa/ }));
    expect(await screen.findByText("Chega de Saudade")).toBeInTheDocument();
    expect(screen.getByText("3:25")).toBeInTheDocument();
    await userEvent.click(screen.getByRole("button", { name: "Tocar playlist" }));
    const row = screen.getByText("Desafinado").closest("li") as HTMLElement;
    await userEvent.click(within(row).getByRole("button", { name: "Tocar" }));
    await userEvent.click(within(row).getByRole("button", { name: "Adicionar à fila" }));
    const posts = seen.filter((c) => c.method === "POST").map((c) => [c.path, c.body]);
    expect(posts).toContainEqual(["/api/music/play", { context_uri: "spotify:playlist:p1" }]);
    expect(posts).toContainEqual(["/api/music/play", { uris: ["spotify:track:t2"] }]);
    expect(posts).toContainEqual(["/api/music/queue", { uri: "spotify:track:t2" }]);
    expect(await screen.findByText("“Desafinado” entra a seguir na fila.")).toBeInTheDocument();
    await userEvent.click(screen.getByRole("button", { name: "Voltar às playlists" }));
    expect(await screen.findByText("Rock")).toBeInTheDocument();
  });

  it("shows the Mac's sentence when Spotify refuses to list a playlist", async () => {
    mount({
      extra: (c) =>
        c.path === "/api/music/playlists/p1/tracks"
          ? failure(403, "O Spotify só lista as músicas das playlists que você criou ou edita; use Tocar para ouvir esta.")
          : undefined,
    });
    await userEvent.click(await screen.findByRole("button", { name: /^Bossa/ }));
    expect(await screen.findByText(/só lista as músicas das playlists que você criou/)).toBeInTheDocument();
  });

  it("shows a playback error from the sidecar as a notice", async () => {
    mount({ extra: (c) => (c.path === "/api/music/play" ? failure(403, "Para tocar pelo Wisp a conta precisa de Spotify Premium.") : undefined) });
    await userEvent.click(await screen.findByRole("button", { name: /^Bossa/ }));
    await userEvent.click(await screen.findByRole("button", { name: "Tocar playlist" }));
    expect(await screen.findByText("Para tocar pelo Wisp a conta precisa de Spotify Premium.")).toBeInTheDocument();
  });

  it("searches after a short pause and groups the results", async () => {
    const { seen } = mount({
      extra: (c) =>
        c.path === "/api/music/search"
          ? {
              tracks: [{ uri: "spotify:track:s1", name: "Águas de Março", artists: "Elis", duration_ms: 180_000, image: null }],
              albums: [{ id: "a1", name: "Elis & Tom", uri: "spotify:album:a1", image: null, artists: "Elis Regina", total_tracks: 10 }],
              playlists: [],
              artists: [{ id: "r1", name: "Elis Regina", uri: "spotify:artist:r1", image: null }],
            }
          : undefined,
    });
    await userEvent.type(await screen.findByPlaceholderText("Buscar no Spotify"), "elis");
    expect(await screen.findByText("Águas de Março")).toBeInTheDocument();
    for (const heading of ["Músicas", "Álbuns", "Artistas"]) expect(screen.getByText(heading)).toBeInTheDocument();
    expect(screen.queryByText("Playlists")).not.toBeInTheDocument();
    expect(seen.filter((c) => c.path === "/api/music/search").map((c) => c.query)).toEqual(["?q=elis"]);
    await userEvent.click(screen.getByRole("button", { name: "Tocar álbum" }));
    await waitFor(() => expect(seen).toContainEqual({ method: "POST", path: "/api/music/play", query: "", body: { context_uri: "spotify:album:a1" } }));
  });

  it("says when a search finds nothing", async () => {
    mount({ extra: (c) => (c.path === "/api/music/search" ? { tracks: [], albums: [], playlists: [], artists: [] } : undefined) });
    await userEvent.type(await screen.findByPlaceholderText("Buscar no Spotify"), "zzz");
    expect(await screen.findByText("Nada no Spotify para “zzz”")).toBeInTheDocument();
  });

  it("signs out from the card", async () => {
    const { seen } = mount();
    await userEvent.click(await screen.findByRole("button", { name: "Sair" }));
    await waitFor(() => expect(seen.some((c) => c.path === "/api/music/signout")).toBe(true));
  });
});
