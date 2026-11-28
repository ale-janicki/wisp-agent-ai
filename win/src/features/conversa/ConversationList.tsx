import type { ConversationSummary, ThinkingState } from "../../api/types";
import styles from "./ConversationList.module.css";

type Props = {
  items: ConversationSummary[];
  currentId: string | null;
  status: Record<string, ThinkingState>;
  attention: Set<string>;
  onOpen: (id: string) => void;
  onNew: () => void;
};

export function ConversationList({ items, currentId, status, attention, onOpen, onNew }: Props) {
  return (
    <nav className={styles.column} aria-label="Conversas">
      <div className={styles.head}>
        <span className={styles.heading}>Conversas</span>
        <button type="button" className={styles.new} onClick={onNew} title="Nova conversa" aria-label="Nova conversa">
          +
        </button>
      </div>
      <div className={styles.rows}>
        {items.length === 0 && <div className={styles.empty}>Nenhuma conversa encontrada</div>}
        {items.map((c) => (
          <button
            type="button"
            key={c.id}
            className={`${styles.row} ${c.id === currentId ? styles.current : ""}`}
            onClick={() => onOpen(c.id)}
          >
            <span className={styles.title}>{c.title || "Nova conversa"}</span>
            {attention.has(c.id) ? (
              <span className={`${styles.dot} ${styles.attention}`} title="Precisa de atenção" />
            ) : status[c.id] === "thinking" ? (
              <span className={`${styles.dot} ${styles.busy}`} title="Pensando…" />
            ) : null}
          </button>
        ))}
      </div>
    </nav>
  );
}
