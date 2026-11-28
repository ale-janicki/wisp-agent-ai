import { act, render, screen, waitFor } from "@testing-library/react";
import userEvent from "@testing-library/user-event";
import { useState } from "react";
import { FakeEventSource, fakeFetch } from "../../test/fakes";
import { WispSession } from "../../WispSession";
import { ShellContext } from "../../shell/context";
import { ConversaTab } from "./ConversaTab";

const info = { port: 4242, token: "tok" };

function Harness({ deps }: { deps: Parameters<typeof WispSession>[0]["deps"] }) {
  const [draft, setDraft] = useState("");
  return (
    <WispSession info={info} deps={deps} onSummary={() => {}}>
      {(session, bus) => (
        <ShellContext.Provider
          value={{ info, bus, session, draft, setDraft, focusComposer: true, navigate: () => {} }}
        >
          <ConversaTab />
        </ShellContext.Provider>
      )}
    </WispSession>
  );
}

beforeEach(() => FakeEventSource.reset());

describe("Conversa against a fake sidecar", () => {
  it("lists conversations, opens one, streams a reply, asks permission and answers it", async () => {
    const { impl, calls } = fakeFetch({
      "GET /conversations": () => ({ items: [{ id: "c1", title: "Primeira", updated_at: "x", engine: "claude" }] }),
      "GET /conversations/c1": () => ({
        id: "c1",
        title: "Primeira",
        messages: [
          { role: "user", blocks: [{ type: "text", text: "lista os arquivos" }] },
          {
            role: "assistant",
            blocks: [
              { type: "text", text: "Vou **listar**." },
              { type: "tool_use", id: "t1", name: "Bash", input: { command: "ls" } },
            ],
          },
          { role: "user", blocks: [{ type: "tool_result", tool_use_id: "t1", content: "a.txt", is_error: false }] },
        ],
      }),
      "POST /conversations/c1/messages": () => undefined,
      "POST /permissions/r1": () => undefined,
    });
    render(<Harness deps={{ fetchImpl: impl, createSource: (u) => new FakeEventSource(u) as unknown as EventSource }} />);
    const es = FakeEventSource.last();
    act(() => es.open());

    await userEvent.click(await screen.findByRole("button", { name: "Primeira" }));
    expect(await screen.findByText("lista os arquivos")).toBeInTheDocument();
    expect(screen.getByText("listar").tagName).toBe("STRONG");

    expect(screen.queryByText("a.txt")).not.toBeInTheDocument();
    await userEvent.click(screen.getByRole("button", { name: /Bash/ }));
    expect(screen.getByText("a.txt")).toBeInTheDocument();

    act(() => {
      es.emit({ conversation_id: "c1", type: "status", state: "thinking" });
      es.emit({ conversation_id: "c1", type: "text_delta", text: "pensando em " });
      es.emit({ conversation_id: "c1", type: "text_delta", text: "algo" });
    });
    expect(screen.getByText("pensando em algo")).toBeInTheDocument();
    expect(screen.getByRole("button", { name: "Parar" })).toBeInTheDocument();

    act(() => es.emit({ conversation_id: "c1", type: "permission_request", request_id: "r1", tool_name: "Write", input: { path: "x.txt" } }));
    expect(screen.getByText(/usar Write/)).toBeInTheDocument();
    expect(screen.getByRole("button", { name: "Permitir" })).toBeDisabled();
    await userEvent.click(screen.getByRole("button", { name: /veja o conteúdo inteiro/ }));
    await userEvent.click(screen.getByRole("button", { name: "Permitir" }));
    await waitFor(() => expect(calls.some((c) => c.path === "/permissions/r1" && (c.body as { allow: boolean }).allow)).toBe(true));
    await waitFor(() => expect(screen.queryByRole("group", { name: "Pedido de permissão" })).not.toBeInTheDocument());
  });

  it("creates a conversation on first send", async () => {
    const { impl, calls } = fakeFetch({
      "GET /conversations": () => ({ items: [] }),
      "POST /conversations": () => ({ id: "new1" }),
      "POST /conversations/new1/messages": () => undefined,
    });
    render(<Harness deps={{ fetchImpl: impl, createSource: (u) => new FakeEventSource(u) as unknown as EventSource }} />);
    expect(await screen.findByText("Nenhuma conversa encontrada")).toBeInTheDocument();
    await userEvent.type(screen.getByPlaceholderText("Pergunte ao Wisp…"), "oi{Enter}");
    await waitFor(() => expect(calls.some((c) => c.path === "/conversations/new1/messages")).toBe(true));
    expect(screen.getByText("oi")).toBeInTheDocument();
  });
});

