import { useCallback, useEffect, useLayoutEffect, useMemo, useRef, useState, type KeyboardEvent } from "react";
import { CompletionMenu } from "./CompletionMenu";
import { commonPrefix, complete, type Completion } from "./completion";
import type { CompletionSource } from "./completionSource";
import { HistoryNavigator, type CommandHistory } from "./history";
import type { TerminalSession } from "./session";
import styles from "./Pane.module.css";

export const PLACEHOLDER_IDLE = "Digite um comando (⇧↩ para nova linha)";
export const PLACEHOLDER_RUNNING = "Comando em execução: as teclas vão para o programa";
export const PLACEHOLDER_ENDED = "Sessão encerrada";

type Search = { query: string; results: string[]; selection: number };

type Props = {
  session: TerminalSession;
  history: CommandHistory;
  completion: CompletionSource;
  onCompletionLoad: (listener: () => void) => () => void;
  focusKey: number;
  active: boolean;
};

export function InputEditor({ session, history, completion, onCompletionLoad, focusKey, active }: Props) {
  const [text, setText] = useState("");
  const [items, setItems] = useState<Completion[]>([]);
  const [selection, setSelection] = useState(0);
  const [moved, setMoved] = useState(false);
  const [search, setSearch] = useState<Search | null>(null);
  const area = useRef<HTMLTextAreaElement>(null);
  const navigator = useRef(new HistoryNavigator());
  const cursor = useRef<number | null>(null);

  const ended = session.phase.kind === "ended" || session.phase.kind === "failed";
  const running = session.isCommandRunning;
  const disabled = ended || running || !session.isRunning;
  const placeholder = ended ? PLACEHOLDER_ENDED : running ? PLACEHOLDER_RUNNING : PLACEHOLDER_IDLE;

  useEffect(() => {
    if (active && !disabled) area.current?.focus();
  }, [active, disabled, focusKey]);

  useLayoutEffect(() => {
    if (cursor.current !== null && area.current) {
      area.current.setSelectionRange(cursor.current, cursor.current);
      cursor.current = null;
    }
  });

  const context = useCallback(() => completion.context(session.directory, session.home), [completion, session]);
  const candidates = useCallback(
    (value: string, position: number): Completion[] => (area.current && area.current.selectionStart !== area.current.selectionEnd ? [] : complete(value, position, context())),
    [context],
  );

  const close = useCallback(() => {
    setItems([]);
    setSelection(0);
    setMoved(false);
  }, []);

  const replaceText = (range: [number, number], insert: string) => {
    const next = text.slice(0, range[0]) + insert + text.slice(Math.min(range[1], text.length));
    cursor.current = range[0] + insert.length;
    setText(next);
  };

  useEffect(
    () =>
      onCompletionLoad(() => {
        if (items.length === 0 || !area.current) return;
        const found = complete(area.current.value, area.current.selectionStart, context());
        setItems(found);
        setSelection((s) => Math.min(s, Math.max(0, found.length - 1)));
      }),
    [onCompletionLoad, items.length, context],
  );

  const complete1 = () => {
    const found = candidates(text, area.current?.selectionStart ?? text.length);
    const first = found[0];
    if (!first) return;
    if (found.length === 1) {
      replaceText(first.replaceRange, first.insertText);
      return;
    }
    const typed = text.slice(first.replaceRange[0], first.replaceRange[1]);
    const common = commonPrefix(found);
    if (common.length > typed.length && common.toLowerCase().startsWith(typed.toLowerCase())) replaceText(first.replaceRange, common);
    setItems(found);
    setSelection(0);
    setMoved(false);
  };

  const accept = (index: number) => {
    const chosen = items[index];
    if (!chosen) return;
    close();
    replaceText(chosen.replaceRange, chosen.insertText);
  };

  const move = (step: number) => {
    if (items.length === 0) return;
    setSelection((selection + step + items.length) % items.length);
    setMoved(true);
  };

  const replaceAll = (value: string) => {
    cursor.current = value.length;
    setText(value);
  };

  const openSearch = () => {
    close();
    setSearch({ query: "", results: history.search(""), selection: 0 });
  };
  const setQuery = (query: string) => setSearch({ query, results: history.search(query), selection: 0 });
  const acceptSearch = (index: number) => {
    const chosen = search?.results[index];
    setSearch(null);
    if (chosen !== undefined) {
      replaceAll(chosen);
      navigator.current.reset();
    }
  };

  const onSearchKey = (event: KeyboardEvent<HTMLTextAreaElement>) => {
    if (!search) return;
    const step = (by: number) => search.results.length > 0 && setSearch({ ...search, selection: (search.selection + by + search.results.length) % search.results.length });
    if (event.key === "Escape") setSearch(null);
    else if (event.key === "Enter") acceptSearch(search.selection);
    else if (event.key === "ArrowUp") step(-1);
    else if (event.key === "ArrowDown") step(1);
    else if (event.key === "Backspace") setQuery(search.query.slice(0, -1));
    else if (event.ctrlKey && event.key.toLowerCase() === "r") step(1);
    else if (event.ctrlKey && (event.key.toLowerCase() === "c" || event.key.toLowerCase() === "g")) setSearch(null);
    else if (!event.ctrlKey && !event.altKey && !event.metaKey && event.key.length === 1) setQuery(search.query + event.key);
    else return;
    event.preventDefault();
  };

  const onKeyDown = (event: KeyboardEvent<HTMLTextAreaElement>) => {
    if (event.nativeEvent.isComposing) return;
    if (search) return onSearchKey(event);
    const el = event.currentTarget;
    const key = event.key;
    const plainCtrl = event.ctrlKey && !event.altKey && !event.shiftKey && !event.metaKey;
    if (plainCtrl && key.toLowerCase() === "c") {
      if (el.selectionStart !== el.selectionEnd) return;
      event.preventDefault();
      session.write("\x03");
      setText("");
      close();
      navigator.current.reset();
      return;
    }
    if (plainCtrl) {
      const lower = key.toLowerCase();
      const at = el.selectionStart;
      const handled = (): void => event.preventDefault();
      if (lower === "r") { handled(); return openSearch(); }
      if (lower === "l") { handled(); return session.clearBlocks(); }
      if (lower === "d") {
        if (text === "") { handled(); session.write("\x04"); }
        return;
      }
      if (lower === "u") { handled(); close(); return replaceText([0, at], ""); }
      if (lower === "k") { handled(); close(); return replaceText([at, text.length], ""); }
      if (lower === "w") {
        handled();
        close();
        const start = text.slice(0, at).replace(/\S+\s*$/, "").length;
        return replaceText([start, at], "");
      }
    }
    if (event.ctrlKey || event.metaKey || event.altKey) return;

    if (key === "Tab") {
      event.preventDefault();
      if (disabled) return;
      if (event.shiftKey) move(-1);
      else if (items.length > 0) accept(selection);
      else complete1();
      return;
    }
    if (items.length > 0) {
      if (key === "Escape") { event.preventDefault(); return close(); }
      if (key === "ArrowUp" && !event.shiftKey) { event.preventDefault(); return move(-1); }
      if (key === "ArrowDown" && !event.shiftKey) { event.preventDefault(); return move(1); }
      if (key === "Enter" && !event.shiftKey) {
        event.preventDefault();
        if (moved) return accept(selection);
        close();
      }
    }
    if (key === "ArrowUp" && !event.shiftKey && el.selectionStart === el.selectionEnd) {
      if (navigator.current.isNavigating || !text.slice(0, el.selectionStart).includes("\n")) {
        const previous = navigator.current.back(history.entries, text);
        if (previous !== null) { event.preventDefault(); replaceAll(previous); }
      }
      return;
    }
    if (key === "ArrowDown" && !event.shiftKey && el.selectionStart === el.selectionEnd && navigator.current.isNavigating) {
      const next = navigator.current.forward(history.entries, text);
      if (next !== null) { event.preventDefault(); replaceAll(next); }
      return;
    }
    if (key === "Enter" && !event.shiftKey) {
      event.preventDefault();
      if (session.submit(text)) {
        setText("");
        close();
        navigator.current.reset();
      }
    }
  };

  const onChange = (value: string, position: number) => {
    setText(value);
    navigator.current.reset();
    if (items.length === 0) return;
    const typed = value[position - 1] ?? "";
    if (/[ ;|&]/.test(typed)) return close();
    const found = complete(value, position, context());
    setItems(found);
    setSelection(0);
    setMoved(false);
  };

  const rows = Math.min(8, Math.max(1, text.split("\n").length));
  const menu = useMemo(() => {
    if (search) {
      const rowsOf: Completion[] =
        search.results.length > 0
          ? search.results.map((r) => ({ insertText: r, display: r.replace(/\n/g, " ⏎ "), kind: "exec" as const, replaceRange: [0, 0] as [number, number] }))
          : [{ insertText: "", display: "Nenhum resultado", kind: "builtin" as const, replaceRange: [0, 0] as [number, number] }];
      return { items: rowsOf, selected: search.selection, header: `Ctrl+R  ${search.query}`, pick: acceptSearch };
    }
    return items.length > 0 ? { items, selected: selection, header: undefined, pick: accept } : null;
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [search, items, selection]);

  return (
    <div className={styles.editor}>
      {menu && <CompletionMenu items={menu.items} selected={menu.selected} header={menu.header} onPick={menu.pick} />}
      <textarea
        ref={area}
        className={styles.input}
        aria-label="Linha de comando"
        value={text}
        rows={rows}
        placeholder={placeholder}
        disabled={disabled}
        spellCheck={false}
        autoCapitalize="off"
        autoCorrect="off"
        onKeyDown={onKeyDown}
        onChange={(event) => onChange(event.target.value, event.target.selectionStart)}
        onMouseDown={() => {
          close();
          setSearch(null);
        }}
      />
    </div>
  );
}
