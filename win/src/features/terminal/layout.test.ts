import { describe, expect, it } from "vitest";
import { matchesQuery, TerminalLayout, tabTitle } from "./layout";

const two = () => {
  const layout = new TerminalLayout();
  layout.addTab("a", "t1");
  layout.split("horizontal", "b");
  return layout;
};

describe("tabs", () => {
  it("adding a tab selects it and focuses its session", () => {
    const layout = new TerminalLayout();
    layout.addTab("a", "t1");
    layout.addTab("b", "t2");
    expect(layout.selectedTabId).toBe("t2");
    expect(layout.focusedSession).toBe("b");
  });

  it("selects by index, last, and wraps adjacent", () => {
    const layout = new TerminalLayout();
    ["a", "b", "c"].forEach((s, i) => layout.addTab(s, `t${i}`));
    expect(layout.selectTabAt(0)).toBe(true);
    expect(layout.selectTabAt(7)).toBe(false);
    layout.selectAdjacentTab(-1);
    expect(layout.selectedTabId).toBe("t2");
    layout.selectAdjacentTab(1);
    expect(layout.selectedTabId).toBe("t0");
    layout.selectTabAt(0);
    layout.selectLastTab();
    expect(layout.selectedTabId).toBe("t2");
  });

  it("moves a tab and the selected one", () => {
    const layout = new TerminalLayout();
    ["a", "b", "c"].forEach((s, i) => layout.addTab(s, `t${i}`));
    layout.moveTab(0, 2);
    expect(layout.tabs.map((t) => t.id)).toEqual(["t1", "t2", "t0"]);
    layout.selectTab("t2");
    expect(layout.moveSelectedTab(-1)).toBe(true);
    expect(layout.tabs.map((t) => t.id)).toEqual(["t2", "t1", "t0"]);
  });

  it("closing the selected tab selects its neighbour", () => {
    const layout = new TerminalLayout();
    ["a", "b", "c"].forEach((s, i) => layout.addTab(s, `t${i}`));
    layout.selectTab("t1");
    expect(layout.closeTab("t1")).toEqual(["b"]);
    expect(layout.selectedTabId).toBe("t2");
  });

  it("a blank title gives the automatic one back", () => {
    const layout = new TerminalLayout();
    layout.addTab("a", "t1");
    layout.rename("t1", "  casa ");
    expect(layout.tabs[0]!.customTitle).toBe("casa");
    layout.rename("t1", "  ");
    expect(layout.tabs[0]!.customTitle).toBeNull();
  });
});

describe("panes", () => {
  it("a split puts the new pane second, focused, 50/50", () => {
    const layout = two();
    expect(layout.selectedTab!.sessions).toEqual(["a", "b"]);
    expect(layout.focusedSession).toBe("b");
    expect(layout.selectedTab!.frames).toEqual({ a: { x: 0, y: 0, w: 0.5, h: 1 }, b: { x: 0.5, y: 0, w: 0.5, h: 1 } });
  });

  it("refuses a session already in a tab", () => {
    const layout = two();
    expect(layout.split("vertical", "a")).toBe(false);
  });

  it("closing a pane hands the focus to its sibling; the last pane closes the tab", () => {
    const layout = two();
    expect(layout.close("b")).toBe("pane");
    expect(layout.focusedSession).toBe("a");
    expect(layout.close("a")).toBe("tab");
    expect(layout.tabs).toEqual([]);
  });

  it("moves the focus to the closest pane on that side", () => {
    const layout = two();
    expect(layout.moveFocus("left")).toBe(true);
    expect(layout.focusedSession).toBe("a");
    expect(layout.moveFocus("left")).toBe(false);
    layout.split("vertical", "c");
    expect(layout.selectedTab!.frames.c).toEqual({ x: 0, y: 0.5, w: 0.5, h: 0.5 });
    expect(layout.moveFocus("up")).toBe(true);
    expect(layout.focusedSession).toBe("a");
    expect(layout.moveFocus("right")).toBe(true);
    expect(layout.focusedSession).toBe("b");
  });

  it("cycles through the panes", () => {
    const layout = two();
    layout.focusAdjacentPane(1);
    expect(layout.focusedSession).toBe("a");
    layout.focusAdjacentPane(-1);
    expect(layout.focusedSession).toBe("b");
  });

  it("keeps a divider ratio inside 0.15...0.85", () => {
    const layout = two();
    layout.resize([], 0.99);
    expect(layout.selectedTab!.dividers[0]!.ratio).toBe(0.85);
    layout.resize([], 0.01);
    expect(layout.selectedTab!.dividers[0]!.ratio).toBe(0.15);
    layout.resize([], Number.NaN);
    expect(layout.selectedTab!.dividers[0]!.ratio).toBe(0.15);
  });

  it("turns a pointer position into a ratio of the split's own area", () => {
    const layout = two();
    layout.moveFocus("left");
    layout.split("vertical", "c");
    const inner = layout.selectedTab!.dividers.find((d) => d.path.join() === "0")!;
    expect(inner.bounds).toEqual({ x: 0, y: 0, w: 0.5, h: 1 });
    expect(inner.ratioAt({ x: 0.2, y: 0.25 })).toBe(0.25);
  });

  it("resizes the nearest split on that axis", () => {
    const layout = two();
    expect(layout.resizeFocused("left")).toBe(true);
    expect(layout.selectedTab!.dividers[0]!.ratio).toBeCloseTo(0.45);
    expect(layout.resizeFocused("up")).toBe(false);
  });

  it("maximize shows only the focused pane and needs more than one", () => {
    const layout = new TerminalLayout();
    layout.addTab("a", "t1");
    expect(layout.toggleMaximize()).toBe(false);
    layout.split("horizontal", "b");
    expect(layout.toggleMaximize()).toBe(true);
    expect(layout.selectedTab!.frames).toEqual({ b: { x: 0, y: 0, w: 1, h: 1 } });
    expect(layout.selectedTab!.dividers).toEqual([]);
    layout.toggleMaximize();
    expect(Object.keys(layout.selectedTab!.frames)).toHaveLength(2);
  });

  it("focusing a pane of another tab selects that tab", () => {
    const layout = two();
    layout.addTab("z", "t2");
    layout.focus("a");
    expect(layout.selectedTabId).toBe("t1");
    expect(layout.focusedSession).toBe("a");
  });

  it("a reopened tab keeps its shape with new session ids", () => {
    const layout = two();
    const tab = layout.selectedTab!;
    const copy = tab.remapped({ a: "x", b: "y" });
    expect(copy.sessions).toEqual(["x", "y"]);
    expect(copy.focused).toBe("y");
    layout.closeTab(tab.id);
    layout.insertTab(copy, 0);
    expect(layout.selectedTabId).toBe(tab.id);
  });
});

describe("titles and search", () => {
  it("the title is the custom one, else the running command's name, else the fallback", () => {
    expect(tabTitle("casa", "dir", "x")).toBe("casa");
    expect(tabTitle(null, "sudo git push", "x")).toBe("git");
    expect(tabTitle(null, "C:\\bin\\node.exe app.js", "x")).toBe("node.exe");
    expect(tabTitle(null, null, "pasta")).toBe("pasta");
  });

  it("every word has to be in some field, ignoring case and accents", () => {
    expect(matchesQuery("proj ação", ["Projeto", "ACAO ao vivo"])).toBe(true);
    expect(matchesQuery("proj zzz", ["Projeto"])).toBe(false);
    expect(matchesQuery("  ", ["x"])).toBe(true);
  });
});
