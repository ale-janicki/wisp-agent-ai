import { render, screen, waitFor, within } from "@testing-library/react";
import userEvent from "@testing-library/user-event";
import { useState } from "react";
import { createFeatureBus } from "../../api/featureEvents";
import { ShellContext } from "../../shell/context";
import { fakeFetch } from "../../test/fakes";
import { filterGroups, urgentFirst, type TaskGroup } from "./filter";
import { TasksTab } from "./TasksTab";

const info = { port: 4242, token: "tok" };

const item = (over: Partial<TaskGroup["items"][number]>) => ({
  line: "- x", occurrence: 0, index: 0, owner: null, front: null, title: "x", detail: "", urgent: false, alert_id: null, ...over,
});

const groups: TaskGroup[] = [
  {
    title: "Frente A",
    items: [
      item({ line: "- a", index: 4, owner: "Ana", front: "Projeto", title: "Entregar relatório", detail: "revisar com o time" }),
      item({ line: "- b", index: 5, title: "Pagar a conta", urgent: true }),
    ],
  },
  { title: null, items: [item({ line: "- c", index: 8, title: "Ligar para o João" })] },
];

function Harness({ routes, navigate = () => {} }: { routes: Record<string, (body: unknown) => unknown>; navigate?: (id: string) => void }) {
  const { impl, calls } = fakeFetch(routes);
  const [bus] = useState(createFeatureBus);
  (globalThis as { __calls?: typeof calls }).__calls = calls;
  return (
    <ShellContext.Provider
      value={{ info, bus, fetchImpl: impl, session: {} as never, draft: "", setDraft: () => {}, focusComposer: false, navigate }}
    >
      <TasksTab />
    </ShellContext.Provider>
  );
}

describe("task filtering", () => {
  it("matches every word, ignoring case and accents, across owner, front, title and detail", () => {
    expect(filterGroups(groups, "relatorio ana")[0]?.items.map((i) => i.line)).toEqual(["- a"]);
    expect(filterGroups(groups, "joao")).toEqual([{ title: null, items: [groups[1]!.items[0]] }]);
    expect(filterGroups(groups, "zzz")).toEqual([]);
    expect(filterGroups(groups, "  ")).toBe(groups);
  });
  it("puts urgent tasks first inside each group", () => {
    expect(urgentFirst(groups)[0]?.items.map((i) => i.line)).toEqual(["- b", "- a"]);
  });
});

describe("Tarefas tab against a fake sidecar", () => {
  const list = () => ({ configured: true, file: "pendencias.md", brain_path: "pendencias.md", groups, open_count: 3 });

  it("lists open tasks with the count, urgent first, and filters by the search box", async () => {
    render(<Harness routes={{ "GET /api/tasks/list": list }} />);
    expect(await screen.findByText("Entregar relatório")).toBeInTheDocument();
    expect(screen.getByText("3 em aberto")).toBeInTheDocument();
    expect(screen.getByText("Frente A")).toBeInTheDocument();
    expect(screen.getByText("Ana")).toBeInTheDocument();
    expect(screen.getByText("Projeto · revisar com o time")).toBeInTheDocument();
    const rows = screen.getAllByRole("listitem").map((r) => r.textContent ?? "");
    expect(rows[0]).toContain("Pagar a conta");
    await userEvent.type(screen.getByRole("searchbox", { name: "Buscar tarefas" }), "joao");
    expect(screen.queryByText("Entregar relatório")).not.toBeInTheDocument();
    expect(screen.getByText("Ligar para o João")).toBeInTheDocument();
    await userEvent.clear(screen.getByRole("searchbox", { name: "Buscar tarefas" }));
    await userEvent.type(screen.getByRole("searchbox", { name: "Buscar tarefas" }), "nada");
    expect(screen.getByText("Nenhuma tarefa com “nada”")).toBeInTheDocument();
  });

  it("says when there is nothing open, when no file is set and when the file cannot be read", async () => {
    const empty = render(<Harness routes={{ "GET /api/tasks/list": () => ({ configured: true, file: "p.md", groups: [], open_count: 0 }) }} />);
    expect(await screen.findByText("Nada em aberto")).toBeInTheDocument();
    empty.unmount();
    const unset = render(<Harness routes={{ "GET /api/tasks/list": () => ({ configured: false, groups: [], open_count: 0 }) }} />);
    expect(await screen.findByText(/Nenhum arquivo de tarefas/)).toBeInTheDocument();
    unset.unmount();
    render(<Harness routes={{}} />);
    expect(await screen.findByText("Não consegui ler as tarefas")).toBeInTheDocument();
  });

  it("completes a task through the sidecar and reloads the list", async () => {
    let open = groups;
    render(
      <Harness
        routes={{
          "GET /api/tasks/list": () => ({ configured: true, file: "p.md", groups: open, open_count: open.reduce((n, g) => n + g.items.length, 0) }),
          "POST /api/tasks/complete": () => {
            open = [{ ...groups[0]!, items: [groups[0]!.items[0]!] }, groups[1]!];
            return { ok: true };
          },
        }}
      />,
    );
    await screen.findByText("Pagar a conta");
    const row = screen.getByText("Pagar a conta").closest("li")!;
    await userEvent.click(within(row).getByRole("button", { name: "Marcar como feita" }));
    await waitFor(() => expect(screen.queryByText("Pagar a conta")).not.toBeInTheDocument());
    const calls = (globalThis as { __calls?: { method: string; path: string; body: unknown }[] }).__calls!;
    expect(calls.find((c) => c.path === "/api/tasks/complete")?.body).toEqual({ line: "- b", occurrence: 0 });
    expect(screen.getByText("2 em aberto")).toBeInTheDocument();
  });

  it("asks before deleting and reports a line that changed", async () => {
    render(
      <Harness
        routes={{
          "GET /api/tasks/list": list,
          "POST /api/tasks/complete": () => {
            throw new Error("boom");
          },
        }}
      />,
    );
    await screen.findByText("Pagar a conta");
    const row = screen.getByText("Pagar a conta").closest("li")!;
    await userEvent.click(within(row).getByRole("button", { name: "Apagar tarefa" }));
    expect(within(row).getByText("Apagar?")).toBeInTheDocument();
    await userEvent.click(within(row).getByRole("button", { name: "Confirmar" }));
    expect(await screen.findByText(/Não consegui marcar como feito/)).toBeInTheDocument();
  });

  it("opens the source in the Brain tab when the file lives inside the brain", async () => {
    const navigate = vi.fn();
    localStorage.removeItem("wisp.brain.open");
    render(<Harness navigate={navigate} routes={{ "GET /api/tasks/list": list }} />);
    await userEvent.click(await screen.findByText("Entregar relatório"));
    expect(navigate).toHaveBeenCalledWith("brain");
    expect(JSON.parse(localStorage.getItem("wisp.brain.open")!)).toEqual({ path: "pendencias.md", line: 4 });
  });
});
