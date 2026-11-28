import { screen, waitFor, within } from "@testing-library/react";
import userEvent from "@testing-library/user-event";
import { AutomationsPane } from "./AutomationsPane";
import { baseState, renderWith } from "./testkit";

const routines = {
  available: true,
  running: 1,
  rows: [
    { label: "ai.wisp.bot", name: "bot", description: "sempre ligado", summary: "rodando · saída 0", state: "running", installed: true, logs: ["C:/l/bot.log", "C:/l/err.log"], always_on: true },
    { label: "ai.wisp.news", name: "news", description: "todo dia 07:00", summary: "desligado", state: "unloaded", installed: true, logs: [], always_on: false },
    { label: "ai.wisp.gone", name: "gone", description: null, summary: "tarefa não instalada", state: "missing", installed: false, logs: [], always_on: false },
  ],
};
const hooks = {
  available: true, count: 3, locked: 1, can_disable: true, can_enable: true,
  groups: [
    { event: "SessionStart", title: "Início da sessão", hooks: [{ id: "a", event: "SessionStart", title: "boot.py", detail: "carrega o brain", command: "boot", enabled: true, locked: false, missing: false }] },
    { event: "PreToolUse", title: "Antes de cada ferramenta", hooks: [
      { id: "g", event: "PreToolUse", title: "guard.py", detail: null, command: "guard", enabled: true, locked: true, missing: false },
      { id: "h", event: "PreToolUse", title: "extra.py", detail: null, command: "extra", enabled: false, locked: false, missing: true },
    ] },
  ],
};
const routes = {
  "GET /api/settings/routines": () => routines,
  "GET /api/settings/hooks": () => hooks,
  "GET /api/settings/commands": () => ({ available: true, entries: [{ name: "go.cmd", detail: "Roda o fluxo", path: "C:/c/go.cmd" }] }),
  "GET /api/settings/mcp": () => ({ engine: "claude", servers: [{ name: "wisp-brain", scope: "usuário", transport: "stdio · wisp", installed_by_wisp: true, disabled: false }, { name: "old", scope: "projeto", transport: "http · a.example", installed_by_wisp: false, disabled: true }] }),
  "GET /api/settings/clis": () => ({ installed: [{ name: "git", directory: "C:/Git/cmd", version: "git version 2", auth: null }, { name: "gh", directory: "~/bin", version: "gh 2.4", auth: "logado" }], missing: ["aws", "docker"] }),
};
const open = async (name: string) => userEvent.click(await screen.findByRole("button", { name: new RegExp(`^${name}`) }));

