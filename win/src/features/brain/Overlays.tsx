import { useEffect, useMemo, useRef, useState, type ReactNode } from "react";
import { rank } from "./rank";
import type { NoteSummary, RenamePreview } from "./types";
import styles from "./Overlays.module.css";

function Modal({ title, children, onClose }: { title: string; children: ReactNode; onClose: () => void }) {
  useEffect(() => {
    const onKey = (e: KeyboardEvent) => {
      if (e.key === "Escape") {
        e.stopPropagation();
        onClose();
      }
    };
    window.addEventListener("keydown", onKey, true);
    return () => window.removeEventListener("keydown", onKey, true);
  }, [onClose]);
  return (
    <div className={styles.scrim} onMouseDown={onClose}>
      <div className={styles.modal} role="dialog" aria-label={title} onMouseDown={(e) => e.stopPropagation()}>
        <h3 className={styles.title}>{title}</h3>
        {children}
      </div>
    </div>
  );
}

export function PromptDialog({
  title,
  label,
  initial = "",
  confirm,
  hint,
  onSubmit,
  onClose,
}: {
  title: string;
  label: string;
  initial?: string;
  confirm: string;
  hint?: string;
  onSubmit: (value: string) => void;
  onClose: () => void;
}) {
  const [value, setValue] = useState(initial);
  return (
    <Modal title={title} onClose={onClose}>
      <form
        onSubmit={(e) => {
          e.preventDefault();
          if (value.trim()) onSubmit(value.trim());
        }}
      >
        <input autoFocus className={styles.field} aria-label={label} placeholder={label} value={value} onChange={(e) => setValue(e.target.value)} />
        {hint && <p className={styles.hint}>{hint}</p>}
        <div className={styles.actions}>
          <button type="button" onClick={onClose}>
            Cancelar
          </button>
          <button type="submit" className={styles.primary} disabled={!value.trim()}>
            {confirm}
          </button>
        </div>
      </form>
    </Modal>
  );
}

export function ConfirmDialog({
  title,
  message,
  confirm,
  onConfirm,
  onClose,
}: {
  title: string;
  message: string;
  confirm: string;
  onConfirm: () => void;
  onClose: () => void;
}) {
  return (
    <Modal title={title} onClose={onClose}>
      <p className={styles.hint}>{message}</p>
      <div className={styles.actions}>
        <button type="button" onClick={onClose}>
          Cancelar
        </button>
        <button type="button" className={styles.primary} onClick={onConfirm} autoFocus>
          {confirm}
        </button>
      </div>
    </Modal>
  );
}

export function RenameDialog({
  path,
  isFolder,
  initial,
  normalize,
  preview,
  error,
  onPreview,
  onApply,
  onClose,
}: {
  path: string;
  isFolder: boolean;
  initial: string;
  normalize: (to: string) => string;
  preview: RenamePreview | null;
  error: string | null;
  onPreview: (to: string) => void;
  onApply: (preview: RenamePreview) => void;
  onClose: () => void;
}) {
  const [to, setTo] = useState(initial);
  const current = preview !== null && preview.to === normalize(to.trim()) ? preview : null;
  const quiet = current !== null && current.link_count === 0;
  return (
    <Modal title={isFolder ? "Renomear ou mover a pasta" : "Renomear ou mover a nota"} onClose={onClose}>
      <p className={styles.hint}>
        “{path}”{isFolder ? " (pasta)" : ""}
      </p>
      <input autoFocus className={styles.field} aria-label="pasta/nome" placeholder="pasta/nome" value={to} onChange={(e) => setTo(e.target.value)} />
      <p className={styles.hint}>Mudar a parte da pasta move o item. Os [[links]] que apontam para ele são atualizados em todo o brain.</p>
      {error && <p className={styles.error}>{error}</p>}
      {current && (
        <div className={styles.preview}>
          <p>
            {`Mover “${current.from}” para “${current.to}” muda ${current.link_count} ${current.link_count === 1 ? "link" : "links"} em ${current.file_count} ${current.file_count === 1 ? "nota" : "notas"}.`}
          </p>
          {current.skipped.length > 0 && (
            <p className={styles.error}>
              {`${current.skipped.length} notas não verificadas (link simbólico ou texto ilegível): ${current.skipped.slice(0, 3).join(", ")}`}
            </p>
          )}
          {current.drawings.length > 0 && (
            <p className={styles.hint}>
              {`Links dentro destes desenhos não são atualizados: ${current.drawings.slice(0, 5).join(", ")}${current.drawings.length > 5 ? ` e mais ${current.drawings.length - 5}` : ""}`}
            </p>
          )}
        </div>
      )}
      <div className={styles.actions}>
        <button type="button" onClick={onClose}>
          Cancelar
        </button>
        {current ? (
          <button type="button" className={styles.primary} onClick={() => onApply(current)}>
            {quiet ? "Mover" : "Mover e atualizar"}
          </button>
        ) : (
          <button type="button" className={styles.primary} disabled={!to.trim() || to.trim() === path} onClick={() => onPreview(to.trim())}>
            Confirmar
          </button>
        )}
      </div>
    </Modal>
  );
}

export function Switcher({ notes, onPick, onClose }: { notes: NoteSummary[]; onPick: (path: string) => void; onClose: () => void }) {
  const [query, setQuery] = useState("");
  const [active, setActive] = useState(0);
  const results = useMemo(() => rank(query, notes), [query, notes]);
  const list = useRef<HTMLUListElement>(null);
  useEffect(() => setActive(0), [query]);
  return (
    <Modal title="Ir para uma nota (título, apelido ou caminho)" onClose={onClose}>
      <input
        autoFocus
        className={styles.field}
        aria-label="Ir para uma nota"
        placeholder="Ir para uma nota (título, apelido ou caminho)"
        value={query}
        onChange={(e) => setQuery(e.target.value)}
        onKeyDown={(e) => {
          if (e.key === "ArrowDown") setActive((i) => Math.min(i + 1, results.length - 1));
          else if (e.key === "ArrowUp") setActive((i) => Math.max(i - 1, 0));
          else if (e.key === "Enter" && results[active]) onPick(results[active]!.path);
          else return;
          e.preventDefault();
        }}
      />
      <ul ref={list} className={styles.results} role="listbox">
        {results.length === 0 && <li className={styles.hint}>Nenhuma nota com “{query}”</li>}
        {results.map((r, i) => (
          <li key={r.path} role="option" aria-selected={i === active}>
            <button type="button" className={i === active ? styles.activeResult : undefined} onClick={() => onPick(r.path)}>
              <span>{r.title}</span>
              <span className={styles.path}>{r.alias ? `apelido: ${r.alias}` : r.path}</span>
            </button>
          </li>
        ))}
      </ul>
    </Modal>
  );
}
