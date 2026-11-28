import { act, render, screen, waitFor, within } from "@testing-library/react";
import userEvent from "@testing-library/user-event";
import { beforeAll, describe, expect, it } from "vitest";
import { buildStore, type Preferences, type TerminalStore } from "./store";
import { b64, headlessEngine, ScriptedBackend } from "./testSupport";
import { TerminalView } from "./TerminalView";

beforeAll(() => {
  globalThis.ResizeObserver ??= class {
    observe() {}
    unobserve() {}
    disconnect() {}
  };
  Object.assign(navigator, { clipboard: { writeText: async () => undefined } });
});

const prefs: Preferences = {
  shell: () => "pwsh",
  setShell: () => {},
  hooks: () => true,
  nativeBlocks: () => true,
  tabsCollapsed: () => false,
  setTabsCollapsed: () => {},
};

function setup() {
  const backend = new ScriptedBackend();
  backend.folders["C:\\work"] = [
    { name: "src", isDir: true },
    { name: "readme.md", isDir: false },
  ];
  backend.programs = ["node"];
  const store = buildStore({
    backend,
    createEngine: (size) => headlessEngine({ cols: Math.min(size.cols, 40), rows: 8 }),
    prefs,
    home: "C:\\Users\\dev",
    shells: [
      { id: "pwsh", label: "PowerShell 7" },
      { id: "cmd", label: "Prompt de Comando" },
    ],
    storage: { load: () => "C:\\work", save: () => {} },
  });
  store.workspace.openFirstIfNeeded();
  return { backend, store };
}

const prompt = (b: ScriptedBackend) => b.mark("cwd=file:///C:/work") + b.mark("A") + "PS C:\\work> " + b.mark("B");
const spawned = () => act(() => new Promise<void>((r) => setTimeout(r, 0)));
async function ready(store: TerminalStore, backend: ScriptedBackend) {
  await spawned();
  await act(async () => {
    backend.output(prompt(backend));
    await store.workspace.selected!.whenIdle();
  });
}

