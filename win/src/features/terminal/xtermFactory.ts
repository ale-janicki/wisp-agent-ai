import { FitAddon } from "@xterm/addon-fit";
import { SearchAddon } from "@xterm/addon-search";
import { WebLinksAddon } from "@xterm/addon-web-links";
import { Terminal } from "@xterm/xterm";
import "@xterm/xterm/css/xterm.css";
import { ANSI16, TERMINAL_ACCENT, TERMINAL_BACKGROUND, TERMINAL_FOREGROUND } from "./palette";
import type { Engine, TermLike } from "./session";
import { shortcutFor } from "./shortcuts";

const FONT = '"Cascadia Mono", "Cascadia Code", Consolas, "Courier New", monospace';
const SCROLLBACK = 50_000;

export function createXtermEngine(size: { cols: number; rows: number }): Engine {
  const term = new Terminal({
    cols: size.cols,
    rows: size.rows,
    scrollback: SCROLLBACK,
    allowProposedApi: true,
    cursorBlink: true,
    fontFamily: FONT,
    fontSize: 13,
    theme: {
      background: TERMINAL_BACKGROUND,
      foreground: TERMINAL_FOREGROUND,
      cursor: TERMINAL_ACCENT,
      selectionBackground: "rgba(163, 214, 92, 0.35)",
      black: ANSI16[0], red: ANSI16[1], green: ANSI16[2], yellow: ANSI16[3],
      blue: ANSI16[4], magenta: ANSI16[5], cyan: ANSI16[6], white: ANSI16[7],
      brightBlack: ANSI16[8], brightRed: ANSI16[9], brightGreen: ANSI16[10], brightYellow: ANSI16[11],
      brightBlue: ANSI16[12], brightMagenta: ANSI16[13], brightCyan: ANSI16[14], brightWhite: ANSI16[15],
    },
  });
  const fit = new FitAddon();
  const search = new SearchAddon();
  term.loadAddon(fit);
  term.loadAddon(search);
  term.loadAddon(new WebLinksAddon((_event, uri) => window.open(uri, "_blank", "noopener")));
  let opened = false;

  term.attachCustomKeyEventHandler((event) => {
    if (event.type !== "keydown") return true;
    if (event.ctrlKey && !event.shiftKey && !event.altKey && event.key.toLowerCase() === "c" && term.hasSelection()) {
      void navigator.clipboard.writeText(term.getSelection());
      return false;
    }
    return shortcutFor(event) === null;
  });

  return {
    term: term as unknown as TermLike,
    attach(host) {
      if (!opened) {
        term.open(host);
        opened = true;
      } else if (term.element && term.element.parentElement !== host) {
        host.appendChild(term.element);
      }
    },
    fit() {
      const dims = fit.proposeDimensions();
      return dims && Number.isFinite(dims.cols) && Number.isFinite(dims.rows) ? { cols: dims.cols, rows: dims.rows } : null;
    },
    focus: () => term.focus(),
    selection: () => (term.hasSelection() ? term.getSelection() : ""),
    find: {
      next: (query) => search.findNext(query),
      previous: (query) => search.findPrevious(query),
      clear: () => search.clearDecorations(),
    },
    dispose: () => term.dispose(),
  };
}