const sources = { createSource: (u: string) => new FakeEventSource(u) as unknown as EventSource };

function listed(extra: object[] = []) {
  return {
    "GET /conversations": () => ({
      items: [
        { id: "c1", title: "Primeira", updated_at: "x", engine: "claude", preview: "Você: oi" },
        { id: "c2", title: "Receita de bolo", updated_at: "x", engine: "claude", preview: "use fermento" },
        { id: "c3", title: "Velha", updated_at: "x", engine: "claude", closed: true },
        ...extra,
      ],
    }),
  };
}

describe("Conversa list column", () => {
  it("shows the last-message preview, hides closed conversations and finds them by search", async () => {
    const { impl } = fakeFetch(listed());
    render(<Harness deps={{ fetchImpl: impl, ...sources }} />);
    act(() => FakeEventSource.last().open());
    expect(await screen.findByText("Você: oi")).toBeInTheDocument();
    expect(screen.queryByRole("button", { name: /^Velha/ })).not.toBeInTheDocument();

    await userEvent.type(screen.getByRole("searchbox", { name: "Buscar conversa" }), "FERMENTÃO");
    expect(screen.getByText("Nenhuma conversa encontrada")).toBeInTheDocument();
    await userEvent.clear(screen.getByRole("searchbox", { name: "Buscar conversa" }));
    await userEvent.type(screen.getByRole("searchbox", { name: "Buscar conversa" }), "fermento");
    expect(screen.getByRole("button", { name: /^Receita de bolo/ })).toBeInTheDocument();
    expect(screen.queryByRole("button", { name: /^Primeira/ })).not.toBeInTheDocument();

    await userEvent.click(screen.getByRole("button", { name: "Limpar busca" }));
    await userEvent.type(screen.getByRole("searchbox", { name: "Buscar conversa" }), "velha");
    expect(screen.getByText("encerrada")).toBeInTheDocument();
  });

  it("deletes and renames from the list", async () => {
    const { impl, calls } = fakeFetch({
      ...listed(),
      "DELETE /conversations/c2": () => ({ ok: true }),
      "PATCH /conversations/c1": () => ({ id: "c1", title: "Nome novo" }),
    });
    render(<Harness deps={{ fetchImpl: impl, ...sources }} />);
    act(() => FakeEventSource.last().open());
    await screen.findByText("Receita de bolo");

    await userEvent.click(screen.getByRole("button", { name: "Apagar conversa Receita de bolo" }));
    await waitFor(() => expect(screen.queryByText("Receita de bolo")).not.toBeInTheDocument());
    expect(calls.some((c) => c.method === "DELETE" && c.path === "/conversations/c2")).toBe(true);

    await userEvent.dblClick(screen.getByRole("button", { name: /^Primeira/ }));
    const box = screen.getByRole("textbox", { name: "Renomear conversa" });
    await userEvent.clear(box);
    await userEvent.type(box, "Nome novo{Enter}");
    await waitFor(() => expect(screen.getByRole("button", { name: /^Nome novo/ })).toBeInTheDocument());
    expect(calls.find((c) => c.method === "PATCH")?.body).toEqual({ title: "Nome novo" });
  });

  it("marks a conversation that answered while another was open, until it is opened", async () => {
    const { impl } = fakeFetch({
      ...listed(),
      "GET /conversations/c1": () => ({ id: "c1", title: "Primeira", messages: [] }),
      "GET /conversations/c2": () => ({ id: "c2", title: "Receita de bolo", messages: [] }),
    });
    render(<Harness deps={{ fetchImpl: impl, ...sources }} />);
    const es = FakeEventSource.last();
    act(() => es.open());
    await userEvent.click(await screen.findByRole("button", { name: /^Primeira/ }));
    act(() => es.emit({ conversation_id: "c2", type: "result", usage: {}, text: "pronto", is_error: false }));
    expect(screen.getByTitle("Precisa de atenção")).toBeInTheDocument();
    await userEvent.click(screen.getByRole("button", { name: /^Receita de bolo/ }));
    await waitFor(() => expect(screen.queryByTitle("Precisa de atenção")).not.toBeInTheDocument());
  });
});

