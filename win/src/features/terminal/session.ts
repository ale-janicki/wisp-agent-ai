import type { TerminalBackend, PtyEvent } from "./backend";
import { BlockTracker, clearsScreen, decideRerun, IDLE, inputBytes, pasteBytes, type Activity, type RerunDecision } from "./blocks";
import { captureLines, type BufferLike } from "./capture";
import { directoryFromReport, folderName } from "./directory";
import type { CommandHistory } from "./history";
import { RESET_GRID, ShellStream, type ShellEvent } from "./marks";
import { DEFAULT_ALLOWLIST, decidePaneMode, type PaneMode } from "./paneMode";
import { makeNonce, planLaunch, type ShellId } from "./shellIntegration";
import type { StyledLine } from "./styled";

export type TermBuffer = BufferLike & { readonly baseY: number; readonly cursorX: number; readonly cursorY: number };

export type TermLike = {
  readonly cols: number;
  readonly rows: number;
  readonly buffer: { readonly normal: TermBuffer };
  readonly modes: { readonly bracketedPasteMode: boolean; readonly applicationCursorKeysMode: boolean };
  write(data: string, callback?: () => void): void;
  resize(cols: number, rows: number): void;
  onData(listener: (data: string) => void): { dispose(): void };
  onTitleChange(listener: (title: string) => void): { dispose(): void };
};

export type Engine = {
  term: TermLike;
  attach?(host: HTMLElement): void;
  fit?(): { cols: number; rows: number } | null;
  focus?(): void;
  selection?(): string;
  find?: { next(query: string): boolean; previous(query: string): boolean; clear(): void };
  dispose(): void;
};

export type Phase = { kind: "idle" } | { kind: "running" } | { kind: "ended"; code: number | null } | { kind: "failed"; message: string };

export type SessionOptions = {
  id?: string;
  shell: ShellId;
  directory: string;
  home: string;
  backend: TerminalBackend;
  history: CommandHistory;
  createEngine: (size: { cols: number; rows: number }) => Engine;
  integrationEnabled?: () => boolean;
  nativeBlocks?: () => boolean;
  allowlist?: ReadonlySet<string>;
  now?: () => number;
};

export const DEFAULT_SIZE = { cols: 120, rows: 30 } as const;
const MAX_OUTPUT_LINES = 100_000;
const LIVE_ROWS = 80;
const LIVE_DELAY_MS = 60;

export const failureText = (reason: string): string => `Não abriu o shell: ${reason}`;

export class TerminalSession {
  readonly id: string;
  readonly shell: ShellId;
  readonly home: string;
  phase: Phase = { kind: "idle" };
  title = "";
  directory: string;
  activity: Activity = IDLE;
  mode: PaneMode = { kind: "grid", reason: "plainShell" };
  isIntegrated = false;
  isNative = false;
  selectedBlockId: number | null = null;
  historyFile: string | null = null;
  readonly blocks = new BlockTracker();
  live: { id: number; lines: StyledLine[]; hidden: number } | null = null;
  engine: Engine;
  onDirectory: ((path: string) => void) | null = null;
  onHistoryFile: ((path: string) => void) | null = null;

  private readonly opts: SessionOptions;
  private readonly allowlist: ReadonlySet<string>;
  private readonly now: () => number;
  private readonly listeners = new Set<() => void>();
  private version = 0;
  private stream = new ShellStream(null, false);
  private chain: Promise<void> = Promise.resolve();
  private generation = 0;
  private atPrompt = false;
  private sawPrompt = false;
  private inAlternateScreen = false;
  private mouseTracking = false;
  private runningCommand: string | null = null;
  private ranInGrid = false;
  private manualMode: PaneMode | null = null;
  private size: { cols: number; rows: number } = { ...DEFAULT_SIZE };
  private liveTimer: ReturnType<typeof setTimeout> | null = null;
  private subscriptions: { dispose(): void }[] = [];

