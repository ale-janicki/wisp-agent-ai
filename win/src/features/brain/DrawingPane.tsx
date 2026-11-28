import { useCallback, useEffect, useState } from "react";
import { ApiError } from "../../api/client";
import { useShell } from "../../shell/context";
import type { BrainApi } from "./api";
import { CanvasView } from "./CanvasView";
import { DrawingFrame } from "./DrawingFrame";
import type { CanvasData } from "./types";
import styles from "./NotePane.module.css";

type Props = { api: BrainApi; path: string; onOpenNote: (target: string, from: string) => void };

export function DrawingPane({ api, path, onOpenNote }: Props) {
  const { info } = useShell();
  const isCanvas = path.toLowerCase().endsWith(".canvas");
  const [editing, setEditing] = useState(false);
  const [readOnly, setReadOnly] = useState<string | null>(null);
  const [canvas, setCanvas] = useState<CanvasData | null>(null);
  const [error, setError] = useState<string | null>(null);
  const open = useCallback((target: string) => onOpenNote(target, path), [onOpenNote, path]);

  useEffect(() => {
    if (!isCanvas) return;
    let alive = true;
    setError(null);
    api
      .drawing(path)
      .then((doc) => {
        if (!alive || doc.kind !== "canvas") return;
        setCanvas(doc.canvas);
        setReadOnly(doc.read_only);
      })
      .catch((e) => alive && setError(e instanceof ApiError && e.status === 422 ? `Não consegui desenhar ${path}` : `Não consegui ler ${path}.`));
    return () => {
      alive = false;
    };
  }, [api, path, isCanvas]);

  return (
    <div className={styles.pane}>
      <header className={styles.head}>
        <h3 className={styles.title} title={path}>
          {path.slice(path.lastIndexOf("/") + 1)}
        </h3>
        {!isCanvas && (
          <span className={styles.actions}>
            <button type="button" disabled={readOnly !== null} onClick={() => setEditing(!editing)}>
              {editing ? "Ler" : "Editar"}
            </button>
          </span>
        )}
      </header>
      {readOnly && <p className={styles.warn}>Somente leitura: {readOnly}</p>}
      {error && <p className={styles.warn}>{error}</p>}
      {isCanvas ? (
        canvas && <CanvasView data={canvas} onOpenNote={open} />
      ) : (
        <DrawingFrame api={api} info={info} path={path} editing={editing} onOpenNote={open} onReadOnly={setReadOnly} />
      )}
    </div>
  );
}

export function ImagePane({ api, path }: { api: BrainApi; path: string }) {
  const [src, setSrc] = useState<string | null>(null);
  const [failed, setFailed] = useState(false);
  useEffect(() => {
    let alive = true;
    setFailed(false);
    api
      .attachment(path)
      .then((file) => alive && setSrc(`data:${file.mime};base64,${file.data}`))
      .catch(() => alive && setFailed(true));
    return () => {
      alive = false;
    };
  }, [api, path]);
  if (failed) return <p className={styles.message}>Não encontrei {path}</p>;
  return src ? <img src={src} alt={path} style={{ maxWidth: "100%", margin: "auto" }} /> : <p className={styles.message}>…</p>;
}
