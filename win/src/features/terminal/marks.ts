export type ShellEvent =
  | { type: "promptStart" }
  | { type: "promptEnd" }
  | { type: "commandStart" }
  | { type: "commandEnd"; exitCode: number | null }
  | { type: "directory"; report: string }
  | { type: "historyFile"; path: string }
  | { type: "command"; text: string }
  | { type: "alternateScreen"; on: boolean }
  | { type: "mouseTracking"; on: boolean }
  | { type: "cleared"; scrollback: boolean }
  | { type: "declined" };

export type ScannedEvent = { event: ShellEvent; start: number; end: number; beganEarlier: boolean };

const CUSTOM_CODE = 6973;
const MAX_BODY = 65_536;
const MAX_CSI = 32;
const ESC = 0x1b;
const BEL = 0x07;

type State = "ground" | "escape" | "csi" | "oscCode" | "oscBody" | "oscBodyEscape" | "oscSkip" | "oscSkipEscape";

export function decodeCommand(encoded: string): string | null {
  let text = encoded.replace(/\s+/g, "");
  while (text.length % 4 !== 0) text += "=";
  if (!/^[A-Za-z0-9+/]*={0,2}$/.test(text)) return null;
  try {
    const binary = atob(text);
    return new TextDecoder().decode(Uint8Array.from(binary, (c) => c.charCodeAt(0)));
  } catch {
    return null;
  }
}

export class ShellMarkScanner {
  private state: State = "ground";
  private promptOpen = false;
  private code = 0;
  private codeDigits = 0;
  private body = "";
  private csi = "";
  private openedEarlier = false;
  private readonly mouseModes = new Set<number>();
  pendingStart: number | null = null;

  constructor(private readonly nonce: string | null) {}

  resetSequence(): void {
    this.state = "ground";
    this.code = 0;
    this.codeDigits = 0;
    this.body = "";
    this.csi = "";
    this.openedEarlier = false;
    this.pendingStart = null;
  }

  scan(text: string): ScannedEvent[] {
    const found: ScannedEvent[] = [];
    this.openedEarlier = this.state !== "ground";
    let start = 0;
    let index = 0;
    while (index < text.length) {
      if (this.state === "ground") {
        const hit = text.indexOf("\x1b", index);
        if (hit < 0) break;
        start = hit;
        this.state = "escape";
        index = hit + 1;
        continue;
      }
      const byte = text.charCodeAt(index);
      index += 1;
      for (const event of this.step(byte)) {
        found.push({ event, start: this.openedEarlier ? 0 : start, end: index, beganEarlier: this.openedEarlier });
      }
      if ((this.state as State) === "ground") this.openedEarlier = false;
    }
    this.pendingStart = this.state === "ground" || this.openedEarlier ? null : start;
    return found;
  }

  private step(byte: number): ShellEvent[] {
    switch (this.state) {
      case "ground":
        return [];
      case "escape":
        if (byte === 0x5d) {
          this.state = "oscCode";
          this.code = 0;
          this.codeDigits = 0;
          this.body = "";
        } else if (byte === 0x5b) {
          this.state = "csi";
          this.csi = "";
        } else if (byte !== ESC) {
          this.state = "ground";
        }
        return [];
      case "csi":
        if (byte >= 0x40 && byte <= 0x7e) {
          this.state = "ground";
          return this.csiEvents(this.csi, String.fromCharCode(byte));
        }
        if (byte === ESC) {
          this.state = "escape";
          return [];
        }
        if (byte < 0x20 || byte > 0x7e || this.csi.length >= MAX_CSI) {
          this.state = "ground";
          return [];
        }
        this.csi += String.fromCharCode(byte);
        return [];
      case "oscCode":
        if (byte >= 0x30 && byte <= 0x39 && this.codeDigits < 5) {
          this.code = this.code * 10 + (byte - 0x30);
          this.codeDigits += 1;
          return [];
        }
        if (byte === 0x3b) {
          this.state = this.code === CUSTOM_CODE && this.nonce ? "oscBody" : "oscSkip";
          return [];
        }
        this.state = byte === ESC ? "oscSkipEscape" : "ground";
        return [];
      case "oscBody":
        if (byte === BEL) return this.finishOsc();
        if (byte === ESC) {
          this.state = "oscBodyEscape";
          return [];
        }
        if (byte === 0x18 || byte === 0x1a) {
          this.state = "ground";
          return [];
        }
        if (this.body.length >= MAX_BODY) {
          this.state = "oscSkip";
          this.body = "";
          return [];
        }
        this.body += String.fromCharCode(byte);
        return [];
      case "oscBodyEscape":
        if (byte === 0x5c) return this.finishOsc();
        if (byte === 0x5b || byte === 0x5d) {
          this.state = "escape";
          return this.step(byte);
        }
        this.state = "ground";
        return [];
      case "oscSkip":
        if (byte === BEL || byte === 0x18 || byte === 0x1a) this.state = "ground";
        else if (byte === ESC) this.state = "oscSkipEscape";
        return [];
      case "oscSkipEscape":
        if (byte === 0x5c) {
          this.state = "ground";
          return [];
        }
        if (byte === 0x5b || byte === 0x5d) {
          this.state = "escape";
          return this.step(byte);
        }
        this.state = "oscSkip";
        return [];
    }
  }