  constructor(options: SessionOptions) {
    this.opts = options;
    this.id = options.id ?? crypto.randomUUID();
    this.shell = options.shell;
    this.home = options.home;
    this.directory = options.directory;
    this.allowlist = options.allowlist ?? DEFAULT_ALLOWLIST;
    this.now = options.now ?? Date.now;
    this.engine = options.createEngine(this.size);
  }

  subscribe = (listener: () => void): (() => void) => {
    this.listeners.add(listener);
    return () => this.listeners.delete(listener);
  };
  getVersion = (): number => this.version;
  private changed(): void {
    this.version += 1;
    for (const listener of this.listeners) listener();
  }

  whenIdle(): Promise<void> {
    return this.chain;
  }

  get isRunning(): boolean {
    return this.phase.kind === "running";
  }
  get isCommandRunning(): boolean {
    return this.blocks.running !== undefined;
  }
  get name(): string {
    return this.directory ? folderName(this.directory, this.home) : this.shell;
  }

  start(size: { cols: number; rows: number } = this.size): void {
    if (this.phase.kind !== "idle") return;
    this.size = size;
    void this.launch();
  }

  reopen(): void {
    if (this.phase.kind !== "ended" && this.phase.kind !== "failed") return;
    this.unhook();
    this.engine.dispose();
    this.engine = this.opts.createEngine(this.size);
    this.blocks.replace([]);
    this.selectedBlockId = null;
    this.live = null;
    this.syncActivity();
    this.phase = { kind: "idle" };
    void this.launch();
    this.changed();
  }

  resize(size: { cols: number; rows: number }): void {
    if (size.cols < 2 || size.rows < 1) return;
    this.size = size;
    this.engine.term.resize(size.cols, size.rows);
    if (this.isRunning) this.opts.backend.resize(this.id, size.cols, size.rows);
  }

  close(): void {
    this.generation += 1;
    if (this.phase.kind === "running") this.opts.backend.kill(this.id);
    this.phase = { kind: "idle" };
    if (this.liveTimer) clearTimeout(this.liveTimer);
  }

  dispose(): void {
    this.close();
    this.unhook();
    this.engine.dispose();
    this.listeners.clear();
  }

  private unhook(): void {
    for (const s of this.subscriptions) s.dispose();
    this.subscriptions = [];
  }

  private async launch(): Promise<void> {
    this.generation += 1;
    const mine = this.generation;
    const nonce = makeNonce();
    const plan = planLaunch(this.shell, this.opts.integrationEnabled?.() ?? true, nonce);
    this.isIntegrated = plan.integrated;
    this.isNative = plan.integrated && (this.opts.nativeBlocks?.() ?? true);
    this.stream = new ShellStream(plan.nonce, this.isNative);
    this.chain = Promise.resolve();
    this.atPrompt = false;
    this.sawPrompt = false;
    this.inAlternateScreen = false;
    this.mouseTracking = false;
    this.runningCommand = null;
    this.ranInGrid = false;
    this.manualMode = null;
    this.historyFile = null;
    this.title = "";
    this.refreshMode();
    const term = this.engine.term;
    this.subscriptions.push(
      term.onData((data) => {
        if (this.generation === mine) this.write(data);
      }),
      term.onTitleChange((title) => {
        if (this.generation !== mine) return;
        this.title = title;
        this.changed();
      }),
    );
    this.phase = { kind: "running" };
    try {
      await this.opts.backend.spawn(
        { id: this.id, shell: plan.shell, cwd: this.directory || null, cols: this.size.cols, rows: this.size.rows, nonce: plan.nonce, integration: plan.integration },
        (event) => {
          if (this.generation === mine) this.receive(event);
        },
      );
    } catch (error) {
      if (this.generation === mine) this.phase = { kind: "failed", message: failureText(error instanceof Error ? error.message : String(error)) };
    }
    this.changed();
  }

