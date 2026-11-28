import { describe, expect, it } from "vitest";
import { DEFAULT_ALLOWLIST, decidePaneMode, isInteractive } from "./paneMode";

const allow = DEFAULT_ALLOWLIST;

describe("decidePaneMode", () => {
  it("shows the grid for the alternate screen, then mouse reporting, then an interactive command", () => {
    expect(decidePaneMode({ altScreen: true, mouse: false, command: null, allowlist: allow })).toEqual({ kind: "grid", reason: "alternateScreen" });
    expect(decidePaneMode({ altScreen: false, mouse: true, command: null, allowlist: allow })).toEqual({ kind: "grid", reason: "mouseTracking" });
    expect(decidePaneMode({ altScreen: false, mouse: false, command: "vim a.txt", allowlist: allow })).toEqual({ kind: "grid", reason: "allowlisted" });
    expect(decidePaneMode({ altScreen: false, mouse: false, command: "dir", allowlist: allow })).toEqual({ kind: "blocks" });
  });
});

describe("isInteractive", () => {
  it("strips the path, the .exe and env-style wrappers", () => {
    expect(isInteractive("C:\\Tools\\Vim\\vim.exe a", allow)).toBe(true);
    expect(isInteractive("sudo -u x nvim", allow)).toBe(true);
  });
  it("looks at every segment but not at one piped into another program", () => {
    expect(isInteractive("dir && vim a", allow)).toBe(true);
    expect(isInteractive("vim a | cat", allow)).toBe(false);
  });
  it("is not fooled by quotes", () => {
    expect(isInteractive('echo "a; vim"', allow)).toBe(false);
  });
  it("information flags and one-shot python/node/claude calls are not interactive", () => {
    expect(isInteractive("python --version", allow)).toBe(false);
    expect(isInteractive("python -c 1", allow)).toBe(false);
    expect(isInteractive("python", allow)).toBe(true);
    expect(isInteractive("node -e 1", allow)).toBe(false);
    expect(isInteractive("claude -p hi", allow)).toBe(false);
    expect(isInteractive("claude", allow)).toBe(true);
  });
  it("docker and ssh only when they open a terminal", () => {
    expect(isInteractive("docker run -it img", allow)).toBe(true);
    expect(isInteractive("docker run img", allow)).toBe(false);
    expect(isInteractive("ssh host", allow)).toBe(true);
    expect(isInteractive("ssh host ls", allow)).toBe(false);
  });
});
