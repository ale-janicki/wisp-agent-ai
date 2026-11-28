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
    expect(screen.getByText("Write")).toBeInTheDocument();
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
