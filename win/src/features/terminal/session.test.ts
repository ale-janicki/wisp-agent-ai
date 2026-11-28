import { describe, expect, it } from "vitest";
import { CommandHistory } from "./history";
import { TerminalSession } from "./session";
import { b64, headlessEngine as engine, ScriptedBackend } from "./testSupport";

async function started(shell: "pwsh" | "cmd" = "pwsh") {
  const backend = new ScriptedBackend();
  const history = new CommandHistory();
  const session = new TerminalSession({
    shell,
    directory: "C:\\work",
    home: "C:\\Users\\dev",
    backend,
    history,
    createEngine: (size) => engine({ cols: Math.min(size.cols, 40), rows: 8 }),
    now: () => 1000,
  });
  session.start({ cols: 40, rows: 8 });
  await new Promise((r) => setTimeout(r, 0));
  return { backend, history, session };
}

const prompt = (b: ScriptedBackend, cwd = "file:///C:/work") =>
  b.mark(`cwd=${cwd}`) + b.mark("A") + "PS C:\\work> " + b.mark("B");
const runs = (b: ScriptedBackend, command: string, output: string) =>
  b.mark(`cmd=${b64(command)}`) + b.mark("C") + "\r\n" + output;

describe("TerminalSession (native blocks)", () => {
  it("starts PowerShell with the marks, the nonce and the folder", async () => {
    const { backend, session } = await started();
    expect(backend.request).toMatchObject({ shell: "pwsh", cwd: "C:\\work", cols: 40, rows: 8 });
    expect(backend.request!.nonce).toMatch(/^[0-9a-f]{32}$/);
    expect(backend.request!.integration).toContain("6973");
    expect(session.phase).toEqual({ kind: "running" });
    expect(session.isNative).toBe(true);
    expect(session.mode).toEqual({ kind: "blocks" });
  });

  it("refuses a line before the first prompt, takes it at the prompt, and types it into the shell", async () => {
    const { backend, session, history } = await started();
    expect(session.submit("dir")).toBe(false);
    backend.output(prompt(backend));
    await session.whenIdle();
    expect(session.canSubmit).toBe(true);
    expect(session.submit("dir")).toBe(true);
    expect(backend.writes).toEqual(["\x1bdir\r"]);
    expect(history.entries).toEqual(["dir"]);
  });

  it("makes a block of a command, with its output read off the screen, and goes back to the prompt", async () => {
    const { backend, session } = await started();
    backend.output(prompt(backend));
    session.submit("echo hi");
    backend.output(runs(backend, "echo hi", "hi\r\n"));
    await session.whenIdle();
    expect(session.blocks.running?.command).toBe("echo hi");
    expect(session.activity).toEqual({ state: "running", command: "echo hi" });

    backend.output(backend.mark("D;0") + prompt(backend, "file:///C:/work/sub"));
    await session.whenIdle();
    const [block] = session.blocks.blocks;
    expect(block!.status).toEqual({ kind: "finished", code: 0 });
    expect(block!.output!.map((l) => l.text)).toEqual(["hi"]);
    expect(session.activity).toEqual({ state: "succeeded", command: "echo hi" });
    expect(session.directory).toBe("C:\\work\\sub");
    expect(session.canSubmit).toBe(true);
  });

  it("keeps all the rows of an output longer than the screen", async () => {
    const { backend, session } = await started();
    backend.output(prompt(backend));
    backend.output(runs(backend, "seq", Array.from({ length: 30 }, (_, i) => `n${i + 1}\r\n`).join("")));
    backend.output(backend.mark("D;0") + prompt(backend));
    await session.whenIdle();
    const lines = session.blocks.blocks[0]!.output!.map((l) => l.text);
    expect(lines).toHaveLength(30);
    expect(lines[0]).toBe("n1");
    expect(lines[29]).toBe("n30");
  });

  it("an output with no line break at the end still has its last row", async () => {
    const { backend, session } = await started();
    backend.output(prompt(backend));
    backend.output(runs(backend, "x", "a\r\nb"));
    backend.output(backend.mark("D;1") + prompt(backend));
    await session.whenIdle();
    expect(session.blocks.blocks[0]!.output!.map((l) => l.text)).toEqual(["a", "b"]);
    expect(session.activity.state).toBe("failed");
  });

  it("shows the shell's own screen for a program on the alternate screen, then the blocks again", async () => {
    const { backend, session } = await started();
    backend.output(prompt(backend));
    backend.output(runs(backend, "mytool", "") + "\x1b[?1049h");
    await session.whenIdle();
    expect(session.mode).toEqual({ kind: "grid", reason: "alternateScreen" });
    backend.output("\x1b[?1049l" + backend.mark("D;0") + prompt(backend));
    await session.whenIdle();
    expect(session.mode).toEqual({ kind: "blocks" });
    expect(session.blocks.blocks[0]!.output).toEqual([]);
  });

  it("an allowlisted command shows the grid from its start", async () => {
    const { backend, session } = await started();
    backend.output(prompt(backend));
    backend.output(runs(backend, "vim a.txt", ""));
    await session.whenIdle();
    expect(session.mode).toEqual({ kind: "grid", reason: "allowlisted" });
  });

  it("the person can switch to the grid and back", async () => {
    const { backend, session } = await started();
    backend.output(prompt(backend));
    await session.whenIdle();
    session.toggleGrid();
    expect(session.mode).toEqual({ kind: "grid", reason: "manual" });
    session.toggleGrid();
    expect(session.mode).toEqual({ kind: "blocks" });
  });

  it("clear drops the blocks", async () => {
    const { backend, session } = await started();
    backend.output(prompt(backend));
    backend.output(runs(backend, "a", "x\r\n") + backend.mark("D;0") + prompt(backend));
    backend.output(runs(backend, "cls", "") + backend.mark("D;0") + prompt(backend));
    await session.whenIdle();
    expect(session.blocks.blocks).toEqual([]);
  });

  it("a command whose Control-C is sent shows as interrupted", async () => {
    const { backend, session } = await started();
    backend.output(prompt(backend));
    backend.output(runs(backend, "ping -t x", ""));
    await session.whenIdle();
    session.write("\x03");
    expect(session.blocks.running?.interrupted).toBe(true);
    expect(backend.writes).toEqual(["\x03"]);
  });

  it("runs a block again by typing its command, only at a prompt", async () => {
    const { backend, session } = await started();
    backend.output(prompt(backend));
    backend.output(runs(backend, "dir", "") + backend.mark("D;0") + prompt(backend));
    await session.whenIdle();
    expect(session.rerun(1)).toEqual({ ok: true, action: { kind: "type", text: "\x1bdir\r" } });
    expect(backend.writes).toEqual(["\x1bdir\r"]);
    backend.output(runs(backend, "dir", ""));
    await session.whenIdle();
    expect(session.rerun(1)).toMatchObject({ ok: false });
  });

  it("reports the shell's end and the exit code", async () => {
    const { backend, session } = await started();
    backend.output(prompt(backend));
    backend.exit(3);
    await session.whenIdle();
    expect(session.phase).toEqual({ kind: "ended", code: 3 });
  });

  it("a shell that declines the marks is a plain terminal with the grid", async () => {
    const { backend, session } = await started();
    backend.output(backend.mark("declined"));
    await session.whenIdle();
    expect(session.isNative).toBe(false);
    expect(session.mode).toEqual({ kind: "grid", reason: "plainShell" });
  });

  it("look-alike marks from a program make no block", async () => {
    const { backend, session } = await started();
    backend.output(prompt(backend));
    backend.output(runs(backend, "cat evil", "\x1b]6973;wrong;C\x07\x1b]133;C\x07"));
    backend.output(backend.mark("D;0") + prompt(backend));
    await session.whenIdle();
    expect(session.blocks.blocks).toHaveLength(1);
  });

  it("passes the pane's size to the pty once it runs", async () => {
    const { backend, session } = await started();
    session.resize({ cols: 90, rows: 20 });
    expect(backend.resizes).toEqual([[90, 20]]);
  });

  it("a failed launch says why and can be reopened", async () => {
    const backend = new ScriptedBackend();
    backend.failSpawn = "sem pwsh";
    const session = new TerminalSession({
      shell: "pwsh", directory: "C:\\", home: "C:\\Users\\dev", backend, history: new CommandHistory(), createEngine: engine,
    });
    session.start();
    await new Promise((r) => setTimeout(r, 0));
    expect(session.phase).toEqual({ kind: "failed", message: "Não abriu o shell: sem pwsh" });
    backend.failSpawn = null;
    session.reopen();
    await new Promise((r) => setTimeout(r, 0));
    expect(session.phase).toEqual({ kind: "running" });
  });
});

describe("TerminalSession (plain shell)", () => {
  it("cmd gets no script and shows the grid", async () => {
    const { backend, session } = await started("cmd");
    expect(backend.request).toMatchObject({ shell: "cmd", integration: null, nonce: null });
    expect(session.isNative).toBe(false);
    expect(session.mode).toEqual({ kind: "grid", reason: "plainShell" });
    expect(session.submit("dir")).toBe(false);
  });

  it("closing kills the shell", async () => {
    const { backend, session } = await started("cmd");
    session.close();
    expect(backend.killed).toBe(true);
    expect(session.isRunning).toBe(false);
  });
});
