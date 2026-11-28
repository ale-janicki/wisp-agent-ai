import type { DirEntry } from "./completion";
import type { ShellId } from "./shellIntegration";

export type PtyEvent = { event: "output"; text: string } | { event: "exit"; code: number | null };

export type SpawnRequest = {
  id: string;
  shell: ShellId;
  cwd: string | null;
  cols: number;
  rows: number;
  nonce: string | null;
  integration: string | null;
};

export type ShellInfo = { id: ShellId; label: string };

export type GitRaw = { porcelain: string; shortstat: string };

export interface TerminalBackend {
  spawn(request: SpawnRequest, onEvent: (event: PtyEvent) => void): Promise<void>;
  write(id: string, data: string): void;
  resize(id: string, cols: number, rows: number): void;
  kill(id: string): void;
  shells(): Promise<ShellInfo[]>;
  home(): Promise<string>;
  listDirectory(path: string): Promise<DirEntry[]>;
  executables(): Promise<string[]>;
  gitStatus(directory: string): Promise<GitRaw | null>;
  readHistory(path: string): Promise<string | null>;
}