describe("Conversa chat column", () => {
  it("lets a closed conversation be read and reopened", async () => {
    const { impl, calls } = fakeFetch({
      ...listed(),
      "GET /conversations/c3": () => ({ id: "c3", title: "Velha", messages: [], closed: true }),
      "POST /conversations/c3/reopen": () => ({ ok: true }),
    });
    render(<Harness deps={{ fetchImpl: impl, ...sources }} />);
    act(() => FakeEventSource.last().open());
    await userEvent.type(await screen.findByRole("searchbox", { name: "Buscar conversa" }), "velha");
    await userEvent.click(screen.getByRole("button", { name: /^Velha/ }));
    expect(await screen.findByText("Conversa encerrada — só leitura")).toBeInTheDocument();
    expect(screen.queryByPlaceholderText("Pergunte ao Wisp…")).not.toBeInTheDocument();
    await userEvent.click(screen.getByRole("button", { name: "Reabrir" }));
    expect(await screen.findByPlaceholderText("Pergunte ao Wisp…")).toBeInTheDocument();
    expect(calls.some((c) => c.path === "/conversations/c3/reopen")).toBe(true);
  });

  it("shows system notes, the 5 h usage and a generated title as they arrive", async () => {
    const { impl } = fakeFetch({
      ...listed(),
      "GET /conversations/c1": () => ({ id: "c1", title: "Primeira", messages: [{ role: "user", blocks: [{ type: "text", text: "oi" }] }] }),
    });
    render(<Harness deps={{ fetchImpl: impl, ...sources }} />);
    const es = FakeEventSource.last();
    act(() => es.open());
    await userEvent.click(await screen.findByRole("button", { name: /^Primeira/ }));
    await screen.findByText("oi");
    act(() => {
      es.emit({ conversation_id: "c1", type: "system", text: "a IA local não está pronta (sem modelo); esta conversa roda no Claude. Ajustes > Modelo resolve." });
      es.emit({ conversation_id: "x", type: "usage", five_hour: { utilization: 0.8, resets_at: 4102444800 }, seven_day: null });
      es.emit({ conversation_id: "c1", type: "title", title: "Cumprimento" });
    });
    expect(screen.getByText(/a IA local não está pronta/)).toBeInTheDocument();
    expect(screen.getByRole("status")).toHaveTextContent("Sessão 80%");
    expect(screen.getAllByText("Cumprimento").length).toBeGreaterThan(0);
  });

  it("sends 'Sempre permitir' as always and shows the engine picker, saving the choice", async () => {
    const { impl, calls } = fakeFetch({
      ...listed(),
      "GET /engines": () => ({
        active: "claude",
        engines: [
          { id: "claude", name: "Claude", ready: true, note: null },
          { id: "codex", name: "Codex", ready: false, note: "o Codex não está instalado neste computador; esta conversa roda no Claude" },
          { id: "local", name: "IA local", ready: true, note: null },
        ],
      }),
      "PUT /engines/active": () => ({ active: "local" }),
      "GET /conversations/c1": () => ({ id: "c1", title: "Primeira", messages: [] }),
      "POST /permissions/r9": () => undefined,
    });
    render(<Harness deps={{ fetchImpl: impl, ...sources }} />);
    const es = FakeEventSource.last();
    act(() => es.open());
    await userEvent.click(await screen.findByRole("button", { name: /^Primeira/ }));
    const picker = await screen.findByRole("combobox", { name: "Motor" });
    expect(screen.getByRole("option", { name: "Codex (indisponível)" })).toBeInTheDocument();
    await userEvent.selectOptions(picker, "local");
    await waitFor(() => expect(calls.find((c) => c.method === "PUT")?.body).toEqual({ engine: "local" }));

    act(() =>
      es.emit({
        conversation_id: "c1", type: "permission_request", request_id: "r9", tool_name: "Bash", input: { command: "ls" },
        summary: "rodar ls", detail: "ls", requires_expansion: false, can_persist: true, persist_rules: ["Bash(ls *)"], asker: "Claude",
      }),
    );
    expect(screen.getByText(/O Claude quer/)).toBeInTheDocument();
    await userEvent.click(screen.getByRole("button", { name: "Sempre permitir" }));
    await waitFor(() => expect(calls.find((c) => c.path === "/permissions/r9")?.body).toEqual({ allow: true, always: true }));
  });

  it("queues a second message while the first one runs", async () => {
    const { impl, calls } = fakeFetch({
      ...listed(),
      "GET /conversations/c1": () => ({ id: "c1", title: "Primeira", messages: [] }),
      "POST /conversations/c1/messages": () => undefined,
    });
    render(<Harness deps={{ fetchImpl: impl, ...sources }} />);
    const es = FakeEventSource.last();
    act(() => es.open());
    await userEvent.click(await screen.findByRole("button", { name: /^Primeira/ }));
    act(() => es.emit({ conversation_id: "c1", type: "status", state: "thinking" }));
    await userEvent.type(screen.getByPlaceholderText("Pergunte ao Wisp…"), "e depois{Enter}");
    await waitFor(() => expect(calls.some((c) => c.path === "/conversations/c1/messages")).toBe(true));
    expect(screen.getByRole("button", { name: "Parar" })).toBeInTheDocument();
  });
});

