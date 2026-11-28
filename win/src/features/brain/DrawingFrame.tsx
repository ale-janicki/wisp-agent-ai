import { useCallback, useEffect, useRef, useState } from "react";
import { baseUrl, ApiError } from "../../api/client";
import type { SidecarInfo } from "../../api/types";
import { useFeatureEvents } from "../../shell/context";
import type { BrainApi } from "./api";
import styles from "./Drawing.module.css";

export const SAVE_DELAY_MS = 600;
export const READY_TIMEOUT_MS = 8000;
export const MISSING_BUILD = "O Excalidraw não está dentro do app. Rode scripts/build-excalidraw.sh e gere o app de novo.";

type Bridge = { type: string; scene?: string; link?: string; message?: string };
type Props = { api: BrainApi; info: SidecarInfo; path: string; editing: boolean; onOpenNote: (target: string) => void; onReadOnly: (reason: string | null) => void };

export function DrawingFrame({ api, info, path, editing, onOpenNote, onReadOnly }: Props) {
  const frame = useRef<HTMLIFrameElement>(null);
  const origin = baseUrl(info);
  const hash = useRef("");
  const dirty = useRef(false);
  const timer = useRef<ReturnType<typeof setTimeout> | undefined>(undefined);
  const editingRef = useRef(editing);
  const readOnly = useRef<string | null>(null);
  const pendingScene = useRef<string | null>(null);
  const [ready, setReady] = useState(false);
  const [failure, setFailure] = useState<string | null>(null);
  const [external, setExternal] = useState(false);
  const [note, setNote] = useState<string | null>(null);
  editingRef.current = editing;

  const send = useCallback(
    (message: Record<string, unknown>) => frame.current?.contentWindow?.postMessage({ wisp: JSON.stringify(message) }, origin),
    [origin],
  );

  const load = useCallback(async () => {
    try {
      const doc = await api.drawing(path);
      if (doc.kind !== "excalidraw") return setFailure(`O Wisp não abre ${path} como desenho.`);
      hash.current = doc.hash;
      readOnly.current = doc.read_only;
      onReadOnly(doc.read_only);
      dirty.current = false;
      send({ type: "load", scene: doc.scene, files: doc.files, viewMode: !editingRef.current || !!doc.read_only, dark: true, language: "pt-BR" });
      setExternal(false);
    } catch (e) {
      setFailure(`Não consegui desenhar ${path}${e instanceof ApiError ? ` (erro ${e.status})` : ""}`);
    }
  }, [api, path, send, onReadOnly]);

  const write = useCallback(
    async (scene: string, force = false) => {
      if (readOnly.current) return;
      try {
        const saved = await api.saveDrawing(path, scene, hash.current, force);
        hash.current = saved.hash;
        dirty.current = false;
        pendingScene.current = null;
        setExternal(false);
        setNote("Salvo");
      } catch (e) {
        if (e instanceof ApiError && e.status === 409) {
          pendingScene.current = scene;
          setExternal(true);
        } else setNote(`Não consegui salvar suas edições de ${path}`);
      }
    },
    [api, path],
  );

  useEffect(() => {
    const onMessage = (event: MessageEvent) => {
      if (event.source !== frame.current?.contentWindow || event.origin !== origin) return;
      const raw = (event.data as { wisp?: unknown } | null)?.wisp;
      if (typeof raw !== "string") return;
      let message: Bridge;
      try {
        message = JSON.parse(raw) as Bridge;
      } catch {
        return;
      }
      switch (message.type) {
        case "ready":
          setReady(true);
          void load();
          break;
        case "dirty":
          dirty.current = true;
          break;
        case "changed":
          if (message.scene && editingRef.current) {
            clearTimeout(timer.current);
            const scene = message.scene;
            pendingScene.current = scene;
            timer.current = setTimeout(() => void write(scene), SAVE_DELAY_MS);
          }
          break;
        case "save":
          if (message.scene) {
            clearTimeout(timer.current);
            void write(message.scene);
          }
          break;
        case "openLink": {
          const link = message.link ?? "";
          const wiki = /^\[\[([^\]]+)\]\]$/.exec(link.trim());
          if (wiki) onOpenNote((wiki[1] ?? "").split("|")[0] ?? "");
          else if (/^https?:/i.test(link)) window.open(link, "_blank", "noopener");
          break;
        }
        case "failure":
          setFailure(message.message ?? "erro desconhecido");
          break;
        default:
          break;
      }
    };
    window.addEventListener("message", onMessage);
    return () => window.removeEventListener("message", onMessage);
  }, [origin, load, write, onOpenNote]);

  useEffect(() => {
    if (!ready) return;
    send({ type: "setViewMode", viewMode: !editing || !!readOnly.current });
    if (!editing) send({ type: "requestSave" });
  }, [editing, ready, send]);

  useEffect(() => {
    if (ready) return;
    const wait = setTimeout(() => setFailure((f) => f ?? MISSING_BUILD), READY_TIMEOUT_MS);
    return () => clearTimeout(wait);
  }, [ready]);

  useEffect(
    () => () => {
      clearTimeout(timer.current);
      if (pendingScene.current && !readOnly.current) void api.saveDrawing(path, pendingScene.current, hash.current).catch(() => undefined);
    },
    [api, path],
  );

  useFeatureEvents("brain", (event) => {
    const paths = event.paths;
    if (event.type !== "changed" || !Array.isArray(paths) || !paths.includes(path) || !ready) return;
    api
      .drawing(path)
      .then((doc) => {
        if (doc.hash === hash.current) return;
        if (dirty.current || pendingScene.current) setExternal(true);
        else void load();
      })
      .catch(() => undefined);
  });

  return (
    <div className={styles.frameWrap}>
      {failure && <p className={styles.error}>{failure}</p>}
      {external && (
        <div className={styles.banner} role="alert">
          <span>O arquivo mudou fora do Wisp enquanto você editava.</span>
          <button type="button" onClick={() => void load()}>
            Recarregar do disco
          </button>
          <button type="button" onClick={() => pendingScene.current && void write(pendingScene.current, true)}>
            Manter o meu
          </button>
        </div>
      )}
      {note && <span className={styles.note}>{note}</span>}
      <iframe
        ref={frame}
        title={`Desenho ${path}`}
        className={styles.frame}
        src={`${origin}/api/brain/excalidraw/t/${encodeURIComponent(info.token)}/index.html`}
        sandbox="allow-scripts allow-same-origin"
      />
    </div>
  );
}
