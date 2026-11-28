import type { Axis, Direction } from "./layout";

export type KeyLike = { key: string; code: string; ctrlKey: boolean; shiftKey: boolean; altKey: boolean; metaKey: boolean };

export type Shortcut =
  | { type: "newTab" }
  | { type: "closePane" }
  | { type: "reopenTab" }
  | { type: "split"; axis: Axis }
  | { type: "maximize" }
  | { type: "rename" }
  | { type: "selectTab"; index: number }
  | { type: "lastTab" }
  | { type: "adjacentTab"; offset: 1 | -1 }
  | { type: "adjacentPane"; offset: 1 | -1 }
  | { type: "moveTab"; offset: 1 | -1 }
  | { type: "moveFocus"; direction: Direction }
  | { type: "resizePane"; direction: Direction }
  | { type: "toggleTabs" }
  | { type: "find" }
  | { type: "toggleGrid" }
  | { type: "copy"; what: "command" | "output" };

const ARROWS: Record<string, Direction> = { ArrowLeft: "left", ArrowRight: "right", ArrowUp: "up", ArrowDown: "down" };

export function shortcutFor(e: KeyLike): Shortcut | null {
  if (e.metaKey) return null;
  const { ctrlKey: ctrl, shiftKey: shift, altKey: alt } = e;
  const letter = e.key.length === 1 ? e.key.toLowerCase() : "";
  const arrow = ARROWS[e.key];

  if (e.key === "F2" && !ctrl && !alt && !shift) return { type: "rename" };
  if (!ctrl && alt && arrow) return shift ? { type: "resizePane", direction: arrow } : { type: "moveFocus", direction: arrow };
  if (!ctrl) return null;

  if (!shift && !alt) {
    if (e.key === "Tab") return { type: "adjacentTab", offset: 1 };
    if (/^[1-9]$/.test(e.key)) return e.key === "9" ? { type: "lastTab" } : { type: "selectTab", index: Number(e.key) - 1 };
    return null;
  }
  if (shift && !alt) {
    if (e.key === "Tab") return { type: "adjacentTab", offset: -1 };
    if (e.key === "Enter") return { type: "maximize" };
    if (e.code === "BracketLeft" || e.key === "{" || e.key === "[") return { type: "adjacentPane", offset: -1 };
    if (e.code === "BracketRight" || e.key === "}" || e.key === "]") return { type: "adjacentPane", offset: 1 };
    switch (letter) {
      case "t": return { type: "newTab" };
      case "w": return { type: "closePane" };
      case "d": return { type: "split", axis: "horizontal" };
      case "b": return { type: "toggleTabs" };
      case "f": return { type: "find" };
      case "g": return { type: "toggleGrid" };
      case "c": return { type: "copy", what: "command" };
      default: return null;
    }
  }
  if (alt && !shift) {
    if (e.code === "BracketLeft" || e.key === "[") return { type: "adjacentTab", offset: -1 };
    if (e.code === "BracketRight" || e.key === "]") return { type: "adjacentTab", offset: 1 };
    return null;
  }
  if (e.key === "ArrowLeft") return { type: "moveTab", offset: -1 };
  if (e.key === "ArrowRight") return { type: "moveTab", offset: 1 };
  switch (letter) {
    case "t": return { type: "reopenTab" };
    case "d": return { type: "split", axis: "vertical" };
    case "c": return { type: "copy", what: "output" };
    default: return null;
  }
}
