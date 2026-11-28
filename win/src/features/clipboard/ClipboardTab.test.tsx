import { act, fireEvent, screen, waitFor, within } from "@testing-library/react";
import userEvent from "@testing-library/user-event";
import { mountInShell } from "../home/testShell";
import { ClipboardTab } from "./ClipboardTab";
import type { ClipItem, ItemsResponse } from "./types";

const NOW = Date.now() / 1000;
const text = (id: string, body: string, over: Partial<ClipItem> = {}): ClipItem => ({ id, kind: "text", text: body, image: null, copied_at: NOW - 300, pinned: false, ...over });

type Seen = { method: string; url: string; body: unknown };

function server(initial: Partial<ItemsResponse> & { items: ClipItem[] }) {
  let state: ItemsResponse = { capture: true, notice: null, empty: null, available: true, ...initial };
  const seen: Seen[] = [];
  const impl = (async (input: RequestInfo | URL, init?: RequestInit) => {
    const url = new URL(String(input));
    const method = init?.method ?? "GET";
    const body = init?.body ? JSON.parse(String(init.body)) : undefined;
    seen.push({ method, url: url.pathname + url.search, body });
    const json = (value: unknown) => new Response(JSON.stringify(value), { status: 200 });
    if (url.pathname === "/api/clipboard/items" && method === "GET") return json(state);
    if (url.pathname.endsWith("/thumbnail")) return json({ data_url: "data:image/png;base64,AAAA" });
    if (url.pathname === "/api/clipboard/capture") {
      state = { ...state, capture: body.enabled };
      return json({ capture: body.enabled });
    }
    return json({ ok: true });
  }) as typeof fetch;
  return { impl, seen, set: (next: Partial<ItemsResponse>) => (state = { ...state, ...next }) };
}

