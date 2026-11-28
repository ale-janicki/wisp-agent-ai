import { useEffect, useState } from "react";
import type { BrainApi } from "./api";
import { GraphView } from "./GraphView";
import type { GraphData, Hit } from "./types";
import styles from "./Home.module.css";

type Props = {
  api: BrainApi;
  graph: boolean;
  query: string;
  version: string;
  onOpen: (path: string) => void;
};

const SEARCH_DEBOUNCE_MS = 250;

export function Home({ api, graph, query, version, onOpen }: Props) {
  const [data, setData] = useState<GraphData | null>(null);
  const [hits, setHits] = useState<Hit[] | null>(null);
  const [failed, setFailed] = useState<string | null>(null);

  useEffect(() => {
    if (!graph) return;
    let alive = true;
    setFailed(null);
    api
      .graph()
      .then((g) => alive && setData(g))
      .catch(() => alive && setFailed("Não consegui ler as notas."));
    return () => {
      alive = false;
    };
  }, [api, graph, version]);

  useEffect(() => {
    if (graph) return;
    let alive = true;
    setFailed(null);
    const text = query.trim();
    const timer = setTimeout(
      () => {
        const request = text ? api.search(text) : api.recent().then((items) => items.map((i) => ({ path: i.path, title: i.title, snippet: "" })));
        request
          .then((items) => alive && setHits(items))
          .catch(() => alive && setFailed("Não consegui buscar no brain."));
      },
      text ? SEARCH_DEBOUNCE_MS : 0,
    );
    return () => {
      alive = false;
      clearTimeout(timer);
    };
  }, [api, graph, query, version]);

  if (failed) return <p className={styles.message}>{failed}</p>;
  if (graph) {
    if (!data) return <p className={styles.message}>Lendo notas…</p>;
    if (data.nodes.length === 0) return <p className={styles.message}>Nenhuma nota</p>;
    return <GraphView data={data} query={query} onOpen={onOpen} />;
  }
  if (!hits) return <p className={styles.message}>Lendo notas…</p>;
  return (
    <div className={styles.list}>
      <span className={styles.caption}>{query.trim() ? "Notas" : "Recentes"}</span>
      {hits.length === 0 && <p className={styles.message}>{query.trim() ? `Nenhuma nota com “${query.trim()}”` : "Nenhuma nota"}</p>}
      {hits.map((hit) => (
        <button key={hit.path} type="button" className={styles.hit} onClick={() => onOpen(hit.path)}>
          <span className={styles.hitTitle}>{hit.title}</span>
          <span className={styles.hitPath}>{hit.path}</span>
          {hit.snippet && <span className={styles.snippet}>{hit.snippet}</span>}
        </button>
      ))}
    </div>
  );
}
