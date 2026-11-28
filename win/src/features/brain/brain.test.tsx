import { act, render, screen, waitFor, within } from "@testing-library/react";
import userEvent from "@testing-library/user-event";
import { useState } from "react";
import { createFeatureBus, type FeatureBus } from "../../api/featureEvents";
import { ShellContext } from "../../shell/context";
import { BrainTab } from "./BrainTab";

const info = { port: 4242, token: "tok" };

type Vault = { notes: Record<string, string>; configured: boolean; conflictOnce: boolean; calls: { method: string; path: string; query: URLSearchParams; body: any }[] };

function sidecar(vault: Vault): typeof fetch {
  const json = (data: unknown, status = 200) => new Response(JSON.stringify(data), { status });
  return (async (input: RequestInfo | URL, init?: RequestInit) => {
    const url = new URL(String(input));
    const method = init?.method ?? "GET";
    const body = init?.body ? JSON.parse(String(init.body)) : undefined;
    vault.calls.push({ method, path: url.pathname, query: url.searchParams, body });
    const route = `${method} ${url.pathname.replace("/api/brain", "")}`;
    const q = (k: string) => url.searchParams.get(k) ?? "";
    switch (route) {
      case "GET /state":
        return json(vault.configured ? { configured: true, name: "cofre" } : { configured: false });
      case "GET /tree":
        return json({ entries: Object.keys(vault.notes).map((path) => ({ path, is_folder: false, modified: 1, size: 1 })) });
      case "GET /notes":
        return json({ items: Object.keys(vault.notes).map((path) => ({ path, title: path.replace(".md", ""), aliases: [], modified: 1, link: path.replace(".md", "") })) });
      case "GET /tags":
        return json({ tags: { projeto: 1 } });
      case "GET /bookmarks":
        return json({ paths: [] });
      case "GET /note":
        return vault.notes[q("path")] === undefined ? json({}, 404) : json({ path: q("path"), kind: "note", text: vault.notes[q("path")], read_only: null, mtime: 1 });
      case "PUT /note":
        if (vault.conflictOnce && body.base !== undefined) {
          vault.conflictOnce = false;
          vault.notes[body.path] = "texto que veio do disco\n";
          return json({}, 409);
        }
        vault.notes[body.path] = body.text;
        return json({ mtime: 2 });
      case "GET /outgoing":
        return json({ items: [{ name: "Ana", heading: "", target: "Ana.md" }, { name: "Fantasma", heading: "", target: null }] });
      case "GET /backlinks":
        return json({ items: q("path") === "Ana.md" ? [{ path: "Inicio.md", title: "Inicio", contexts: [{ line: 2, text: "Veja [[Ana]]" }] }] : [] });
      case "GET /properties":
        return json({ has_frontmatter: false, items: [] });
      case "GET /resolve":
        return json({ path: q("name") === "Ana" ? "Ana.md" : null });
      case "POST /task": {
        const lines = vault.notes[body.path]!.split("\n");
        lines[body.line] = lines[body.line]!.replace("[ ]", "[x]");
        vault.notes[body.path] = lines.join("\n");
        return json({ text: vault.notes[body.path], mtime: 3 });
      }
      case "POST /merge":
        return json({ kind: "merged", text: `${body.mine}+${body.theirs}` });
      case "POST /recover":
        return json({ saved: "x" });
      case "GET /recent":
        return json({ items: Object.keys(vault.notes).map((path) => ({ path, title: path.replace(".md", ""), modified: 1 })) });
      case "GET /graph":
        return json({ nodes: [], edges: [] });
      case "POST /rename/preview":
        return json({ id: "p1", from: body.from, to: body.to, is_folder: false, is_complete: true, link_count: 2, file_count: 1, skipped: [], drawings: [], edits: [{ path: "Inicio.md", count: 2 }] });
      case "POST /rename/apply":
        vault.notes[body.to] = vault.notes[body.from]!;
        delete vault.notes[body.from];
        return json({ ok: true, path: body.to });
      default:
        return json({ error: `unhandled ${route}` }, 404);
    }
  }) as typeof fetch;
}

