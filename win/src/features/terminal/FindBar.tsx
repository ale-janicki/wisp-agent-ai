import { useEffect, useRef } from "react";
import styles from "./Pane.module.css";

type Props = {
  query: string;
  onQuery: (query: string) => void;
  current: number | null;
  total: number;
  onPrevious: () => void;
  onNext: () => void;
  onClose: () => void;
};

export function FindBar({ query, onQuery, current, total, onPrevious, onNext, onClose }: Props) {
  const input = useRef<HTMLInputElement>(null);
  useEffect(() => input.current?.focus(), []);
  return (
    <div className={styles.find} role="search">
      <input
        ref={input}
        className={styles.findInput}
        value={query}
        placeholder="Buscar nos blocos"
        aria-label="Buscar nos blocos"
        onChange={(event) => onQuery(event.target.value)}
        onKeyDown={(event) => {
          if (event.key === "Enter") {
            event.preventDefault();
            if (event.shiftKey) onPrevious();
            else onNext();
          } else if (event.key === "Escape") {
            event.preventDefault();
            onClose();
          }
        }}
      />
      <span className={styles.findCount}>{query ? `${current ?? 0}/${total}` : ""}</span>
      <button type="button" aria-label="Anterior" title="Anterior" onClick={onPrevious}>
        ↑
      </button>
      <button type="button" aria-label="Próxima" title="Próxima" onClick={onNext}>
        ↓
      </button>
      <button type="button" aria-label="Fechar busca" title="Fechar busca" onClick={onClose}>
        ✕
      </button>
    </div>
  );
}
