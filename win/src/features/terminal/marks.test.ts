import { describe, expect, it } from "vitest";
import { decodeCommand, ShellMarkScanner, ShellStream, type ShellEvent } from "./marks";

const NONCE = "abc123";
const mark = (body: string, nonce = NONCE) => `\x1b]6973;${nonce};${body}\x07`;
const events = (text: string, nonce: string | null = NONCE): ShellEvent[] =>
  new ShellMarkScanner(nonce).scan(text).map((s) => s.event);
const b64 = (text: string) => btoa(String.fromCharCode(...new TextEncoder().encode(text)));

describe("ShellMarkScanner", () => {
  it("reads the marks that carry the session nonce", () => {
    const text = mark("A") + mark("B") + mark("C") + mark("D;3");
    expect(events(text)).toEqual([
      { type: "promptStart" },
      { type: "promptEnd" },
      { type: "commandStart" },
      { type: "commandEnd", exitCode: 3 },
    ]);
  });

  it("ignores look-alike marks: wrong nonce, plain OSC 133, no nonce at all", () => {
    expect(events(mark("A", "other"))).toEqual([]);
    expect(events("\x1b]133;A\x07")).toEqual([]);
    expect(events(mark("A"), null)).toEqual([]);
  });

  it("D without a code means no exit code", () => {
    expect(events(mark("A") + mark("D"))).toEqual([{ type: "promptStart" }, { type: "commandEnd", exitCode: null }]);
  });

  it("only the first B after an A counts", () => {
    expect(events(mark("A") + mark("B") + mark("B"))).toEqual([{ type: "promptStart" }, { type: "promptEnd" }]);
  });

  it("decodes the command, the history file and the folder", () => {
    const found = events(mark(`cmd=${b64("git status ç")}`) + mark(`hist=${b64("C:\\h\\x_history.txt")}`) + mark("cwd=file:///C:/Users/dev"));
    expect(found).toEqual([
      { type: "command", text: "git status ç" },
      { type: "historyFile", path: "C:\\h\\x_history.txt" },
      { type: "directory", report: "file:///C:/Users/dev" },
    ]);
  });

  it("decodeCommand takes padded and unpadded base64 and refuses garbage", () => {
    expect(decodeCommand(b64("ab").replace(/=+$/, ""))).toBe("ab");
    expect(decodeCommand("%%%")).toBeNull();
  });

  it("accepts ST as the terminator and reports declined", () => {
    expect(events(`\x1b]6973;${NONCE};declined\x1b\\`)).toEqual([{ type: "declined" }]);
  });

  it("tracks the alternate screen, mouse reporting and screen clears", () => {
    const found = events("\x1b[?1049h\x1b[?1000h\x1b[?1006h\x1b[?1000l\x1b[?1049l\x1b[2J\x1b[3J");
    expect(found).toEqual([
      { type: "alternateScreen", on: true },
      { type: "mouseTracking", on: true },
      { type: "mouseTracking", on: false },
      { type: "alternateScreen", on: false },
      { type: "cleared", scrollback: false },
      { type: "cleared", scrollback: true },
    ]);
  });

  it("a prompt or the end of a command empties the mouse modes", () => {
    const found = events("\x1b[?1000h" + mark("A") + "\x1b[?1002l");
    expect(found.filter((e) => e.type === "mouseTracking")).toEqual([
      { type: "mouseTracking", on: true },
      { type: "mouseTracking", on: false },
    ]);
  });

  it("reports where each mark sits in the text", () => {
    const text = "hi" + mark("A") + "there";
    const [only] = new ShellMarkScanner(NONCE).scan(text);
    expect(text.slice(only!.start, only!.end)).toBe(mark("A"));
  });
});

describe("ShellStream", () => {
  it("cuts the text at each mark so the cursor can be read where the mark was", () => {
    const stream = new ShellStream(NONCE, true);
    expect(stream.cut("out" + mark("C") + "more")).toEqual([
      { kind: "text", text: "out" + mark("C") },
      { kind: "resetGrid" },
      { kind: "event", event: { type: "commandStart" } },
      { kind: "text", text: "more" },
    ]);
  });

  it("holds a mark split across two reads", () => {
    const stream = new ShellStream(NONCE, true);
    const whole = mark("D;0");
    const first = stream.cut("x" + whole.slice(0, 6));
    expect(first).toEqual([{ kind: "text", text: "x" }]);
    const second = stream.cut(whole.slice(6) + "y");
    expect(second).toEqual([
      { kind: "text", text: whole },
      { kind: "event", event: { type: "commandEnd", exitCode: 0 } },
      { kind: "text", text: "y" },
    ]);
  });

  it("passes plain text through untouched", () => {
    expect(new ShellStream(NONCE, true).cut("hello")).toEqual([{ kind: "text", text: "hello" }]);
  });
});