  private receive(event: PtyEvent): void {
    const mine = this.generation;
    this.chain = this.chain
      .then(() => (event.event === "output" ? this.process(event.text) : (this.ended(event.code), true)))
      .catch((error: unknown) => {
        console.warn("terminal: output failed", error);
        return false;
      })
      .then((visible) => {
        if (visible && mine === this.generation) this.changed();
      });
  }

  private ended(code: number | null): void {
    this.phase = { kind: "ended", code };
    this.blocks.shellEnded(this.now());
    this.live = null;
    this.syncActivity();
  }

  private async process(text: string): Promise<boolean> {
    const term = this.engine.term;
    const events: ShellEvent[] = [];
    for (const piece of this.stream.cut(text)) {
      if (piece.kind === "text") await new Promise<void>((resolve) => term.write(piece.text, resolve));
      else if (piece.kind === "resetGrid") await new Promise<void>((resolve) => term.write(RESET_GRID, resolve));
      else {
        events.push(piece.event);
        this.apply(piece.event);
      }
    }
    if (events.length > 0) this.syncActivity();
    this.scheduleLive();
    return events.length > 0;
  }

  private apply(event: ShellEvent): void {
    if (event.type === "historyFile") {
      this.historyFile = event.path;
      this.onHistoryFile?.(event.path);
    }
    if (event.type === "declined") {
      this.isIntegrated = false;
      this.isNative = false;
    }
    if (this.isNative && event.type === "cleared") return;
    const runningBefore = this.blocks.running?.id ?? null;
    this.blocks.apply(event, this.now());
    if (this.isNative) this.applyNative(event, runningBefore);
    if (event.type === "declined") this.refreshMode();
    if (event.type === "directory" || event.type === "commandEnd") this.syncDirectory();
    if (this.selectedBlockId !== null && !this.blocks.block(this.selectedBlockId)) this.selectedBlockId = null;
  }

  private applyNative(event: ShellEvent, runningBefore: number | null): void {
    switch (event.type) {
      case "alternateScreen":
        this.inAlternateScreen = event.on;
        this.refreshMode();
        break;
      case "mouseTracking":
        this.mouseTracking = event.on;
        this.refreshMode();
        break;
      case "promptStart":
        this.atPrompt = false;
        this.sawPrompt = true;
        if (runningBefore !== null) this.blocks.setOutput(runningBefore, this.ranInGrid ? [] : this.captureOutput());
        this.leaveGrid();
        break;
      case "promptEnd":
        this.atPrompt = this.blocks.running === undefined;
        break;
      case "commandStart": {
        this.atPrompt = false;
        const running = this.blocks.running;
        if (running) {
          this.runningCommand = running.command;
          this.refreshMode();
        }
        break;
      }
      case "commandEnd": {
        const finished = runningBefore === null ? undefined : this.blocks.block(runningBefore);
        if (finished && finished.status.kind !== "running") {
          this.blocks.setOutput(finished.id, this.ranInGrid ? [] : this.captureOutput());
          if (clearsScreen(finished.command)) this.blocks.replace([]);
        }
        this.live = null;
        this.leaveGrid();
        break;
      }
      default:
        break;
    }
  }

  private captureOutput(): StyledLine[] {
    const buffer = this.engine.term.buffer.normal;
    const end = buffer.baseY + buffer.cursorY + (buffer.cursorX > 0 ? 1 : 0);
    let lines = captureLines(buffer, 0, end);
    if (lines[0]?.text === "") lines = lines.slice(1);
    while (lines.length > 0 && lines[lines.length - 1]!.text === "") lines.pop();
    return lines.length > MAX_OUTPUT_LINES ? lines.slice(lines.length - MAX_OUTPUT_LINES) : lines;
  }