describe("TerminalView", () => {
  it("shows the tab list with Nova aba, the tab, its folder and the editor", async () => {
    const { backend, store } = setup();
    render(<TerminalView store={store} />);
    await ready(store, backend);
    const tabs = screen.getByRole("navigation", { name: "Abas do terminal" });
    expect(within(tabs).getByText("Nova aba")).toBeInTheDocument();
    expect(within(tabs).getByText("work")).toBeInTheDocument();
    expect(screen.getByLabelText("Linha de comando")).toHaveAttribute("placeholder", "Digite um comando (⇧↩ para nova linha)");
  });

  it("runs the line typed in the editor and shows the command as a block with its output", async () => {
    const { backend, store } = setup();
    const user = userEvent.setup();
    render(<TerminalView store={store} />);
    await ready(store, backend);
    await user.type(screen.getByLabelText("Linha de comando"), "echo oi{Enter}");
    expect(backend.writes).toEqual(["\x1becho oi\r"]);
    await act(async () => {
      backend.output(backend.mark(`cmd=${b64("echo oi")}`) + backend.mark("C") + "\r\noi\r\n");
      await store.workspace.selected!.whenIdle();
    });
    expect(screen.getByLabelText("Linha de comando")).toBeDisabled();
    await act(async () => {
      backend.output(backend.mark("D;0") + prompt(backend));
      await store.workspace.selected!.whenIdle();
    });
    const block = within(screen.getByTestId("blocks")).getByRole("article");
    expect(within(block).getByText("echo oi")).toBeInTheDocument();
    expect(within(block).getByText("oi")).toBeInTheDocument();
    expect(within(block).getByLabelText("Terminou")).toBeInTheDocument();
    expect(screen.getByLabelText("Linha de comando")).toBeEnabled();
  });

  it("Tab completes a file name, shows several as a menu", async () => {
    const { backend, store } = setup();
    const user = userEvent.setup();
    render(<TerminalView store={store} />);
    await ready(store, backend);
    const input = screen.getByLabelText("Linha de comando");
    await user.type(input, "type re");
    await user.keyboard("{Tab}");
    await waitFor(() => expect(input).toHaveValue("type re"));
    await user.keyboard("{Tab}");
    await waitFor(() => expect(input).toHaveValue("type readme.md "));
  });

  it("the up arrow brings back what was run, and Ctrl+R searches the history", async () => {
    const { backend, store } = setup();
    store.history.append("git status");
    store.history.append("dir");
    const user = userEvent.setup();
    render(<TerminalView store={store} />);
    await ready(store, backend);
    const input = screen.getByLabelText("Linha de comando");
    await user.click(input);
    await user.keyboard("{ArrowUp}");
    expect(input).toHaveValue("dir");
    await user.keyboard("{ArrowUp}");
    expect(input).toHaveValue("git status");
    await user.keyboard("{ArrowDown}{ArrowDown}");
    expect(input).toHaveValue("");
    await user.keyboard("{Control>}r{/Control}gi");
    expect(screen.getByRole("listbox", { name: "Ctrl+R gi" })).toBeInTheDocument();
    await user.keyboard("{Enter}");
    expect(input).toHaveValue("git status");
  });

  it("Ctrl+C with nothing selected interrupts the command", async () => {
    const { backend, store } = setup();
    const user = userEvent.setup();
    render(<TerminalView store={store} />);
    await ready(store, backend);
    await user.click(screen.getByLabelText("Linha de comando"));
    await user.keyboard("{Control>}c{/Control}");
    expect(backend.writes).toContain("\x03");
  });

  it("Ctrl+Shift+T opens another tab and Ctrl+1 goes back to the first", async () => {
    const { backend, store } = setup();
    const user = userEvent.setup();
    render(<TerminalView store={store} />);
    await ready(store, backend);
    await user.click(screen.getByLabelText("Linha de comando"));
    await user.keyboard("{Control>}{Shift>}t{/Shift}{/Control}");
    expect(store.workspace.layout.tabs).toHaveLength(2);
    await user.keyboard("{Control>}1{/Control}");
    expect(store.workspace.layout.selectedTabId).toBe(store.workspace.layout.tabs[0]!.id);
  });

  it("splits the pane with Ctrl+Shift+D and closes it with Ctrl+Shift+W", async () => {
    const { backend, store } = setup();
    const user = userEvent.setup();
    render(<TerminalView store={store} />);
    await ready(store, backend);
    await user.click(screen.getByLabelText("Linha de comando"));
    await user.keyboard("{Control>}{Shift>}d{/Shift}{/Control}");
    expect(store.workspace.layout.selectedTab!.sessions).toHaveLength(2);
    expect(screen.getAllByRole("separator")).toHaveLength(1);
    await user.keyboard("{Control>}{Shift>}w{/Shift}{/Control}");
    expect(store.workspace.layout.selectedTab!.sessions).toHaveLength(1);
  });

  it("closing the last tab leaves the empty state with Nova sessão", async () => {
    const { backend, store } = setup();
    const user = userEvent.setup();
    render(<TerminalView store={store} />);
    await ready(store, backend);
    await user.click(screen.getByRole("button", { name: "Fechar aba" }));
    expect(screen.getByText("Nenhuma sessão aberta")).toBeInTheDocument();
    await user.click(screen.getByRole("button", { name: "Nova sessão" }));
    expect(store.workspace.layout.tabs).toHaveLength(1);
  });

  it("shows the Reabrir bar when the shell ends", async () => {
    const { backend, store } = setup();
    render(<TerminalView store={store} />);
    await ready(store, backend);
    await act(async () => {
      backend.exit(2);
      await store.workspace.selected!.whenIdle();
    });
    expect(screen.getByText("Código de saída 2")).toBeInTheDocument();
    expect(screen.getByRole("button", { name: "Reabrir" })).toBeInTheDocument();
  });
});
