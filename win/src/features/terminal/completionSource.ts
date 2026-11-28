import type { CompletionContext, DirEntry } from "./completion";
import type { TerminalBackend } from "./backend";

const FOLDER_MAX_AGE_MS = 5_000;
const PROGRAMS_MAX_AGE_MS = 30_000;

type Cached<T> = { value: T; at: number };

export class CompletionSource {
  private folders = new Map<string, Cached<DirEntry[]>>();
  private programs: Cached<string[]> | null = null;
  private pending = new Set<string>();

  constructor(
    private readonly backend: Pick<TerminalBackend, "listDirectory" | "executables">,
    private readonly onLoad: () => void,
    private readonly now: () => number = Date.now,
  ) {}

  context(cwd: string, home: string): CompletionContext {
    return { cwd, home, list: (directory) => this.list(directory), executables: () => this.executables() };
  }

  private list(directory: string): DirEntry[] {
    const key = directory.toLowerCase();
    const cached = this.folders.get(key);
    if (!cached || this.now() - cached.at > FOLDER_MAX_AGE_MS) this.fetch(`d:${key}`, async () => {
      const value = await this.backend.listDirectory(directory).catch(() => []);
      this.folders.set(key, { value, at: this.now() });
    });
    return cached?.value ?? [];
  }

  private executables(): string[] {
    if (!this.programs || this.now() - this.programs.at > PROGRAMS_MAX_AGE_MS) this.fetch("programs", async () => {
      const value = await this.backend.executables().catch(() => []);
      this.programs = { value, at: this.now() };
    });
    return this.programs?.value ?? [];
  }

  private fetch(key: string, load: () => Promise<void>): void {
    if (this.pending.has(key)) return;
    this.pending.add(key);
    void load().then(() => {
      this.pending.delete(key);
      this.onLoad();
    });
  }
}
