import { Channel, invoke } from "@tauri-apps/api/core";
import type { DirEntry } from "./completion";
import type { GitRaw, PtyEvent, ShellInfo, SpawnRequest, TerminalBackend } from "./backend";

type RawEntry = { name: string; isDir: boolean };

const swallow = (id: string) => (error: unknown) => {
  console.warn(`terminal: command failed for ${id}`, error);
};

export const tauriBackend: TerminalBackend = {
  async spawn(request: SpawnRequest, onEvent: (event: PtyEvent) => void): Promise<void> {
    const channel = new Channel<PtyEvent>();
    channel.onmessage = onEvent;
    await invoke("terminal_spawn", { ...request, onEvent: channel });
  },
  write(id, data) {
    void invoke("terminal_write", { id, data }).catch(swallow(id));
  },
  resize(id, cols, rows) {
    void invoke("terminal_resize", { id, cols, rows }).catch(swallow(id));
  },
  kill(id) {
    void invoke("terminal_kill", { id }).catch(swallow(id));
  },
  shells: () => invoke<ShellInfo[]>("terminal_shells"),
  home: () => invoke<string>("terminal_home"),
  async listDirectory(path): Promise<DirEntry[]> {
    return (await invoke<RawEntry[]>("terminal_list_dir", { path })).map((e) => ({ name: e.name, isDir: e.isDir }));
  },
  executables: () => invoke<string[]>("terminal_executables"),
  gitStatus: (directory) => invoke<GitRaw | null>("terminal_git_status", { directory }),
  readHistory: (path) => invoke<string | null>("terminal_read_history", { path }),
};
