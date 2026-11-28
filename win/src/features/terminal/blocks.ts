import { directoryFromReport } from "./directory";
import type { ShellEvent } from "./marks";
import type { StyledLine } from "./styled";

export type BlockStatus = { kind: "running" } | { kind: "finished"; code: number } | { kind: "lost" };

export type TerminalBlock = {
  id: number;
  command: string;
  directory: string | null;
  startedAt: number;
  finishedAt: number | null;
  status: BlockStatus;
  output: StyledLine[] | null;
  interrupted: boolean;
  rev: number;
};

export type Activity =
  | { state: "idle"; command: null }
  | { state: "running" | "succeeded"; command: string | null }
  | { state: "failed"; code: number; command: string | null };

export const IDLE: Activity = { state: "idle", command: null };

export const BLOCK_CAPACITY = 500;

export class BlockTracker {
  blocks: TerminalBlock[] = [];
  directory: string | null = null;
  suspended = false;
  private pendingPrompt = false;
  private pendingCommand: string | null = null;
  private nextId = 1;

  get running(): TerminalBlock | undefined {
    for (let i = this.blocks.length - 1; i >= 0; i--) if (this.blocks[i]!.status.kind === "running") return this.blocks[i];
    return undefined;
  }

  get activity(): Activity {
    const last = this.blocks.at(-1);
    if (!last) return IDLE;
    const command = last.command === "" ? null : last.command;
    switch (last.status.kind) {
      case "running": return { state: "running", command };
      case "finished": return last.status.code === 0 ? { state: "succeeded", command } : { state: "failed", code: last.status.code, command };
      case "lost": return { state: "idle", command: null };
    }
  }

  apply(event: ShellEvent, now: number): void {
    switch (event.type) {
      case "alternateScreen":
        this.suspended = event.on;
        return;
      case "declined":
      case "promptEnd":
      case "mouseTracking":
      case "historyFile":
        return;
      case "directory": {
        const path = directoryFromReport(event.report);
        if (path) this.directory = path;
        return;
      }
      case "cleared":
        this.clear(event.scrollback);
        return;
      case "promptStart":
        this.suspended = false;
        this.closeLost(now);
        this.pendingPrompt = true;
        this.pendingCommand = null;
        return;
      case "command":
        if (!this.suspended) this.pendingCommand = event.text;
        return;
      case "commandStart":
        if (this.suspended || !this.pendingPrompt) return;
        this.closeLost(now);
        this.blocks.push({
          id: this.nextId,
          command: this.pendingCommand ?? "",
          directory: this.directory,
          startedAt: now,
          finishedAt: null,
          status: { kind: "running" },
          output: null,
          interrupted: false,
          rev: 0,
        });
        this.nextId += 1;
        this.pendingPrompt = false;
        this.pendingCommand = null;
        if (this.blocks.length > BLOCK_CAPACITY) this.blocks.splice(0, this.blocks.length - BLOCK_CAPACITY);
        return;
      case "commandEnd": {
        this.suspended = false;
        const block = this.running;
        if (!block) return;
        block.finishedAt = now;
        block.status = event.exitCode === null ? { kind: "lost" } : { kind: "finished", code: event.exitCode };
        block.rev += 1;
        return;
      }
    }
  }

  markInterrupted(): boolean {
    const block = this.running;
    if (!block || block.interrupted) return false;
    block.interrupted = true;
    block.rev += 1;
    return true;
  }

  shellEnded(now: number): void {
    this.closeLost(now);
  }

  setOutput(id: number, output: StyledLine[]): void {
    const block = this.blocks.find((b) => b.id === id);
    if (block) {
      block.output = output;
      block.rev += 1;
    }
  }

  replace(blocks: TerminalBlock[]): void {
    this.blocks = blocks;
  }

  block(id: number | null): TerminalBlock | undefined {
    return id === null ? undefined : this.blocks.find((b) => b.id === id);
  }

  private closeLost(now: number): void {
    const block = this.running;
    if (!block) return;
    block.finishedAt = now;
    block.status = { kind: "lost" };
    block.rev += 1;
  }

  private clear(scrollback: boolean): void {
    if (scrollback) this.blocks = [];
  }
}

export const CLEAR_COMMANDS = new Set(["clear", "cls", "clear-host"]);

export function clearsScreen(command: string): boolean {
  if (/[;&|\n`$(]/.test(command)) return false;
  const first = command.trim().split(/\s+/)[0];
  return first !== undefined && CLEAR_COMMANDS.has(first.toLowerCase());
}

export type RerunAction = { kind: "type"; text: string };
export type RerunDecision = { ok: true; action: RerunAction } | { ok: false; refusal: string };

export const REFUSAL_BUSY = "O shell está ocupado: espere o comando atual terminar.";
export const REFUSAL_EMPTY = "Sem comando para colar de novo.";

const PASTE_START = "\x1b[200~";
const PASTE_END = "\x1b[201~";
const CLEAR_LINE = "\x1b";

export function sanitize(command: string): string {
  let out = "";
  for (const char of command) {
    const code = char.codePointAt(0)!;
    if (code === 0x0a || code === 0x09 || (code >= 0x20 && code !== 0x7f && !(code >= 0x80 && code <= 0x9f))) out += char;
  }
  return out;
}

export function inputBytes(text: string, bracketedPaste: boolean): string {
  const clean = sanitize(text).replace(/\n+$/, "");
  const body = bracketedPaste ? PASTE_START + clean + PASTE_END : clean.replace(/\n/g, "\r");
  return `${CLEAR_LINE}${body}\r`;
}

export function pasteBytes(text: string, bracketedPaste: boolean): string {
  const clean = sanitize(text.replace(/\r\n/g, "\n").replace(/\r/g, "\n")).replace(/\n/g, "\r");
  if (clean === "") return "";
  return bracketedPaste ? PASTE_START + clean + PASTE_END : clean;
}

export function decideRerun(command: string, bracketedPaste: boolean, atPrompt: boolean): RerunDecision {
  const text = sanitize(command).replace(/\n+$/, "");
  if (text.trim() === "") return { ok: false, refusal: REFUSAL_EMPTY };
  if (!atPrompt) return { ok: false, refusal: REFUSAL_BUSY };
  return { ok: true, action: { kind: "type", text: inputBytes(text, bracketedPaste) } };
}

export function blockDuration(seconds: number): string {
  const value = Math.max(0, seconds);
  const tenths = Math.round(value * 10);
  if (tenths < 100) return `${Math.floor(tenths / 10)},${tenths % 10} s`;
  const whole = Math.round(value);
  if (whole < 60) return `${whole} s`;
  if (whole < 3600) return `${Math.floor(whole / 60)} min ${whole % 60} s`;
  return `${Math.floor(whole / 3600)} h ${Math.floor((whole % 3600) / 60)} min`;
}

export type CopyKind = "command" | "output" | "commandAndOutput";

export function copyText(kind: CopyKind, command: string, output: string): string {
  const typed = command.replace(/\n+$/, "");
  if (kind === "command") return typed;
  if (kind === "output") return output;
  return [typed, output].filter((p) => p !== "").join("\n");
}
