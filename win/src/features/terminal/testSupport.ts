import { Terminal } from "@xterm/headless";
import type { DirEntry } from "./completion";
import type { GitRaw, PtyEvent, SpawnRequest, TerminalBackend } from "./backend";
import type { Engine } from "./session";

export const b64 = (text: string) => btoa(String.fromCharCode(...new TextEncoder().encode(text)));
const NONCE_OF = (request: SpawnRequest) => request.nonce!;

export class ScriptedBackend implements TerminalBackend {
  request: SpawnRequest | null = null;
  writes: string[] = [];
  resizes: [number, number][] = [];
  killed = false;
  failSpawn: string | null = null;
  private emitter: ((e: PtyEvent) => void) | null = null;

  async spawn(request: SpawnRequest, onEvent: (event: PtyEvent) => void) {
    if (this.failSpawn) throw new Error(this.failSpawn);
    this.request = request;
    this.emitter = onEvent;
  }
  write(_id: string, data: string) {
    this.writes.push(data);
  }
  resize(_id: string, cols: number, rows: number) {
    this.resizes.push([cols, rows]);
  }
  kill() {
    this.killed = true;
  }
  shells = async () => [];
  home = async () => "C:\\Users\\dev";
  folders: Record<string, DirEntry[]> = {};
  programs: string[] = [];
  git: GitRaw | null = null;
  historyText: string | null = null;
  listDirectory = async (path: string) => this.folders[path] ?? [];
  executables = async () => this.programs;
  gitStatus = async () => this.git;
  readHistory = async () => this.historyText;

  output(text: string) {
    this.emitter!({ event: "output", text });
  }
  exit(code: number | null) {
    this.emitter!({ event: "exit", code });
  }
  mark(body: string) {
    return `\x1b]6973;${NONCE_OF(this.request!)};${body}\x07`;
  }
}

export const headlessEngine = (size: { cols: number; rows: number }): Engine => {
  const term = new Terminal({ cols: size.cols, rows: size.rows, allowProposedApi: true, scrollback: 1000 });
  return { term, dispose: () => term.dispose() };
};
