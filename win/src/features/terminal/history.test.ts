import { describe, expect, it } from "vitest";
import { CommandHistory, HistoryNavigator, parseHistory } from "./history";

describe("parseHistory", () => {
  it("reads one command per line, skipping blanks and repeats in a row", () => {
    expect(parseHistory("dir\r\n\r\ndir\r\ngit status\r\n")).toEqual(["dir", "git status"]);
  });

  it("joins a line that ends in a backtick with the next one, as PSReadLine writes multi-line entries", () => {
    expect(parseHistory("foreach ($i in 1..2) {`\n  $i`\n}\nnext")).toEqual(["foreach ($i in 1..2) {\n  $i\n}", "next"]);
  });

  it("reads the zsh extended format too", () => {
    expect(parseHistory(": 1700000000:0;ls -la\n: 1700000001:0;pwd")).toEqual(["ls -la", "pwd"]);
  });
});

describe("CommandHistory", () => {
  it("appends, trims, and does not repeat the last entry", () => {
    const history = new CommandHistory();
    history.append("a\n");
    history.append("a");
    history.append("   ");
    history.append("b");
    expect(history.entries).toEqual(["a", "b"]);
  });

  it("keeps the newest entries when over capacity", () => {
    const history = new CommandHistory(2);
    ["a", "b", "c"].forEach((c) => history.append(c));
    expect(history.entries).toEqual(["b", "c"]);
  });

  it("seeds once, with what was typed before it kept after what was loaded", () => {
    const history = new CommandHistory();
    history.append("typed");
    history.seed(["old1", "old2"]);
    history.seed(["ignored"]);
    expect(history.entries).toEqual(["old1", "old2", "typed"]);
    expect(history.isSeeded).toBe(true);
  });

  it("searches newest first, all words contained, then scattered letters", () => {
    const history = new CommandHistory();
    ["git commit -m x", "dir", "git push", "gcm"].forEach((c) => history.append(c));
    expect(history.search("git")).toEqual(["git push", "git commit -m x"]);
    expect(history.search("gt cm")).toEqual(["git commit -m x"]);
    expect(history.search("")).toEqual(["gcm", "git push", "dir", "git commit -m x"]);
  });
});

describe("HistoryNavigator", () => {
  const entries = ["git status", "dir", "git push"];

  it("goes back through the entries that start with what was typed and returns to the draft", () => {
    const nav = new HistoryNavigator();
    expect(nav.back(entries, "git")).toBe("git push");
    expect(nav.back(entries, "git push")).toBe("git status");
    expect(nav.back(entries, "git status")).toBeNull();
    expect(nav.forward(entries, "git status")).toBe("git push");
    expect(nav.forward(entries, "git push")).toBe("git");
    expect(nav.isNavigating).toBe(false);
  });

  it("forward does nothing when not navigating", () => {
    expect(new HistoryNavigator().forward(entries, "")).toBeNull();
  });
});