describe("Conversa attachments", () => {
  it("stages a picked file, shows it, sends only the staged path and renders the attachment in the transcript", async () => {
    const staged = { path: "C:\\anexos\\wisp-ab12cd34-nota.txt", name: "wisp-ab12cd34-nota.txt", bytes: 1500, image: false };
    const uploads: string[] = [];
    const base = fakeFetch({
      ...listed(),
      "GET /conversations/c1": () => ({ id: "c1", title: "Primeira", messages: [] }),
      "POST /conversations/c1/messages": () => undefined,
    });
    const impl = (async (input: RequestInfo | URL, init?: RequestInit) => {
      const url = new URL(String(input));
      if (url.pathname === "/attachments" && init?.method === "PUT") {
        uploads.push(url.searchParams.get("name") ?? "");
        expect(new Headers(init.headers).get("Authorization")).toBe("Bearer tok");
        return new Response(JSON.stringify({ files: [staged], refused: [], notice: null }), { status: 200 });
      }
      return base.impl(input, init);
    }) as typeof fetch;
    render(<Harness deps={{ fetchImpl: impl, ...sources }} />);
    act(() => FakeEventSource.last().open());
    await userEvent.click(await screen.findByRole("button", { name: /^Primeira/ }));

    await userEvent.upload(screen.getByTestId("file-picker"), new File(["x"], "nota.txt"));
    expect(await screen.findByText("nota.txt")).toBeInTheDocument();
    expect(uploads).toEqual(["nota.txt"]);

    await userEvent.type(screen.getByPlaceholderText("Pergunte ao Wisp…"), "leia isso{Enter}");
    await waitFor(() => expect(base.calls.some((c) => c.path === "/conversations/c1/messages")).toBe(true));
    expect(base.calls.find((c) => c.path === "/conversations/c1/messages")?.body).toEqual({ text: "leia isso", attachments: [staged.path] });
    expect(await screen.findByText("leia isso")).toBeInTheDocument();
    expect(screen.getByText("1,5 KB")).toBeInTheDocument();
    expect(screen.queryByText(/C:\\anexos/)).not.toBeInTheDocument();
    expect(screen.queryByRole("button", { name: /Remover/ })).not.toBeInTheDocument();
  });
});