let bus: FeatureBus;
const navigate = vi.fn();

function Harness({ vault }: { vault: Vault }) {
  const [b] = useState(() => (bus = createFeatureBus()));
  return (
    <ShellContext.Provider value={{ info, bus: b, fetchImpl: sidecar(vault), session: {} as never, draft: "", setDraft: () => {}, focusComposer: false, navigate }}>
      <BrainTab />
    </ShellContext.Provider>
  );
}

const fresh = (over: Partial<Vault> = {}): Vault => ({
  notes: { "Inicio.md": "# Inicio\n\nVeja [[Ana]] e [[Fantasma]].\n\n- [ ] fazer\n", "Ana.md": "# Ana\n\nTexto da Ana.\n" },
  configured: true,
  conflictOnce: false,
  calls: [],
  ...over,
});

beforeEach(() => {
  localStorage.clear();
  navigate.mockReset();
});

describe("Brain tab against a fake sidecar", () => {
  it("says so when the brain is not configured", async () => {
    render(<Harness vault={fresh({ configured: false })} />);
    expect(await screen.findByText(/O brain não está configurado/)).toBeInTheDocument();
  });

  it("starts on the overview with the note count, lists recents and opens a note from the tree", async () => {
    render(<Harness vault={fresh()} />);
    expect(await screen.findByText("2 notas")).toBeInTheDocument();
    await userEvent.click(screen.getByRole("button", { name: "Lista" }));
    expect(await screen.findByText("Recentes")).toBeInTheDocument();
    await userEvent.click(within(screen.getByRole("tree")).getByText("Inicio"));
    expect(await screen.findByRole("heading", { level: 1, name: "Inicio" })).toBeInTheDocument();
    expect(screen.getByRole("tab", { name: "Inicio", selected: true })).toBeInTheDocument();
  });

  it("follows a wikilink, marks the missing one, and offers to create it", async () => {
    const vault = fresh();
    render(<Harness vault={vault} />);
    await userEvent.click(await screen.findByText("Inicio"));
    const missing = await screen.findByRole("link", { name: "Fantasma" });
    await waitFor(() => expect(missing).toHaveAttribute("title", "Nota que ainda não existe; clique para criar"));
    await userEvent.click(screen.getByRole("link", { name: "Ana" }));
    expect(await screen.findByText("Texto da Ana.")).toBeInTheDocument();
    await userEvent.click(screen.getByRole("button", { name: /Backlinks/ }));
    expect(await screen.findByText("Veja [[Ana]]")).toBeInTheDocument();
    await userEvent.click(screen.getByRole("button", { name: "Voltar" }));
    await userEvent.click(await screen.findByRole("link", { name: "Fantasma" }));
    expect(await screen.findByText("A nota “Fantasma” ainda não existe")).toBeInTheDocument();
  });

  it("toggles a task checkbox by writing the file through the sidecar", async () => {
    const vault = fresh();
    render(<Harness vault={vault} />);
    await userEvent.click(await screen.findByText("Inicio"));
    await userEvent.click(await screen.findByRole("checkbox"));
    await waitFor(() => expect(vault.notes["Inicio.md"]).toContain("- [x] fazer"));
    expect(vault.calls.find((c) => c.path === "/api/brain/task")?.body).toEqual({ path: "Inicio.md", line: 4, expected: "- [ ] fazer" });
  });

  it("edits with Ctrl+E and autosaves after the pause", async () => {
    const vault = fresh();
    render(<Harness vault={vault} />);
    await userEvent.click(await screen.findByText("Inicio"));
    await screen.findByRole("heading", { level: 1, name: "Inicio" });
    await userEvent.keyboard("{Control>}e{/Control}");
    const area = await screen.findByRole("textbox", { name: "Texto da nota" });
    await userEvent.type(area, " mais");
    expect(vault.notes["Inicio.md"]).not.toContain("mais");
    await waitFor(() => expect(vault.notes["Inicio.md"]).toContain("mais"), { timeout: 2500 });
    const put = vault.calls.filter((c) => c.method === "PUT").at(-1)!;
    expect(put.body.base).toBe("# Inicio\n\nVeja [[Ana]] e [[Fantasma]].\n\n- [ ] fazer\n");
  });

  it("shows the conflict banner when the disk changed, and merges", async () => {
    const vault = fresh({ conflictOnce: true });
    render(<Harness vault={vault} />);
    await userEvent.click(await screen.findByText("Inicio"));
    await screen.findByRole("heading", { level: 1, name: "Inicio" });
    await userEvent.keyboard("{Control>}e{/Control}");
    await userEvent.type(await screen.findByRole("textbox", { name: "Texto da nota" }), "!");
    expect(await screen.findByText(/Esta nota mudou no disco/, undefined, { timeout: 2500 })).toBeInTheDocument();
    await userEvent.click(screen.getByRole("button", { name: "Mesclar" }));
    await waitFor(() => expect((screen.getByRole("textbox", { name: "Texto da nota" }) as HTMLTextAreaElement).value).toContain("+texto que veio do disco"));
    expect(screen.queryByText(/Esta nota mudou no disco/)).not.toBeInTheDocument();
  });

  it("reloads silently when the file changes on disk and nothing was edited", async () => {
    const vault = fresh();
    render(<Harness vault={vault} />);
    await userEvent.click(await screen.findByText("Ana"));
    await screen.findByText("Texto da Ana.");
    vault.notes["Ana.md"] = "# Ana\n\nTexto novo vindo do agente.\n";
    act(() => bus.emit({ feature: "brain", type: "changed", paths: ["Ana.md"] }));
    expect(await screen.findByText("Texto novo vindo do agente.")).toBeInTheDocument();
  });

  it("previews a rename with the link count and applies it", async () => {
    const vault = fresh();
    render(<Harness vault={vault} />);
    await userEvent.click(await screen.findByText("Ana"));
    await screen.findByText("Texto da Ana.");
    await userEvent.click(screen.getByRole("button", { name: "Mais ações" }));
    await userEvent.click(screen.getByRole("menuitem", { name: "Renomear ou mover…" }));
    const field = await screen.findByRole("textbox", { name: "pasta/nome" });
    await userEvent.clear(field);
    await userEvent.type(field, "gente/Ana Maria");
    await userEvent.click(screen.getByRole("button", { name: "Confirmar" }));
    expect(await screen.findByText(/muda 2 links em 1 nota/)).toBeInTheDocument();
    expect(vault.calls.find((c) => c.path === "/api/brain/rename/preview")?.body).toEqual({ from: "Ana.md", to: "gente/Ana Maria.md" });
    await userEvent.click(screen.getByRole("button", { name: "Mover e atualizar" }));
    await waitFor(() => expect(vault.notes["gente/Ana Maria.md"]).toBeDefined());
    expect(await screen.findByRole("tab", { name: "gente/Ana Maria".split("/")[1]! })).toBeInTheDocument();
  });

  it("opens the note and line handed over by the Tarefas tab", async () => {
    localStorage.setItem("wisp.brain.open", JSON.stringify({ path: "Inicio.md", line: 4 }));
    render(<Harness vault={fresh()} />);
    expect(await screen.findByRole("heading", { level: 1, name: "Inicio" })).toBeInTheDocument();
    expect(localStorage.getItem("wisp.brain.open")).toBeNull();
  });

  it("switches notes with Ctrl+O", async () => {
    render(<Harness vault={fresh()} />);
    await screen.findByText("2 notas");
    await userEvent.keyboard("{Control>}o{/Control}");
    const field = await screen.findByRole("textbox", { name: "Ir para uma nota" });
    await userEvent.type(field, "ana{Enter}");
    expect(await screen.findByText("Texto da Ana.")).toBeInTheDocument();
  });
});
