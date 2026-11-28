import { useCallback, useEffect, useRef, useState } from "react";
import { BlockList, countMatches } from "./BlockList";
import { ContextChips } from "./ContextChips";
import { FindBar } from "./FindBar";
import { InputEditor } from "./InputEditor";
import { useSession } from "./hooks";
import type { TerminalSession } from "./session";
import type { TerminalStore } from "./store";
import styles from "./Pane.module.css";

type Props = {
  store: TerminalStore;
  session: TerminalSession;
  focused: boolean;
  split: boolean;
  findOpen: boolean;
  onCloseFind: () => void;
  onFocus: () => void;
};

function endedNote(session: TerminalSession): string | null {
  const phase = session.phase;
  if (phase.kind === "failed") return phase.message;
  if (phase.kind === "ended") return phase.code === null ? "Encerrado por um sinal" : `Código de saída ${phase.code}`;
  return null;
}

export function Pane({ store, session, focused, split, findOpen, onCloseFind, onFocus }: Props) {
  const version = useSession(session);
  const pane = useRef<HTMLDivElement>(null);
  const host = useRef<HTMLDivElement>(null);
  const [notice, setNotice] = useState<string | null>(null);
  const [query, setQuery] = useState("");
  const [index, setIndex] = useState(0);
  const [focusKey, setFocusKey] = useState(0);
  const engine = session.engine;
  const grid = session.mode.kind === "grid";
  const running = session.isCommandRunning;
  const note = endedNote(session);
  const finished = [...session.blocks.blocks].reverse().find((b) => b.status.kind !== "running")?.id ?? null;
  void version;

  useEffect(() => {
    if (host.current) engine.attach?.(host.current);
  }, [engine]);

  useEffect(() => {
    const element = pane.current;
    if (!element) return;
    let frame = 0;
    const fit = () => {
      cancelAnimationFrame(frame);
      frame = requestAnimationFrame(() => {
        const size = engine.fit?.();
        if (size) session.resize(size);
      });
    };
    const observer = new ResizeObserver(fit);
    observer.observe(element);
    fit();
    return () => {
      observer.disconnect();
      cancelAnimationFrame(frame);
    };
  }, [engine, session]);

  useEffect(() => {
    if (!focused) return;
    if (grid || running) engine.focus?.();
    else setFocusKey((k) => k + 1);
  }, [focused, grid, running, engine]);

  useEffect(() => {
    if (!notice) return;
    const timer = setTimeout(() => setNotice(null), 4000);
    return () => clearTimeout(timer);
  }, [notice]);

  const total = countMatches(session, query);
  const step = useCallback(
    (by: number) => {
      if (grid) {
        if (query) (by > 0 ? engine.find?.next(query) : engine.find?.previous(query));
        return;
      }
      if (total > 0) setIndex((i) => (i + by + total) % total);
    },
    [grid, engine, query, total],
  );

  return (
    <div
      ref={pane}
      className={styles.pane}
      data-focused={focused}
      data-split={split}
      data-mode={session.mode.kind}
      onPointerDownCapture={(event) => {
        onFocus();
        if ((event.target as HTMLElement).closest('[role="search"]')) return;
        if (!grid && !running) setFocusKey((k) => k + 1);
        else engine.focus?.();
      }}
    >
      {findOpen && (
        <FindBar
          query={query}
          onQuery={(q) => {
            setQuery(q);
            setIndex(0);
          }}
          current={total > 0 ? index + 1 : 0}
          total={total}
          onPrevious={() => step(-1)}
          onNext={() => step(1)}
          onClose={() => {
            engine.find?.clear();
            setQuery("");
            onCloseFind();
          }}
        />
      )}
      <div className={styles.grid} ref={host} data-visible={grid} aria-hidden={!grid} />
      {!grid && (
        <div className={styles.layer}>
          <BlockList session={session} onNotice={setNotice} findQuery={query} findIndex={index} />
          {notice && (
            <div className={styles.notice} role="status">
              {notice}
            </div>
          )}
          <footer className={styles.footer}>
            <ContextChips backend={store.backend} directory={session.directory} home={store.home} finishedKey={finished} />
            <InputEditor
              session={session}
              history={store.history}
              completion={store.completion}
              onCompletionLoad={store.onCompletionLoad}
              focusKey={focusKey}
              active={focused}
            />
          </footer>
        </div>
      )}
      {note && (
        <div className={styles.ended}>
          <span>{note}</span>
          <button type="button" onClick={() => session.reopen()}>
            Reabrir
          </button>
        </div>
      )}
      {split && focused && <span className={styles.activeMark} aria-hidden />}
    </div>
  );
}