describe("Copiados tab", () => {
  it("says nothing was copied yet", async () => {
    const s = server({ items: [], empty: "Nada copiado ainda" });
    mountInShell(<ClipboardTab />, { fetchImpl: s.impl });
    expect(await screen.findByText("Nada copiado ainda")).toBeInTheDocument();
    expect(screen.getByRole("heading", { name: "Copiados" })).toBeInTheDocument();
    expect(screen.getByRole("button", { name: "Limpar" })).toBeDisabled();
  });

  it("lists each item with the Mac's preview and caption", async () => {
    const s = server({
      items: [
        text("A", "\n  primeira linha  \nsegunda\nterceira"),
        text("B", "https://wisp.example/x", { kind: "url", copied_at: NOW - 10 }),
        { id: "C", kind: "image", text: null, image: "C.png", copied_at: NOW - 7200, pinned: false },
      ],
    });
    mountInShell(<ClipboardTab />, { fetchImpl: s.impl });
    expect(await screen.findByText("primeira linha")).toBeInTheDocument();
    expect(screen.getByText("há 5 min. · 3 linhas")).toBeInTheDocument();
    expect(screen.getByText("agora · link")).toBeInTheDocument();
    expect(screen.getByText("Imagem")).toBeInTheDocument();
    expect(screen.getByText(/há 2 h · imagem/)).toBeInTheDocument();
    await waitFor(() => expect(screen.getByAltText("Imagem copiada")).toHaveAttribute("src", "data:image/png;base64,AAAA"));
  });

  it("searches on the server as the user types", async () => {
    const s = server({ items: [text("A", "oi")] });
    mountInShell(<ClipboardTab />, { fetchImpl: s.impl });
    await screen.findByText("oi");
    await userEvent.type(screen.getByPlaceholderText("Buscar nos copiados"), "reun");
    await waitFor(() => expect(s.seen.at(-1)?.url).toBe("/api/clipboard/items?q=reun"));
  });

  it("says nothing matched when a search is empty", async () => {
    const s = server({ items: [], empty: "Nada encontrado" });
    mountInShell(<ClipboardTab />, { fetchImpl: s.impl });
    expect(await screen.findByText("Nada encontrado")).toBeInTheDocument();
  });

  it("copies on click and marks the row as copied", async () => {
    const s = server({ items: [text("A", "olá")] });
    mountInShell(<ClipboardTab />, { fetchImpl: s.impl });
    await userEvent.click(await screen.findByRole("button", { name: /olá/ }));
    await waitFor(() => expect(s.seen).toContainEqual({ method: "POST", url: "/api/clipboard/items/A/copy", body: {} }));
    expect(await screen.findByText("copiado")).toBeInTheDocument();
  });

  it("pins and removes from the row's own buttons", async () => {
    const s = server({ items: [text("A", "olá")] });
    mountInShell(<ClipboardTab />, { fetchImpl: s.impl });
    const row = (await screen.findByText("olá")).closest("li") as HTMLElement;
    await userEvent.click(within(row).getByRole("button", { name: "Fixar" }));
    await userEvent.click(within(row).getByRole("button", { name: "Remover" }));
    await waitFor(() => {
      expect(s.seen).toContainEqual({ method: "POST", url: "/api/clipboard/items/A/pin", body: {} });
      expect(s.seen).toContainEqual({ method: "DELETE", url: "/api/clipboard/items/A", body: undefined });
    });
  });

  it("asks before clearing and keeps pinned items out of the question", async () => {
    const s = server({ items: [text("A", "a"), text("B", "b", { pinned: true })] });
    mountInShell(<ClipboardTab />, { fetchImpl: s.impl });
    await screen.findByText("a");
    await userEvent.click(screen.getByRole("button", { name: "Limpar" }));
    expect(screen.getByText("Limpar o histórico? Os fixados ficam.")).toBeInTheDocument();
    await userEvent.click(screen.getByRole("button", { name: "Não" }));
    expect(s.seen.some((c) => c.url.endsWith("/clear"))).toBe(false);
    await userEvent.click(screen.getByRole("button", { name: "Limpar" }));
    await userEvent.click(screen.getByRole("button", { name: "Sim" }));
    await waitFor(() => expect(s.seen).toContainEqual({ method: "POST", url: "/api/clipboard/clear", body: {} }));
  });

  it("warns when capture is off and turns it back on", async () => {
    const s = server({ items: [], capture: false, empty: "Nada copiado ainda" });
    mountInShell(<ClipboardTab />, { fetchImpl: s.impl });
    expect(await screen.findByText("A captura está desligada; ligue para guardar o que você copiar.")).toBeInTheDocument();
    await userEvent.click(screen.getByRole("button", { name: "Ligar" }));
    await waitFor(() => expect(s.seen).toContainEqual({ method: "PUT", url: "/api/clipboard/capture", body: { enabled: true } }));
    await waitFor(() => expect(screen.queryByText(/captura está desligada/)).not.toBeInTheDocument());
  });

  it("shows the store's notice and reloads when the sidecar says the history changed", async () => {
    const s = server({ items: [text("A", "velho")], notice: "o histórico de copiados estava corrompido" });
    const { bus } = mountInShell(<ClipboardTab />, { fetchImpl: s.impl });
    expect(await screen.findByText("o histórico de copiados estava corrompido")).toBeInTheDocument();
    s.set({ items: [text("N", "novo"), text("A", "velho")], notice: null });
    act(() => bus.emit({ feature: "clipboard", type: "changed" }));
    expect(await screen.findByText("novo")).toBeInTheDocument();
    fireEvent.click(document.body);
  });

  it("tells when the system clipboard cannot be watched here", async () => {
    const s = server({ items: [], available: false, empty: "Nada copiado ainda" });
    mountInShell(<ClipboardTab />, { fetchImpl: s.impl });
    expect(await screen.findByText("Não consigo ler a área de transferência neste sistema.")).toBeInTheDocument();
  });
});