  private finishOsc(): ShellEvent[] {
    this.state = "ground";
    let event = this.markEvent(this.body);
    if (event?.type === "promptStart") {
      this.mouseModes.clear();
      this.promptOpen = true;
    } else if (event?.type === "commandEnd") {
      this.mouseModes.clear();
    } else if (event?.type === "promptEnd") {
      if (this.promptOpen) this.promptOpen = false;
      else event = null;
    }
    return event ? [event] : [];
  }

  private markEvent(body: string): ShellEvent | null {
    const nonce = this.nonce ?? "";
    if (body.length <= nonce.length || body[nonce.length] !== ";" || !body.startsWith(nonce)) return null;
    const mark = body.slice(nonce.length + 1);
    if (mark === "A") return { type: "promptStart" };
    if (mark === "B") return { type: "promptEnd" };
    if (mark === "C") return { type: "commandStart" };
    if (mark === "declined") return { type: "declined" };
    if (mark === "D" || mark.startsWith("D;")) {
      const digits = /^\d+/.exec(mark.slice(2))?.[0];
      return { type: "commandEnd", exitCode: digits === undefined ? null : Number(digits) };
    }
    if (mark.startsWith("cmd=")) {
      const text = decodeCommand(mark.slice(4));
      return text === null ? null : { type: "command", text };
    }
    if (mark.startsWith("hist=")) {
      const path = decodeCommand(mark.slice(5));
      return path ? { type: "historyFile", path } : null;
    }
    if (mark.startsWith("cwd=")) return { type: "directory", report: mark.slice(4) };
    return null;
  }

  private csiEvents(params: string, final: string): ShellEvent[] {
    if (final === "h" || final === "l") {
      if (!params.startsWith("?")) return [];
      const modes = params
        .slice(1)
        .split(";")
        .map((m) => Number.parseInt(m, 10))
        .filter((m) => Number.isFinite(m));
      const on = final === "h";
      const events: ShellEvent[] = [];
      if (modes.some((m) => m === 47 || m === 1047 || m === 1049)) events.push({ type: "alternateScreen", on });
      const tracking = modes.filter((m) => m === 1000 || m === 1002 || m === 1003);
      if (tracking.length > 0) {
        for (const mode of tracking) {
          if (on) this.mouseModes.add(mode);
          else this.mouseModes.delete(mode);
        }
        events.push({ type: "mouseTracking", on: this.mouseModes.size > 0 });
      }
      return events;
    }
    if (final === "J") {
      if (params === "2") return [{ type: "cleared", scrollback: false }];
      if (params === "3") return [{ type: "cleared", scrollback: true }];
    }
    return [];
  }
}

export type StreamPiece = { kind: "text"; text: string } | { kind: "resetGrid" } | { kind: "event"; event: ShellEvent };

const MAX_HELD = 256;
export const RESET_GRID = "\x1b[H\x1b[2J\x1b[3J";

export class ShellStream {
  private readonly scanner: ShellMarkScanner;
  private held = "";

  constructor(
    nonce: string | null,
    private readonly nativeBlocks: boolean,
  ) {
    this.scanner = new ShellMarkScanner(nonce);
  }

  cut(read: string): StreamPiece[] {
    const input = this.held + read;
    this.held = "";
    if (input === "") return [];
    const found = this.scanner.scan(input);
    let end = input.length;
    const pending = this.scanner.pendingStart;
    if (pending !== null && input.length - pending <= MAX_HELD) {
      this.held = input.slice(pending);
      end = pending;
      this.scanner.resetSequence();
    }
    const pieces: StreamPiece[] = [];
    let fed = 0;
    for (const item of found) {
      if (item.end > fed) pieces.push({ kind: "text", text: input.slice(fed, item.end) });
      fed = Math.max(fed, item.end);
      if (this.nativeBlocks && item.event.type === "commandStart") pieces.push({ kind: "resetGrid" });
      pieces.push({ kind: "event", event: item.event });
    }
    if (fed < end) pieces.push({ kind: "text", text: input.slice(fed, end) });
    return pieces;
  }
}
