import { useEffect, useState } from "react";
import type { BrainApi } from "./api";
import type { Backlink } from "./types";
import styles from "./Panels.module.css";

type Props = { api: BrainApi; path: string; version: string; onOpen: (path: string, line: number) => void };

export function Backlinks({ api, path, version, onOpen }: Props) {
  const [items, setItems] = useState<Backlink[] | null>(null);
  const [open, setOpen] = useState(false);
  useEffect(() => {
    let alive = true;
    api
      .backlinks(path)
      .then((list) => alive && setItems(list))
      .catch(() => alive && setItems([]));
    return () => {
      alive = false;
    };
  }, [api, path, version]);
  return (
    <section className={styles.panel} aria-label="Backlinks">
      <header className={styles.head}>
        <button type="button" className={styles.toggle} onClick={() => setOpen(!open)} aria-expanded={open}>
          {open ? "▾" : "▸"} Backlinks{items ? ` (${items.length})` : ""}
        </button>
      </header>
      {open && (
        <div className={styles.body}>
          {items?.length === 0 && <p className={styles.muted}>Nenhuma nota aponta para esta.</p>}
          {items?.map((item) => (
            <div key={item.path} className={styles.backlink}>
              <button type="button" className={styles.linkTitle} onClick={() => onOpen(item.path, item.contexts[0]?.line ?? 0)}>
                {item.title}
              </button>
              {item.contexts.map((c) => (
                <button key={c.line} type="button" className={styles.context} onClick={() => onOpen(item.path, c.line)}>
                  {c.text}
                </button>
              ))}
            </div>
          ))}
        </div>
      )}
    </section>
  );
}
