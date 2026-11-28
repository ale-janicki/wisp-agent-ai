import { describe, expect, it } from "vitest";
import { shortcutFor, type KeyLike } from "./shortcuts";

const key = (k: string, mods: Partial<KeyLike> = {}, code = ""): KeyLike => ({
  key: k,
  code,
  ctrlKey: false,
  shiftKey: false,
  altKey: false,
  metaKey: false,
  ...mods,
});
const ctrlShift = { ctrlKey: true, shiftKey: true };
const ctrlAltShift = { ctrlKey: true, altKey: true, shiftKey: true };

describe("shortcutFor (Cmd on the Mac is Ctrl+Shift here, so Ctrl+D, Ctrl+W and company still reach the shell)", () => {
  it("tabs and panes", () => {
    expect(shortcutFor(key("T", ctrlShift))).toEqual({ type: "newTab" });
    expect(shortcutFor(key("W", ctrlShift))).toEqual({ type: "closePane" });
    expect(shortcutFor(key("T", ctrlAltShift))).toEqual({ type: "reopenTab" });
    expect(shortcutFor(key("D", ctrlShift))).toEqual({ type: "split", axis: "horizontal" });
    expect(shortcutFor(key("D", ctrlAltShift))).toEqual({ type: "split", axis: "vertical" });
    expect(shortcutFor(key("Enter", ctrlShift))).toEqual({ type: "maximize" });
    expect(shortcutFor(key("F2"))).toEqual({ type: "rename" });
  });

  it("Ctrl+1..8 name the tabs and Ctrl+9 the last one", () => {
    expect(shortcutFor(key("1", { ctrlKey: true }))).toEqual({ type: "selectTab", index: 0 });
    expect(shortcutFor(key("8", { ctrlKey: true }))).toEqual({ type: "selectTab", index: 7 });
    expect(shortcutFor(key("9", { ctrlKey: true }))).toEqual({ type: "lastTab" });
    expect(shortcutFor(key("0", { ctrlKey: true }))).toBeNull();
  });

  it("moves between tabs, panes and moves tabs", () => {
    expect(shortcutFor(key("Tab", { ctrlKey: true }))).toEqual({ type: "adjacentTab", offset: 1 });
    expect(shortcutFor(key("Tab", { ctrlKey: true, shiftKey: true }))).toEqual({ type: "adjacentTab", offset: -1 });
    expect(shortcutFor(key("{", ctrlShift, "BracketLeft"))).toEqual({ type: "adjacentPane", offset: -1 });
    expect(shortcutFor(key("}", ctrlShift, "BracketRight"))).toEqual({ type: "adjacentPane", offset: 1 });
    expect(shortcutFor(key("]", { ctrlKey: true, altKey: true }, "BracketRight"))).toEqual({ type: "adjacentTab", offset: 1 });
    expect(shortcutFor(key("ArrowLeft", ctrlAltShift))).toEqual({ type: "moveTab", offset: -1 });
    expect(shortcutFor(key("ArrowRight", ctrlAltShift))).toEqual({ type: "moveTab", offset: 1 });
  });

  it("Alt+arrows move the focus between panes and Alt+Shift+arrows resize", () => {
    expect(shortcutFor(key("ArrowUp", { altKey: true }))).toEqual({ type: "moveFocus", direction: "up" });
    expect(shortcutFor(key("ArrowRight", { altKey: true, shiftKey: true }))).toEqual({ type: "resizePane", direction: "right" });
  });

  it("view and clipboard", () => {
    expect(shortcutFor(key("B", ctrlShift))).toEqual({ type: "toggleTabs" });
    expect(shortcutFor(key("F", ctrlShift))).toEqual({ type: "find" });
    expect(shortcutFor(key("G", ctrlShift))).toEqual({ type: "toggleGrid" });
    expect(shortcutFor(key("C", ctrlShift))).toEqual({ type: "copy", what: "command" });
    expect(shortcutFor(key("C", ctrlAltShift))).toEqual({ type: "copy", what: "output" });
  });

  it("never takes the keys a shell needs", () => {
    for (const k of ["c", "d", "w", "t", "l", "r", "z", "u", "a", "e", "k"]) {
      expect(shortcutFor(key(k, { ctrlKey: true }))).toBeNull();
    }
    expect(shortcutFor(key("a"))).toBeNull();
    expect(shortcutFor(key("D", { metaKey: true, ctrlKey: true, shiftKey: true }))).toBeNull();
  });
});
