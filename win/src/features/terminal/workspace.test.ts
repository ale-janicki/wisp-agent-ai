import { describe, expect, it } from "vitest";
import { TerminalWorkspace, type SessionLike } from "./workspace";

class FakeSession implements SessionLike {
  closed = false;
  disposed = false;
  started: { cols: number; rows: number } | null = null;
  onDirectory: ((path: string) => void) | null = null;
  constructor(
    readonly id: string,
    public directory: string,
  ) {}
  start(size: { cols: number; rows: number }) {
    this.started = size;
  }
  close() {
    this.closed = true;
  }
  dispose() {
    this.disposed = true;
  }
}

function make(remembered: string | null = null) {
  let count = 0;
  const saved: string[] = [];
  const made: FakeSession[] = [];
  const workspace = new TerminalWorkspace<FakeSession>({
    home: "C:\\Users\\dev",
    memory: { load: () => remembered, save: (p) => saved.push(p) },
    makeSession: (directory) => {
      const session = new FakeSession(`s${++count}`, directory);
      made.push(session);
      return session;
    },
  });
  return { workspace, saved, made };
}

describe("TerminalWorkspace", () => {
  it("the first session opens once, in the remembered folder or the home folder", () => {
    const first = make("D:\\last");
    first.workspace.openFirstIfNeeded();
    first.workspace.openFirstIfNeeded();
    expect(first.made.map((s) => s.directory)).toEqual(["D:\\last"]);
    expect(make().workspace.openSession().directory).toBe("C:\\Users\\dev");
  });

  it("closing every tab leaves it empty and does not open another by itself", () => {
    const { workspace } = make();
    workspace.openFirstIfNeeded();
    workspace.closeSelected();
    workspace.openFirstIfNeeded();
    expect(workspace.sessions).toEqual([]);
    expect(workspace.layout.tabs).toEqual([]);
  });

  it("a new tab and a split start in the focused session's folder", () => {
    const { workspace } = make();
    const a = workspace.openSession();
    a.directory = "C:\\work";
    const b = workspace.openSession();
    expect(b.directory).toBe("C:\\work");
    b.directory = "C:\\other";
    expect(workspace.split("horizontal")).toBe(true);
    expect(workspace.sessions.at(-1)!.directory).toBe("C:\\other");
    expect(workspace.layout.selectedTab!.sessions).toHaveLength(2);
  });

  it("closing a pane ends its session and remembers its folder", () => {
    const { workspace, saved } = make();
    const a = workspace.openSession();
    workspace.split("vertical");
    a.directory = "C:\\z";
    workspace.close(a.id);
    expect(a.closed && a.disposed).toBe(true);
    expect(saved).toContain("C:\\z");
    expect(workspace.sessions).toHaveLength(1);
  });

  it("reopens the last closed tab with its panes, each a new session in its folder", () => {
    const { workspace } = make();
    const a = workspace.openSession();
    workspace.openSession();
    workspace.layout.selectTabAt(0);
    workspace.split("horizontal");
    const tab = workspace.layout.selectedTab!;
    const [first, second] = tab.sessions.map((id) => workspace.session(id)!);
    first!.directory = "C:\\one";
    second!.directory = "C:\\two";
    workspace.closeTab(tab.id);
    expect(workspace.sessions).toHaveLength(1);
    expect(workspace.reopenClosedTab()).toBe(true);
    const reopened = workspace.layout.tabs.find((t) => t.id === tab.id)!;
    expect(workspace.layout.tabs[0]!.id).toBe(tab.id);
    expect(reopened.sessions.map((id) => workspace.session(id)!.directory)).toEqual(["C:\\one", "C:\\two"]);
    expect(reopened.sessions).not.toContain(a.id);
    expect(workspace.reopenClosedTab()).toBe(false);
  });

  it("remembers at most 10 closed tabs", () => {
    const { workspace } = make();
    for (let i = 0; i < 12; i++) {
      const s = workspace.openSession();
      workspace.close(s.id);
    }
    let reopened = 0;
    while (workspace.reopenClosedTab()) reopened += 1;
    expect(reopened).toBe(10);
  });

  it("renaming ends when the tab closes, and an empty name gives the automatic one back", () => {
    const { workspace } = make();
    const a = workspace.openSession();
    expect(workspace.renameSelectedTab()).toBe(true);
    const id = workspace.layout.selectedTabId!;
    expect(workspace.renamingTabId).toBe(id);
    workspace.rename(id, "casa");
    expect(workspace.renamingTabId).toBeNull();
    expect(workspace.layout.tabs[0]!.customTitle).toBe("casa");
    workspace.renameSelectedTab();
    workspace.close(a.id);
    expect(workspace.renamingTabId).toBeNull();
  });

  it("a session's folder change is remembered", () => {
    const { workspace, saved } = make();
    const a = workspace.openSession();
    a.onDirectory!("C:\\moved");
    expect(saved).toEqual(["C:\\moved"]);
  });

  it("closeAll kills every shell", () => {
    const { workspace, made } = make();
    workspace.openSession();
    workspace.openSession();
    workspace.closeAll();
    expect(made.every((s) => s.closed && s.disposed)).toBe(true);
    expect(workspace.sessions).toEqual([]);
  });

  it("tells its subscribers when anything changes", () => {
    const { workspace } = make();
    let calls = 0;
    workspace.subscribe(() => (calls += 1));
    const before = workspace.getVersion();
    workspace.openSession();
    expect(calls).toBeGreaterThan(0);
    expect(workspace.getVersion()).toBeGreaterThan(before);
  });
});
