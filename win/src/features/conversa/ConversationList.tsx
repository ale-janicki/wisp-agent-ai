import { useState } from "react";
import type { ConversationSummary, ThinkingState } from "../../api/types";
import styles from "./ConversationList.module.css";

type Props = {
  items: ConversationSummary[];
  currentId: string | null;
  status: Record<string, ThinkingState>;
  attention: Set<string>;
  onOpen: (id: string) => void;
  onNew: () => void;
  onDelete?: (id: string) => void;
  onRename?: (id: string, title: string) => void;
};

const fold = (text: string | null | undefined) =>
  (text ?? "").normalize("NFD").replace(/\p{Diacritic}/gu, "").toLowerCase();

export function searchConversations(items: ConversationSummary[], query: string): ConversationSummary[] {
  const wanted = fold(query.trim());
  if (!wanted) return items.filter((c) => c.closed !== true);
  const hit = (c: ConversationSummary) => fold(c.title).includes(wanted) || fold(c.preview).includes(wanted);
  return [...items.filter((c) => c.closed !== true && hit(c)), ...items.filter((c) => c.closed === true && hit(c))];
}

export function ConversationList({ items, currentId, status, attention, onOpen, onNew, onDelete, onRename }: Props) {
  const [query, setQuery] = useState("");
  const [editing, setEditing] = useState<string | null>(null);
  const [draft, setDraft] = useState("");
  const shown = searchConversations(items, query);

  const commit = (id: string) => {
    const title = draft.trim();
    setEditing(null);
    if (title && onRename) onRename(id, title);
  };

  return (
    <nav className={styles.column} aria-label="Conversas">
      <div className={styles.head}>
        <span className={styles.heading}>Conversas</span>
        <button type="button" className={styles.new} onClick={onNew} title="Nova conversa" aria-label="Nova conversa">
          +
        </button>
      </div>
      <div className={styles.search}>
        <input
          className={styles.searchInput}
          type="search"
          value={query}
          placeholder="Buscar conversa"
          aria-label="Buscar conversa"
          onChange={(e) => setQuery(e.target.value)}
        />
        {query && (
          <button type="button" className={styles.clear} onClick={() => setQuery("")} title="Limpar busca" aria-label="Limpar busca">
            ✕
          </button>
        )}
      </div>
      <div className={styles.rows}>
        {shown.length === 0 && <div className={styles.empty}>Nenhuma conversa encontrada</div>}
        {shown.map((c) => (
          <div key={c.id} className={`${styles.row} ${c.id === currentId ? styles.current : ""}`}>
            {editing === c.id ? (
              <input
                className={styles.rename}
                value={draft}
                autoFocus
                aria-label="Renomear conversa"
                onChange={(e) => setDraft(e.target.value)}
                onBlur={() => commit(c.id)}
                onKeyDown={(e) => {
                  if (e.key === "Enter") commit(c.id);
                  if (e.key === "Escape") setEditing(null);
                }}
              />
            ) : (
              <button
                type="button"
                className={styles.open}
                onClick={() => onOpen(c.id)}
                onDoubleClick={() => {
                  if (!onRename) return;
                  setDraft(c.title || "");
                  setEditing(c.id);
                }}
                title={c.title}
              >
                <span className={styles.titleLine}>
                  <span className={styles.title}>{c.title || "Nova conversa"}</span>
                  {c.closed === true && <span className={styles.closed}>encerrada</span>}
                </span>
                {c.preview && <span className={styles.preview}>{c.preview}</span>}
              </button>
            )}
            {attention.has(c.id) ? (
              <span className={`${styles.dot} ${styles.attention}`} title="Precisa de atenção" />
            ) : status[c.id] === "thinking" ? (
              <span className={`${styles.dot} ${styles.busy}`} title="Respondendo…" />
            ) : null}
            {onDelete && (
              <button
                type="button"
                className={styles.delete}
                onClick={() => onDelete(c.id)}
                title="Apagar conversa"
                aria-label={`Apagar conversa ${c.title || "Nova conversa"}`}
              >
                ✕
              </button>
            )}
          </div>
        ))}
      </div>
    </nav>
  );
}
