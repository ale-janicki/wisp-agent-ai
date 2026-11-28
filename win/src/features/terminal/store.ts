import type { TerminalBackend } from "./backend";
import { CompletionSource } from "./completionSource";
import { CommandHistory, parseHistory } from "./history";
import type { ShellId } from "./shellIntegration";
import { TerminalSession, type Engine } from "./session";
import { TerminalWorkspace } from "./workspace";

const KEY_SHELL = "wisp.terminal.shell";
const KEY_HOOKS = "wisp.terminal.hooks";
const KEY_NATIVE = "wisp.terminal.nativeBlocks";
const KEY_DIRECTORY = "wisp.terminal.directory";
const KEY_TABS = "wisp.terminal.tabsCollapsed";

const SHELL_IDS: readonly ShellId[] = ["pwsh", "powershell", "cmd"];

export type Preferences = {
  shell: () => ShellId | null;
  setShell: (shell: ShellId) => void;
  hooks: () => boolean;
  nativeBlocks: () => boolean;
  tabsCollapsed: () => boolean;
  setTabsCollapsed: (collapsed: boolean) => void;
};

const read = (key: string): string | null => {
  try {
    return window.localStorage.getItem(key);
  } catch {
    return null;
  }
};
const write = (key: string, value: string): void => {
  try {
    window.localStorage.setItem(key, value);
  } catch {
  }
};

export const preferences: Preferences = {
  shell: () => {
    const value = read(KEY_SHELL);
    return SHELL_IDS.find((s) => s === value) ?? null;
  },
  setShell: (shell) => write(KEY_SHELL, shell),
  hooks: () => read(KEY_HOOKS) !== "false",
  nativeBlocks: () => read(KEY_NATIVE) !== "false",
  tabsCollapsed: () => read(KEY_TABS) === "true",
  setTabsCollapsed: (collapsed) => write(KEY_TABS, String(collapsed)),
};

export function chooseShell(available: readonly ShellId[], chosen: ShellId | null): ShellId {
  if (chosen && available.includes(chosen)) return chosen;
  return SHELL_IDS.find((s) => available.includes(s)) ?? "cmd";
}

export type TerminalStore = {
  workspace: TerminalWorkspace<TerminalSession>;
  history: CommandHistory;
  completion: CompletionSource;
  backend: TerminalBackend;
  home: string;
  onCompletionLoad: (listener: () => void) => () => void;
  shellId: () => ShellId;
  setShell: (shell: ShellId) => void;
  shells: { id: ShellId; label: string }[];
};

export type StoreInput = {
  backend: TerminalBackend;
  createEngine: (size: { cols: number; rows: number }) => Engine;
  prefs: Preferences;
  home: string;
  shells: { id: ShellId; label: string }[];
  storage?: { load(): string | null; save(path: string): void };
};

export function buildStore(input: StoreInput): TerminalStore {
  const { backend, prefs, home } = input;
  const history = new CommandHistory();
  const loadListeners = new Set<() => void>();
  const completion = new CompletionSource(backend, () => loadListeners.forEach((l) => l()));
  let shell = chooseShell(input.shells.map((s) => s.id), prefs.shell());
  const loadedHistory = new Set<string>();
  const seed = (path: string) => {
    if (loadedHistory.has(path)) return;
    loadedHistory.add(path);
    void backend
      .readHistory(path)
      .then((text) => text && history.seed(parseHistory(text)))
      .catch(() => undefined);
  };
  const memory = input.storage ?? { load: () => read(KEY_DIRECTORY), save: (path: string) => write(KEY_DIRECTORY, path) };
  const workspace = new TerminalWorkspace<TerminalSession>({
    home,
    memory,
    makeSession: (directory) => {
      const session = new TerminalSession({
        shell,
        directory,
        home,
        backend,
        history,
        createEngine: input.createEngine,
        integrationEnabled: prefs.hooks,
        nativeBlocks: prefs.nativeBlocks,
      });
      session.onHistoryFile = seed;
      return session;
    },
  });
  return {
    workspace,
    history,
    completion,
    backend,
    home,
    onCompletionLoad: (listener) => {
      loadListeners.add(listener);
      return () => loadListeners.delete(listener);
    },
    shellId: () => shell,
    setShell: (next) => {
      shell = next;
      prefs.setShell(next);
    },
    shells: input.shells,
  };
}
