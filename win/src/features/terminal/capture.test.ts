import { Terminal } from "@xterm/headless";
import { describe, expect, it } from "vitest";
import { captureLines, plainText } from "./capture";
import { PLAIN, type StyledLine } from "./styled";

const feed = (term: Terminal, data: string) => new Promise<void>((resolve) => term.write(data, resolve));
const make = (cols = 20, rows = 5) => new Terminal({ cols, rows, allowProposedApi: true, scrollback: 100 });

describe("captureLines", () => {
  it("reads the rows with the text trimmed on the right", async () => {
    const term = make();
    await feed(term, "hello  \r\nworld\r\n");
    const lines = captureLines(term.buffer.active, 0, 2);
    expect(plainText(lines)).toBe("hello\nworld");
  });

  it("joins a row the terminal wrapped into one line", async () => {
    const term = make(5, 4);
    await feed(term, "abcdefgh\r\nz");
    const lines = captureLines(term.buffer.active, 0, 3);
    expect(lines.map((l) => l.text)).toEqual(["abcdefgh", "z"]);
  });

  it("keeps colors and weight as runs over the text", async () => {
    const term = make();
    await feed(term, "a\x1b[31;1mred\x1b[0m \x1b[38;2;1;2;3mrgb\x1b[0m");
    const [line] = captureLines(term.buffer.active, 0, 1) as [StyledLine];
    expect(line.text).toBe("ared rgb");
    expect(line.runs).toEqual([
      { start: 0, end: 1, style: PLAIN },
      { start: 1, end: 4, style: expect.objectContaining({ fg: 1, bold: true }) },
      { start: 4, end: 5, style: PLAIN },
      { start: 5, end: 8, style: expect.objectContaining({ fg: "#010203", bold: false }) },
    ]);
  });

  it("counts a wide character once", async () => {
    const term = make();
    await feed(term, "日本x");
    const [line] = captureLines(term.buffer.active, 0, 1) as [StyledLine];
    expect(line.text).toBe("日本x");
  });

  it("reads rows that already left the screen", async () => {
    const term = make(10, 3);
    await feed(term, "1\r\n2\r\n3\r\n4\r\n5");
    const buffer = term.buffer.active;
    expect(plainText(captureLines(buffer, 0, buffer.baseY + buffer.cursorY + 1))).toBe("1\n2\n3\n4\n5");
  });

  it("an empty range gives no lines", async () => {
    const term = make();
    expect(captureLines(term.buffer.active, 3, 3)).toEqual([]);
  });
});
