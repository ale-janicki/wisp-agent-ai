import { useCallback, useEffect, useRef, useState } from "react";
import { useFeatureApi, useFeatureEvents } from "../../shell/context";
import { relative } from "./relative";
import type { ClipItem, ItemsResponse } from "./types";
import styles from "./ClipboardTab.module.css";

const COPIED_MS = 1500;

export function ClipboardTab() {
  const api = useFeatureApi("clipboard");
  const [data, setData] = useState<ItemsResponse | null>(null);
  const [query, setQuery] = useState("");
  const [confirming, setConfirming] = useState(false);
  const [copiedId, setCopiedId] = useState<string | null>(null);
  const copiedTimer = useRef<ReturnType<typeof setTimeout> | undefined>(undefined);
  const latest = useRef(0);

  const load = useCallback(
    async (q: string) => {
      const ticket = ++latest.current;
      try {
        const next = await api.get<ItemsResponse>("/items", { q: q.trim() ? q : undefined });
        if (ticket === latest.current) setData(next);
      } catch {
        return;
      }
    },
    [api],
  );

  useEffect(() => {
    void load(query);
  }, [load, query]);
  useEffect(() => () => clearTimeout(copiedTimer.current), []);
  useFeatureEvents("clipboard", (event) => {
    if (event.type === "changed") void load(query);
  });

  const act = (run: () => Promise<unknown>) => void run().then(() => load(query));
  const copy = (item: ClipItem) =>
    act(async () => {
      await api.post(`/items/${item.id}/copy`);
      setCopiedId(item.id);
      clearTimeout(copiedTimer.current);
      copiedTimer.current = setTimeout(() => setCopiedId(null), COPIED_MS);
    });

  const items = data?.items ?? [];
  const hasUnpinned = items.some((i) => !i.pinned);
  const hasPinned = items.some((i) => i.pinned);

  return (
    <div className={styles.tab}>
      <div className={styles.head}>
        <h2 className={styles.title}>Copiados</h2>
        <span className={styles.spacer} />
        {confirming ? (
          <>
            <span className={styles.ask}>{hasPinned ? "Limpar o histórico? Os fixados ficam." : "Limpar todo o histórico?"}</span>
            <button
              type="button"
              className={`${styles.pill} ${styles.danger}`}
              onClick={() => {
                setConfirming(false);
                act(() => api.post("/clear"));
              }}
            >
              Sim
            </button>
            <button type="button" className={styles.pill} onClick={() => setConfirming(false)}>
              Não
            </button>
          </>
        ) : (
          <button type="button" className={styles.pill} disabled={!hasUnpinned} onClick={() => setConfirming(true)}>
            Limpar
          </button>
        )}
      </div>
      <input
        className={styles.search}
        type="search"
        placeholder="Buscar nos copiados"
        aria-label="Buscar nos copiados"
        value={query}
        onChange={(e) => setQuery(e.target.value)}
      />
      {data && !data.capture && (
        <div className={styles.warn}>
          <span>A captura está desligada; ligue para guardar o que você copiar.</span>
          <button type="button" className={styles.pill} onClick={() => act(() => api.put("/capture", { enabled: true }))}>
            Ligar
          </button>
        </div>
      )}
      {data && !data.available && <div className={styles.warn}>Não consigo ler a área de transferência neste sistema.</div>}
      {data?.notice && <div className={styles.warn}>{data.notice}</div>}
      <div className={styles.card}>
        {items.length === 0 ? (
          <div className={styles.empty}>{data?.empty ?? ""}</div>
        ) : (
          <ul className={styles.list}>
            {items.map((item) => (
              <Row
                key={item.id}
                item={item}
                copied={copiedId === item.id}
                onCopy={() => copy(item)}
                onPin={() => act(() => api.post(`/items/${item.id}/pin`))}
                onRemove={() => act(() => api.delete(`/items/${item.id}`))}
                thumbnail={(id) => api.get<{ data_url: string }>(`/items/${id}/thumbnail`).then((r) => r.data_url)}
              />
            ))}
          </ul>
        )}
      </div>
    </div>
  );
}

const lines = (text: string) => text.split(/\r\n|\r|\n/).filter((l) => l !== "");

export function previewOf(item: ClipItem): string {
  if (item.text === null) return "Imagem";
  const first = lines(item.text).find((l) => l.trim() !== "");
  return first ? first.trim() : item.text;
}

function captionOf(item: ClipItem): string {
  const when = relative(item.copied_at);
  if (item.kind === "url") return `${when} · link`;
  if (item.kind === "image") return `${when} · imagem`;
  const count = item.text ? lines(item.text).length : 1;
  return count > 1 ? `${when} · ${count} linhas` : when;
}

type RowProps = {
  item: ClipItem;
  copied: boolean;
  onCopy: () => void;
  onPin: () => void;
  onRemove: () => void;
  thumbnail: (id: string) => Promise<string>;
};

function Row({ item, copied, onCopy, onPin, onRemove, thumbnail }: RowProps) {
  const [src, setSrc] = useState<string | null>(null);
  useEffect(() => {
    if (item.kind !== "image") return;
    let alive = true;
    thumbnail(item.id)
      .then((url) => alive && setSrc(url))
      .catch(() => {});
    return () => {
      alive = false;
    };
  }, [item.id, item.kind]); // eslint-disable-line react-hooks/exhaustive-deps

  return (
    <li className={`${styles.row} ${item.pinned ? styles.pinned : ""}`} title={item.text ?? "Imagem"}>
      <button type="button" className={styles.main} onClick={onCopy}>
        <span className={styles.lead}>
          {item.kind === "image" ? src ? <img src={src} alt="Imagem copiada" /> : null : item.kind === "url" ? "🔗" : "≡"}
        </span>
        <span className={styles.text}>
          <span className={styles.preview}>{previewOf(item)}</span>
          <span className={`${styles.caption} ${copied ? styles.copied : ""}`}>{copied ? "copiado" : captionOf(item)}</span>
        </span>
      </button>
      <span className={styles.actions}>
        <button type="button" className={`${styles.icon} ${item.pinned ? styles.on : ""}`} onClick={onPin} title={item.pinned ? "Desafixar" : "Fixar"} aria-label={item.pinned ? "Desafixar" : "Fixar"}>
          {item.pinned ? "●" : "○"}
        </button>
        <button type="button" className={styles.icon} onClick={onRemove} title="Remover" aria-label="Remover">
          ✕
        </button>
      </span>
    </li>
  );
}
