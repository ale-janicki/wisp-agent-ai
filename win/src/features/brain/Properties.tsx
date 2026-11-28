import { useCallback, useEffect, useState } from "react";
import type { BrainApi } from "./api";
import type { Property } from "./types";
import styles from "./Panels.module.css";

type Props = {
  api: BrainApi;
  path: string;
  disabled: boolean;
  version: string;
  beforeEdit: () => Promise<void>;
  onText: (text: string) => void;
  onTag: (tag: string) => void;
};

export function Properties({ api, path, disabled, version, beforeEdit, onText, onTag }: Props) {
  const [items, setItems] = useState<Property[]>([]);
  const [open, setOpen] = useState(true);
  const [adding, setAdding] = useState(false);
  const [key, setKey] = useState("");
  const [value, setValue] = useState("");
  const [error, setError] = useState<string | null>(null);

  const load = useCallback(() => {
    let alive = true;
    api
      .properties(path)
      .then((list) => alive && setItems(list))
      .catch(() => alive && setItems([]));
    return () => {
      alive = false;
    };
  }, [api, path]);
  useEffect(() => load(), [load, version]);

  const run = async (work: () => Promise<{ text: string }>) => {
    setError(null);
    try {
      await beforeEdit();
      onText((await work()).text);
    } catch {
      setError("Não consegui alterar a propriedade.");
    }
  };

  const setList = (prop: Property, next: string[]) => run(() => api.setProperty(path, prop.key, next));

  return (
    <section className={styles.panel} aria-label="Propriedades">
      <header className={styles.head}>
        <button type="button" className={styles.toggle} onClick={() => setOpen(!open)} aria-expanded={open}>
          {open ? "▾" : "▸"} Propriedades
        </button>
        {!disabled && (
          <button type="button" className={styles.small} onClick={() => setAdding(!adding)} aria-label="Adicionar propriedade">
            +
          </button>
        )}
      </header>
      {open && (
        <div className={styles.body}>
          {error && <p className={styles.error}>{error}</p>}
          {items.length === 0 && !adding && <p className={styles.muted}>Adicionar propriedades à nota</p>}
          {items.map((prop) => (
            <div key={prop.key} className={styles.prop}>
              <span className={styles.key}>{prop.key}</span>
              {prop.kind === "list" && Array.isArray(prop.value) ? (
                <span className={styles.chips}>
                  {prop.value.map((item) => (
                    <span key={item} className={styles.chip}>
                      <button
                        type="button"
                        className={styles.chipText}
                        onClick={() => prop.key === "tags" && onTag(item.replace(/^#/, ""))}
                      >
                        {item}
                      </button>
                      {!disabled && (
                        <button
                          type="button"
                          className={styles.chipX}
                          aria-label={`Remover ${item}`}
                          onClick={() => void setList(prop, (prop.value as string[]).filter((v) => v !== item))}
                        >
                          ×
                        </button>
                      )}
                    </span>
                  ))}
                  {!disabled && (
                    <input
                      className={styles.inline}
                      aria-label={`Adicionar a ${prop.key}`}
                      placeholder="+"
                      onKeyDown={(e) => {
                        const next = e.currentTarget.value.trim();
                        if (e.key === "Enter" && next) {
                          void setList(prop, [...(prop.value as string[]), next]);
                          e.currentTarget.value = "";
                        }
                      }}
                    />
                  )}
                </span>
              ) : prop.kind === "complex" ? (
                <pre className={styles.complex}>{String(prop.value)}</pre>
              ) : (
                <input
                  className={styles.value}
                  aria-label={prop.key}
                  defaultValue={String(prop.value)}
                  disabled={disabled}
                  onBlur={(e) => e.target.value !== prop.value && void run(() => api.setProperty(path, prop.key, e.target.value))}
                  onKeyDown={(e) => e.key === "Enter" && e.currentTarget.blur()}
                />
              )}
              {!disabled && (
                <button
                  type="button"
                  className={styles.small}
                  aria-label="Remover propriedade"
                  title="Remover propriedade"
                  onClick={() => void run(() => api.removeProperty(path, prop.key))}
                >
                  ×
                </button>
              )}
            </div>
          ))}
          {adding && (
            <form
              className={styles.prop}
              onSubmit={(e) => {
                e.preventDefault();
                if (!key.trim()) return;
                void run(() => api.setProperty(path, key.trim(), value));
                setKey("");
                setValue("");
                setAdding(false);
              }}
            >
              <input className={styles.key} aria-label="Nome da propriedade" placeholder="chave" value={key} onChange={(e) => setKey(e.target.value)} />
              <input className={styles.value} aria-label="Valor da propriedade" placeholder="valor" value={value} onChange={(e) => setValue(e.target.value)} />
              <button type="submit" className={styles.small}>
                OK
              </button>
            </form>
          )}
        </div>
      )}
    </section>
  );
}