describe("Automações", () => {
  it("is one card with the Mac's six rows and the count of each", async () => {
    renderWith(routes, <AutomationsPane state={baseState()} />);
    const titles = ["Integrações", "Rotinas", "Hooks", "Comandos", "MCP", "CLIs"];
    for (const title of titles) expect(screen.getByRole("button", { name: new RegExp(`^${title}`) })).toBeInTheDocument();
    expect(await screen.findByRole("button", { name: /^Rotinas.*1 rodando · 3/ })).toBeInTheDocument();
    expect(await screen.findByRole("button", { name: /^Hooks.*3 · 1 trava/ })).toBeInTheDocument();
    expect(await screen.findByRole("button", { name: /^MCP.*2/ })).toBeInTheDocument();
    expect(await screen.findByRole("button", { name: /^CLIs.*2/ })).toBeInTheDocument();
  });

  it("hides Rotinas, Hooks and Comandos when the profile has no such block, like the Mac", () => {
    renderWith(routes, <AutomationsPane state={baseState({ blocks: { routines: false, hooks: false, commands: false } })} />);
    expect(screen.queryByRole("button", { name: /^Rotinas/ })).not.toBeInTheDocument();
    expect(screen.queryByRole("button", { name: /^Hooks/ })).not.toBeInTheDocument();
    expect(screen.getAllByRole("button").map((b) => b.textContent?.replace(/[0-9›].*/, ""))).toEqual(["Integrações", "MCP", "CLIs"]);
  });

  it("Integrações sends you to the tab that owns the connection", async () => {
    const navigate = vi.fn();
    renderWith(routes, <AutomationsPane state={baseState()} />, navigate);
    await open("Integrações");
    await userEvent.click(screen.getByRole("button", { name: "Abrir Música" }));
    await userEvent.click(screen.getByRole("button", { name: "Abrir Agenda" }));
    expect(navigate.mock.calls).toEqual([["music"], ["agenda"]]);
  });

  it("Rotinas shows each state, never offers Ligar on an uninstalled task", async () => {
    renderWith(routes, <AutomationsPane state={baseState()} />);
    await open("Rotinas");
    expect(await screen.findByText("rodando · saída 0")).toBeInTheDocument();
    expect(screen.getByText("tarefa não instalada")).toBeInTheDocument();
    const toggles = screen.getAllByRole("button").filter((b) => ["Desligar", "Ligar"].includes(b.textContent ?? ""));
    expect(toggles.map((b) => b.textContent)).toEqual(["Desligar", "Ligar"]);
  });

  it("Desligar asks first, then posts the label", async () => {
    const view = renderWith({ ...routes, "POST /api/settings/routines/toggle": () => ({ ok: true }) }, <AutomationsPane state={baseState()} />);
    await open("Rotinas");
    await userEvent.click(await screen.findByRole("button", { name: "Desligar" }));
    expect(screen.getByText("Desligar bot?")).toBeInTheDocument();
    expect(view.posts("/api/settings/routines/toggle")).toHaveLength(0);
    await userEvent.click(screen.getByRole("button", { name: "Sim" }));
    await waitFor(() => expect(view.posts("/api/settings/routines/toggle")[0]?.body).toEqual({ label: "ai.wisp.bot", on: false }));
  });

  it("a refused toggle shows the reason under that routine only", async () => {
    renderWith({ ...routes, "POST /api/settings/routines/toggle": () => ({ ok: false, error: "Não consegui ligar news: Acesso negado" }) }, <AutomationsPane state={baseState()} />);
    await open("Rotinas");
    await userEvent.click(await screen.findByRole("button", { name: "Ligar" }));
    await userEvent.click(screen.getByRole("button", { name: "Sim" }));
    expect(await screen.findByText("Não consegui ligar news: Acesso negado")).toBeInTheDocument();
  });

  it("Log opens the tail of the routine's log, switches files and goes back", async () => {
    const log = vi.fn((_: unknown) => ({ ok: true, lines: ["a", "b"], path: "C:/l/bot.log", paths: [] }));
    const view = renderWith({ ...routes, "GET /api/settings/routines/log": log }, <AutomationsPane state={baseState()} />);
    await open("Rotinas");
    await userEvent.click(await screen.findByRole("button", { name: "Log" }));
    expect(await screen.findByText(/a\s*b/)).toBeInTheDocument();
    await userEvent.click(screen.getByRole("button", { name: "err.log" }));
    await waitFor(() => expect(view.calls.filter((c) => c.path === "/api/settings/routines/log")).toHaveLength(2));
    await userEvent.click(screen.getByRole("button", { name: "Voltar às rotinas" }));
    expect(await screen.findByText("tarefa não instalada")).toBeInTheDocument();
  });

  it("a log that does not exist yet says where it would be", async () => {
    renderWith({ ...routes, "GET /api/settings/routines/log": () => ({ ok: false, error: "Este log ainda não existe: C:/l/bot.log" }) }, <AutomationsPane state={baseState()} />);
    await open("Rotinas");
    await userEvent.click(await screen.findByRole("button", { name: "Log" }));
    expect(await screen.findByText("Este log ainda não existe: C:/l/bot.log")).toBeInTheDocument();
  });

  it("Hooks are grouped by moment, safety hooks show a lock and have no switch", async () => {
    renderWith(routes, <AutomationsPane state={baseState()} />);
    await open("Hooks");
    expect(await screen.findByText("Início da sessão")).toBeInTheDocument();
    expect(screen.getByText("Antes de cada ferramenta")).toBeInTheDocument();
    expect(screen.getByText("🔒 trava")).toBeInTheDocument();
    expect(screen.getByText("script ausente")).toBeInTheDocument();
    const guardRow = screen.getByText("guard.py").closest("div")!.parentElement!;
    expect(within(guardRow).queryByRole("button")).not.toBeInTheDocument();
  });

  it("Ligar a disabled hook posts its id with on: true", async () => {
    const view = renderWith({ ...routes, "POST /api/settings/hooks/toggle": () => ({ ok: true }) }, <AutomationsPane state={baseState()} />);
    await open("Hooks");
    const row = (await screen.findByText("extra.py")).closest("div")!.parentElement!;
    await userEvent.click(within(row).getByRole("button", { name: "Ligar" }));
    await userEvent.click(screen.getByRole("button", { name: "Sim" }));
    await waitFor(() => expect(view.posts("/api/settings/hooks/toggle")[0]?.body).toEqual({ id: "h", on: true }));
  });

  it("Comandos list names with the first comment", async () => {
    renderWith(routes, <AutomationsPane state={baseState()} />);
    await open("Comandos");
    expect(await screen.findByText("go.cmd")).toBeInTheDocument();
    expect(screen.getByText("Roda o fluxo")).toBeInTheDocument();
  });

  it("MCP names the engine, marks disabled servers and promises no secrets", async () => {
    renderWith(routes, <AutomationsPane state={baseState()} />);
    await open("MCP");
    expect(await screen.findByText(/Servidores que o motor Claude enxerga/)).toBeInTheDocument();
    expect(screen.getByText("stdio · wisp · usuário · instalado pelo Wisp")).toBeInTheDocument();
    expect(screen.getByText("desativado")).toBeInTheDocument();
    expect(screen.getByText("configurado")).toBeInTheDocument();
  });

  it("CLIs show version, directory and login, fold the missing ones and rescan on Atualizar", async () => {
    const view = renderWith(routes, <AutomationsPane state={baseState()} />);
    await open("CLIs");
    expect(await screen.findByText("gh 2.4 · ~/bin")).toBeInTheDocument();
    expect(screen.getByText("logado")).toBeInTheDocument();
    expect(screen.queryByText("aws, docker")).not.toBeInTheDocument();
    await userEvent.click(screen.getByRole("button", { name: "Não encontradas (2)" }));
    expect(screen.getByText("aws, docker")).toBeInTheDocument();
    await userEvent.click(screen.getByRole("button", { name: "Atualizar" }));
    await waitFor(() => expect(view.calls.filter((c) => c.path === "/api/settings/clis").length).toBeGreaterThanOrEqual(3));
  });
});