  private scheduleLive(): void {
    if (this.liveTimer || !this.isNative || !this.blocks.running) return;
    this.liveTimer = setTimeout(() => {
      this.liveTimer = null;
      const running = this.blocks.running;
      if (!running || this.mode.kind !== "blocks") return;
      const buffer = this.engine.term.buffer.normal;
      const end = buffer.baseY + buffer.cursorY + (buffer.cursorX > 0 ? 1 : 0);
      const from = Math.max(0, end - LIVE_ROWS);
      const lines = captureLines(buffer, from, end);
      const skipBreak = from === 0 && lines[0]?.text === "";
      this.live = { id: running.id, lines: skipBreak ? lines.slice(1) : lines, hidden: from };
      this.changed();
    }, LIVE_DELAY_MS);
  }

  private syncDirectory(): void {
    const path = this.blocks.directory;
    if (!path || path === this.directory) return;
    this.directory = path;
    this.onDirectory?.(path);
  }

  private syncActivity(): void {
    const current = this.blocks.activity;
    if (current.state !== this.activity.state || current.command !== this.activity.command) this.activity = current;
  }

  private leaveGrid(): void {
    this.runningCommand = null;
    this.inAlternateScreen = false;
    this.mouseTracking = false;
    this.ranInGrid = false;
    this.manualMode = null;
    this.refreshMode();
  }

  private refreshMode(): void {
    let next: PaneMode = { kind: "grid", reason: "plainShell" };
    if (this.isNative) {
      next = decidePaneMode({ altScreen: this.inAlternateScreen, mouse: this.mouseTracking, command: this.runningCommand, allowlist: this.allowlist });
      if (next.kind === "grid" && (next.reason === "allowlisted" || next.reason === "mouseTracking")) this.ranInGrid = true;
      if (this.manualMode) next = this.manualMode;
    }
    const same = next.kind === this.mode.kind && (next.kind === "blocks" || (this.mode.kind === "grid" && this.mode.reason === next.reason));
    if (!same) this.mode = next;
  }

  toggleGrid(): void {
    if (!this.isNative || !this.isRunning) return;
    this.manualMode = this.mode.kind === "grid" ? { kind: "blocks" } : { kind: "grid", reason: "manual" };
    this.refreshMode();
    this.changed();
  }

  write(data: string): void {
    if (!this.isRunning) return;
    if (data.includes("\x03") && this.blocks.markInterrupted()) this.changed();
    this.opts.backend.write(this.id, data);
  }

  submit(text: string): boolean {
    if (!this.isRunning || !this.isNative || this.blocks.running || !(this.atPrompt || this.sawPrompt)) return false;
    if (text.trim() === "") return false;
    this.atPrompt = false;
    this.opts.history.append(text);
    this.opts.backend.write(this.id, inputBytes(text, this.engine.term.modes.bracketedPasteMode));
    return true;
  }

  paste(text: string): void {
    const bytes = pasteBytes(text, this.engine.term.modes.bracketedPasteMode);
    if (bytes !== "") this.write(bytes);
  }

  rerun(id: number): RerunDecision {
    const block = this.blocks.block(id);
    if (!block) return { ok: false, refusal: "Sem comando para colar de novo." };
    const decision = decideRerun(block.command, this.engine.term.modes.bracketedPasteMode, this.isRunning && !this.blocks.running);
    if (decision.ok) {
      this.opts.history.append(block.command);
      this.write(decision.action.text);
    }
    return decision;
  }

  clearBlocks(): void {
    this.blocks.replace([]);
    this.selectedBlockId = null;
    this.live = null;
    this.changed();
  }

  selectBlock(id: number | null): void {
    if (this.selectedBlockId === id) return;
    this.selectedBlockId = id;
    this.changed();
  }

  get canSubmit(): boolean {
    return this.isRunning && this.isNative && !this.blocks.running && (this.atPrompt || this.sawPrompt);
  }

  setDirectoryFromReport(report: string): void {
    const path = directoryFromReport(report);
    if (path && path !== this.directory) {
      this.directory = path;
      this.onDirectory?.(path);
      this.changed();
    }
  }
}
