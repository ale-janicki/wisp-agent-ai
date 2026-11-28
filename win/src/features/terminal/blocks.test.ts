import { describe, expect, it } from "vitest";
import { BlockTracker, blockDuration, clearsScreen, decideRerun } from "./blocks";
import type { ShellEvent } from "./marks";

const run = (tracker: BlockTracker, command: string, code: number | null, at = 0) => {
  const steps: ShellEvent[] = [
    { type: "promptStart" },
    { type: "promptEnd" },
    { type: "command", text: command },
    { type: "commandStart" },
    { type: "commandEnd", exitCode: code },
  ];
  steps.forEach((event, i) => tracker.apply(event, at + i * 100));
};

describe("BlockTracker", () => {
  it("a command between a prompt and its end becomes a finished block", () => {
    const tracker = new BlockTracker();
    tracker.apply({ type: "directory", report: "file:///C:/work" }, 0);
    run(tracker, "dir", 0, 1000);
    const [block] = tracker.blocks;
    expect(block).toMatchObject({ id: 1, command: "dir", directory: "C:\\work", status: { kind: "finished", code: 0 } });
    expect(block!.finishedAt! - block!.startedAt).toBe(100);
  });

  it("a command with no exit code is lost", () => {
    const tracker = new BlockTracker();
    run(tracker, "x", null);
    expect(tracker.blocks[0]!.status).toEqual({ kind: "lost" });
  });

  it("a new prompt while a block runs closes it as lost", () => {
    const tracker = new BlockTracker();
    tracker.apply({ type: "promptStart" }, 0);
    tracker.apply({ type: "command", text: "a" }, 0);
    tracker.apply({ type: "commandStart" }, 0);
    expect(tracker.running?.command).toBe("a");
    tracker.apply({ type: "promptStart" }, 5);
    expect(tracker.running).toBeUndefined();
    expect(tracker.blocks[0]!.status).toEqual({ kind: "lost" });
  });

  it("a command start with no prompt before it makes no block", () => {
    const tracker = new BlockTracker();
    tracker.apply({ type: "commandStart" }, 0);
    expect(tracker.blocks).toEqual([]);
  });

  it("the alternate screen suspends the tracking and a new prompt lifts it", () => {
    const tracker = new BlockTracker();
    tracker.apply({ type: "promptStart" }, 0);
    tracker.apply({ type: "alternateScreen", on: true }, 0);
    expect(tracker.suspended).toBe(true);
    tracker.apply({ type: "command", text: "vim" }, 0);
    tracker.apply({ type: "commandStart" }, 0);
    expect(tracker.blocks).toEqual([]);
    tracker.apply({ type: "promptStart" }, 0);
    expect(tracker.suspended).toBe(false);
  });

  it("keeps at most 500 blocks", () => {
    const tracker = new BlockTracker();
    for (let i = 0; i < 503; i++) run(tracker, `c${i}`, 0);
    expect(tracker.blocks).toHaveLength(500);
    expect(tracker.blocks[0]!.command).toBe("c3");
  });

  it("clearing the scrollback drops every block", () => {
    const tracker = new BlockTracker();
    run(tracker, "a", 0);
    tracker.apply({ type: "cleared", scrollback: true }, 0);
    expect(tracker.blocks).toEqual([]);
  });

  it("reports the activity of the last block", () => {
    const tracker = new BlockTracker();
    expect(tracker.activity).toEqual({ state: "idle", command: null });
    tracker.apply({ type: "promptStart" }, 0);
    tracker.apply({ type: "command", text: "sleep" }, 0);
    tracker.apply({ type: "commandStart" }, 0);
    expect(tracker.activity).toEqual({ state: "running", command: "sleep" });
    tracker.apply({ type: "commandEnd", exitCode: 2 }, 1);
    expect(tracker.activity).toEqual({ state: "failed", code: 2, command: "sleep" });
  });

  it("marks the running block interrupted once", () => {
    const tracker = new BlockTracker();
    tracker.apply({ type: "promptStart" }, 0);
    tracker.apply({ type: "commandStart" }, 0);
    expect(tracker.markInterrupted()).toBe(true);
    expect(tracker.markInterrupted()).toBe(false);
  });

  it("stores the output of a block by id", () => {
    const tracker = new BlockTracker();
    run(tracker, "a", 0);
    tracker.setOutput(1, [{ text: "hi", runs: [] }]);
    expect(tracker.blocks[0]!.output).toEqual([{ text: "hi", runs: [] }]);
  });

  it("a shell that ends closes the running block", () => {
    const tracker = new BlockTracker();
    tracker.apply({ type: "promptStart" }, 0);
    tracker.apply({ type: "commandStart" }, 0);
    tracker.shellEnded(9);
    expect(tracker.blocks[0]!.status).toEqual({ kind: "lost" });
  });
});

describe("decideRerun", () => {
  it("types the command into a shell at its prompt, wrapped when it takes bracketed paste", () => {
    expect(decideRerun("dir\n", true, true)).toEqual({ ok: true, action: { kind: "type", text: "\x1b\x1b[200~dir\x1b[201~\r" } });
    expect(decideRerun("dir", false, true)).toEqual({ ok: true, action: { kind: "type", text: "\x1bdir\r" } });
  });
  it("refuses a busy shell and an empty command", () => {
    expect(decideRerun("dir", true, false)).toEqual({ ok: false, refusal: "O shell está ocupado: espere o comando atual terminar." });
    expect(decideRerun("  \n", true, true)).toEqual({ ok: false, refusal: "Sem comando para colar de novo." });
  });
  it("strips control characters", () => {
    expect(decideRerun("a\x07b", false, true)).toEqual({ ok: true, action: { kind: "type", text: "\x1bab\r" } });
  });
});

describe("blockDuration", () => {
  it("uses the comma and the Mac's units", () => {
    expect(blockDuration(0.34)).toBe("0,3 s");
    expect(blockDuration(12.2)).toBe("12 s");
    expect(blockDuration(75)).toBe("1 min 15 s");
    expect(blockDuration(7500)).toBe("2 h 5 min");
  });
});

describe("clearsScreen", () => {
  it("recognises clear, cls and Clear-Host and nothing chained", () => {
    expect(clearsScreen("clear")).toBe(true);
    expect(clearsScreen("cls")).toBe(true);
    expect(clearsScreen("Clear-Host")).toBe(true);
    expect(clearsScreen("clear; dir")).toBe(false);
    expect(clearsScreen("echo clear")).toBe(false);
  });
});
