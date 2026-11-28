import { useCallback, useEffect, useMemo, useRef, useState } from "react";
import { ApiError } from "../../api/client";
import { BrainIcon } from "../../shell/icons";
import { useFeatureApi, useFeatureEvents, useShell } from "../../shell/context";
import { TabCard, TabMessage } from "../../shell/TabCard";
import { brainApi } from "./api";
import { DrawingPane, ImagePane } from "./DrawingPane";
import { Home } from "./Home";
import { NotePane } from "./NotePane";
import { ConfirmDialog, PromptDialog, RenameDialog, Switcher } from "./Overlays";
import type { Focus } from "./Reader";
import { Tree, type TreeAction } from "./Tree";
import { ancestorsOf, kindOf, parentOf, uniquePath } from "./treeRows";
import type { NoteSummary, RenamePreview, TreeEntry } from "./types";
import styles from "./BrainTab.module.css";

const GRAPH_KEY = "wisp.brain.graph";
const OPEN_KEY = "wisp.brain.open";
const REFRESH_DEBOUNCE_MS = 300;
const ASK_LIMIT = 24000;

type Overlay =
  | { kind: "switcher" }
  | { kind: "prompt"; title: string; label: string; confirm: string; hint?: string; submit: (value: string) => void }
  | { kind: "confirm"; title: string; message: string; confirm: string; run: () => void }
  | { kind: "rename"; path: string; isFolder: boolean }
  | null;

type Workspace = { tabs: string[]; active: string | null; expanded: string[] };
type Phase = "loading" | "unconfigured" | "failed" | "ready";

const workspaceKey = (name: string) => `wisp.brain.workspace:${name}`;
const loadWorkspace = (name: string): Workspace => {
  try {
    const raw = JSON.parse(localStorage.getItem(workspaceKey(name)) ?? "null") as Partial<Workspace> | null;
    return { tabs: raw?.tabs ?? [], active: raw?.active ?? null, expanded: raw?.expanded ?? [] };
  } catch {
    return { tabs: [], active: null, expanded: [] };
  }
};
const join = (folder: string, name: string) => (folder ? `${folder}/${name}` : name);
const noteName = (value: string) => (/\.md$/i.test(value) ? value : `${value}.md`);
const stripMd = (path: string) => path.replace(/\.md$/i, "");
const tabTitle = (path: string) => stripMd(path.slice(path.lastIndexOf("/") + 1));

export function BrainTab() {
  const shell = useShell();
  const raw = useFeatureApi("brain");
  const api = useMemo(() => brainApi(raw), [raw]);

  const [phase, setPhase] = useState<Phase>("loading");
  const [name, setName] = useState("");
  const [entries, setEntries] = useState<TreeEntry[]>([]);
  const [notes, setNotes] = useState<NoteSummary[]>([]);
  const [tags, setTags] = useState<Record<string, number>>({});
  const [bookmarks, setBookmarks] = useState<string[]>([]);
  const [version, setVersion] = useState("0");
  const [tabs, setTabs] = useState<string[]>([]);
  const [active, setActive] = useState<string | null>(null);
  const [expanded, setExpanded] = useState<Set<string>>(new Set());
  const [focus, setFocus] = useState<Focus>(null);
  const [editing, setEditing] = useState<Set<string>>(new Set());
  const [graph, setGraph] = useState(() => localStorage.getItem(GRAPH_KEY) !== "list");
  const [query, setQuery] = useState("");
  const [browse, setBrowse] = useState(true);
  const [showTree, setShowTree] = useState(true);
  const [overlay, setOverlay] = useState<Overlay>(null);
  const [renameState, setRenameState] = useState<{ preview: RenamePreview | null; error: string | null }>({ preview: null, error: null });
  const [message, setMessage] = useState<string | null>(null);
  const activeRef = useRef<string | null>(null);
  const tabsRef = useRef<string[]>([]);
  const history = useRef<{ stack: string[]; pos: number }>({ stack: [], pos: -1 });
  const search = useRef<HTMLInputElement>(null);
  const refreshTimer = useRef<ReturnType<typeof setTimeout> | undefined>(undefined);
  activeRef.current = active;
  tabsRef.current = tabs;

  const refresh = useCallback(async () => {
    try {
      const [tree, list, counts] = await Promise.all([api.tree(), api.notes(), api.tags()]);
      setEntries(tree);
      setNotes(list);
      setTags(counts);
      setVersion(String(Date.now()));
    } catch {
      setMessage("Não consegui ler as notas.");
    }
  }, [api]);

  useEffect(() => {
    let alive = true;
    (async () => {
      try {
        const state = await api.state();
        if (!alive) return;
        if (!state.configured) return setPhase("unconfigured");
        const folder = state.name ?? "";
        setName(folder);
        const saved = loadWorkspace(folder);
        setTabs(saved.tabs);
        setActive(saved.active);
        setBrowse(saved.active === null);
        setExpanded(new Set(saved.expanded));
        await refresh();
        api
          .bookmarks()
          .then((paths) => alive && setBookmarks(paths))
          .catch(() => undefined);
        if (alive) setPhase("ready");
      } catch (e) {
        if (!alive) return;
        setPhase(e instanceof ApiError && e.status === 409 ? "unconfigured" : "failed");
      }
    })();
    return () => {
      alive = false;
    };
  }, [api, refresh]);

  useEffect(() => {
    if (phase !== "ready") return;
    localStorage.setItem(workspaceKey(name), JSON.stringify({ tabs, active, expanded: [...expanded] }));
  }, [phase, name, tabs, active, expanded]);

  useFeatureEvents("brain", (event) => {
    if (event.type !== "changed") return;
    clearTimeout(refreshTimer.current);
    refreshTimer.current = setTimeout(() => void refresh(), REFRESH_DEBOUNCE_MS);
  });
  useEffect(() => () => clearTimeout(refreshTimer.current), []);

  const paths = useMemo(() => entries.map((e) => e.path), [entries]);

  const show = useCallback((path: string, options: { newTab?: boolean; focus?: Focus; record?: boolean } = {}) => {
    setBrowse(false);
    setQuery("");
    setMessage(null);
    setFocus(options.focus ?? null);
    setTabs((current) => {
      if (current.includes(path)) return current;
      const at = activeRef.current;
      if (options.newTab || at === null || !current.includes(at)) return [...current, path];
      return current.map((p) => (p === at ? path : p));
    });
    setActive(path);
    setExpanded((current) => new Set([...current, ...ancestorsOf(path)]));
    if (options.record !== false) {
      const h = history.current;
      if (h.stack[h.pos] !== path) {
        h.stack = [...h.stack.slice(0, h.pos + 1), path];
        h.pos = h.stack.length - 1;
      }
    }
  }, []);

  useEffect(() => {
    if (phase !== "ready") return;
    const raw = localStorage.getItem(OPEN_KEY);
    if (!raw) return;
    localStorage.removeItem(OPEN_KEY);
    try {
      const { path, line } = JSON.parse(raw) as { path?: unknown; line?: unknown };
      if (typeof path === "string") show(path, { focus: typeof line === "number" ? { line } : null });
    } catch {
      localStorage.removeItem(OPEN_KEY);
    }
  }, [phase, show]);

  const step = useCallback(
    (delta: number) => {
      const h = history.current;
      const next = h.pos + delta;
      const path = h.stack[next];
      if (path === undefined) return;
      h.pos = next;
      show(path, { record: false });
    },
    [show],
  );

  const close = useCallback((path: string) => {
    setTabs((current) => {
      const left = current.filter((p) => p !== path);
      if (activeRef.current === path) {
        const index = current.indexOf(path);
        const next = left[Math.min(index, left.length - 1)] ?? null;
        setActive(next);
        if (next === null) setBrowse(true);
      }
      return left;
    });
  }, []);

  const createAndOpen = useCallback(
    async (path: string, text?: string) => {
      try {
        const target = uniquePath(path, paths);
        await api.create(target, text);
        await refresh();
        show(target, { focus: null });
        setEditing((c) => new Set(c).add(target));
      } catch (e) {
        setMessage(e instanceof ApiError && e.status === 400 ? "Nome inválido." : "Não consegui criar a nota.");
      }
    },
    [api, paths, refresh, show],
  );

  const openLink = useCallback(
    async (target: string, heading: string, from: string, newTab = false) => {
      if (!target && heading) return setFocus({ heading });
      try {
        const found = await api.resolve(target, from);
        if (found) return show(found, { newTab, focus: heading ? { heading } : null });
        setOverlay({
          kind: "confirm",
          title: `A nota “${target}” ainda não existe`,
          message: `Criar em ${parentOf(from) || "raiz"}?`,
          confirm: "Criar nota",
          run: () => {
            setOverlay(null);
            void createAndOpen(target.includes("/") ? noteName(target) : join(parentOf(from), noteName(target)));
          },
        });
      } catch {
        setMessage("Não consegui resolver o link.");
      }
    },
    [api, show, createAndOpen],
  );

  const openDrawing = useCallback(
    (file: string, from: string) => {
      const wanted = file.toLowerCase();
      const found = paths.find((p) => p.toLowerCase() === wanted) ?? paths.find((p) => p.toLowerCase().endsWith("/" + wanted));
      if (found) return show(found);
      void openLink(file.replace(/\.md$/i, ""), "", from);
    },
    [paths, show, openLink],
  );

  const openFromDrawing = useCallback(
    (target: string, from: string) => {
      const [file = "", ...rest] = target.split("#");
      void openLink(file, rest.join("#"), from);
    },
    [openLink],
  );

  const toggleBookmark = useCallback(
    async (path: string) => {
      const next = bookmarks.includes(path) ? bookmarks.filter((p) => p !== path) : [...bookmarks, path];
      setBookmarks(next);
      try {
        await api.saveBookmarks(next);
      } catch {
        setMessage("Não consegui salvar os favoritos.");
        setBookmarks(bookmarks);
      }
    },
    [api, bookmarks],
  );

  const openDaily = useCallback(async () => {
    try {
      const { path } = await api.openDaily();
      await refresh();
      show(path);
    } catch {
      setMessage("Não consegui abrir a nota de hoje.");
    }
  }, [api, refresh, show]);

  const requestRename = (path: string, isFolder: boolean) => {
    setRenameState({ preview: null, error: null });
    setOverlay({ kind: "rename", path, isFolder });
  };

  const afterMove = useCallback(
    (from: string, to: string) => async () => {
      setOverlay(null);
      const rewrite = (p: string) => (p === from ? to : p.startsWith(from + "/") ? to + p.slice(from.length) : p);
      setTabs((c) => c.map(rewrite));
      setActive((a) => (a === null ? a : rewrite(a)));
      setBookmarks((b) => b.map(rewrite));
      await refresh();
    },
    [refresh],
  );

  const moveItem = useCallback(
    (from: string, to: string) => {
      setRenameState({ preview: null, error: null });
      api
        .previewRename(from, to)
        .then((preview) => {
          if (preview.link_count === 0 && preview.is_complete) return api.applyRename(from, to, preview.id).then(afterMove(from, to));
          setRenameState({ preview, error: null });
          setOverlay({ kind: "rename", path: from, isFolder: preview.is_folder });
        })
        .catch(() => setMessage("Não consegui mover."));
    },
    [api, afterMove],
  );

  const onAction = (action: TreeAction) => {
    if (action.kind === "bookmark") return void toggleBookmark(action.path);
    if (action.kind === "rename") return requestRename(action.path, action.isFolder);
    if (action.kind === "delete") {
      return setOverlay({
        kind: "confirm",
        title: "Mover para o Lixo?",
        message: `“${action.path}”${action.isFolder ? " (pasta)" : ""} vai para a Lixeira do Windows; dá para recuperar de lá. Links que apontavam para ele ficam sem destino.`,
        confirm: "Mover para o Lixo",
        run: () => {
          setOverlay(null);
          api
            .trash(action.path)
            .then(() => {
              setTabs((c) => c.filter((p) => p !== action.path && !p.startsWith(action.path + "/")));
              if (activeRef.current === action.path || activeRef.current?.startsWith(action.path + "/")) {
                setActive(null);
                setBrowse(true);
              }
              return refresh();
            })
            .catch(() => setMessage("Não consegui mover para a Lixeira."));
        },
      });
    }
    const folder = action.folder;
    if (action.kind === "new-drawing" || action.kind === "new-canvas") {
      return void api
        .newDrawing(action.kind === "new-drawing" ? "excalidraw" : "canvas", folder)
        .then(async ({ path }) => {
          await refresh();
          show(path);
        })
        .catch(() => setMessage("Não consegui criar o desenho."));
    }
    const folderLabel = folder ? ` em ${folder}` : "";
    setOverlay({
      kind: "prompt",
      title: action.kind === "new-note" ? "Nova nota" : "Nova pasta",
      label: action.kind === "new-note" ? "Nome da nota" : "Nome da pasta",
      confirm: "Criar",
      hint: folderLabel ? `Será criada${folderLabel}.` : undefined,
      submit: (value) => {
        setOverlay(null);
        if (action.kind === "new-note") return void createAndOpen(join(folder, noteName(value)));
        api
          .folder(join(folder, value))
          .then(async () => {
            setExpanded((c) => new Set([...c, folder, join(folder, value)].filter(Boolean)));
            await refresh();
          })
          .catch((e) => setMessage(e instanceof ApiError && e.status === 409 ? "Já existe uma pasta com esse nome." : "Não consegui criar a pasta."));
      },
    });
  };

  const ask = (text: string) =>
    setOverlay({
      kind: "prompt",
      title: "Perguntar ao Wisp sobre esta nota…",
      label: "Perguntar ao Wisp sobre esta nota",
      confirm: "Enviar",
      hint: "A nota vai junto como contexto na conversa atual.",
      submit: (question) => {
        const path = activeRef.current ?? "";
        setOverlay(null);
        shell.setDraft(`${question}\n\nNota: ${path}\n\n${text.slice(0, ASK_LIMIT)}`);
        shell.navigate("conversa");
      },
    });

  useEffect(() => {
    if (phase !== "ready") return;
    const onKey = (e: KeyboardEvent) => {
      if (!(e.ctrlKey || e.metaKey)) return;
      const key = e.key.toLowerCase();
      const at = activeRef.current;
      if (key === "o" && !e.shiftKey) setOverlay({ kind: "switcher" });
      else if (key === "e" && at && kindOf(at) === "note") setEditing((c) => {
        const next = new Set(c);
        if (!next.delete(at)) next.add(at);
        return next;
      });
      else if (key === "f" && e.shiftKey) {
        setBrowse(true);
        search.current?.focus();
      } else if (key === "d" && e.shiftKey) void openDaily();
      else if (e.key === "[") step(-1);
      else if (e.key === "]") step(1);
      else return;
      e.preventDefault();
    };
    window.addEventListener("keydown", onKey);
    return () => window.removeEventListener("keydown", onKey);
  }, [phase, openDaily, step]);

  const normalizeTarget = (to: string) => (overlay?.kind === "rename" && !overlay.isFolder && /\.md$/i.test(overlay.path) ? noteName(to) : to);

  const submitRename = (to: string) => {
    if (overlay?.kind !== "rename") return;
    const target = normalizeTarget(to);
    api
      .previewRename(overlay.path, target)
      .then((preview) => setRenameState({ preview, error: null }))
      .catch((e) => setRenameState({ preview: null, error: e instanceof ApiError && e.status === 409 ? `Já existe ${target}.` : "Não consegui preparar a mudança." }));
  };

  if (phase === "loading") return <TabCard title="Brain" icon={BrainIcon}><TabMessage text="Lendo notas…" /></TabCard>;
  if (phase === "unconfigured")
    return (
      <TabCard title="Brain" icon={BrainIcon}>
        <TabMessage text={"O brain não está configurado ou a pasta não existe.\nDefina a pasta das notas no Wisp e abra de novo."} />
      </TabCard>
    );
  if (phase === "failed") return <TabCard title="Brain" icon={BrainIcon}><TabMessage text="Não consegui falar com o Wisp." /></TabCard>;

  const noteCount = notes.length;
  const current = active && !browse ? active : null;
  const kind = current ? kindOf(current) : null;

  return (
    <TabCard title="Brain" icon={BrainIcon} trailing={`${noteCount} ${noteCount === 1 ? "nota" : "notas"}`}>
      <div className={styles.shell}>
        {showTree && (
          <Tree
            entries={entries}
            expanded={expanded}
            active={current}
            bookmarks={bookmarks}
            onToggle={(folder) =>
              setExpanded((c) => {
                const next = new Set(c);
                if (!next.delete(folder)) next.add(folder);
                return next;
              })
            }
            onCollapseAll={() => setExpanded(new Set())}
            onOpen={(path, newTab) => show(path, { newTab })}
            onAction={onAction}
            onMove={moveItem}
          />
        )}
        <div className={styles.main}>
          <div className={styles.bar}>
            <button type="button" className={styles.icon} onClick={() => setShowTree(!showTree)} aria-label="Mostrar ou esconder a árvore" title="Mostrar ou esconder a árvore">
              ☰
            </button>
            <button type="button" className={styles.icon} onClick={() => step(-1)} aria-label="Voltar" title="Voltar (Ctrl+[)">
              ←
            </button>
            <button type="button" className={styles.icon} onClick={() => step(1)} aria-label="Avançar" title="Avançar (Ctrl+])">
              →
            </button>
            <input
              ref={search}
              className={styles.search}
              aria-label="Buscar nota"
              placeholder="Buscar nota"
              value={query}
              onChange={(e) => {
                setQuery(e.target.value);
                setBrowse(true);
              }}
            />
            {query && (
              <button type="button" className={styles.icon} aria-label="Limpar busca" onClick={() => setQuery("")}>
                ×
              </button>
            )}
            <button type="button" className={styles.chip} onClick={() => setOverlay({ kind: "switcher" })} title="Ir para nota… (Ctrl+O)">
              Ir para nota…
            </button>
            <button type="button" className={styles.chip} onClick={() => void openDaily()} title="Nota de hoje (Ctrl+Shift+D)">
              Nota de hoje
            </button>
            <button type="button" className={styles.chip} onClick={() => setBrowse(true)}>
              Visão geral
            </button>
          </div>
          {tabs.length > 0 && (
            <div className={styles.tabs} role="tablist" aria-label="Notas abertas">
              {tabs.map((path) => (
                <span key={path} className={`${styles.tab} ${path === current ? styles.tabActive : ""}`}>
                  <button type="button" role="tab" aria-selected={path === current} onClick={() => show(path)} title={path}>
                    {tabTitle(path)}
                  </button>
                  <button type="button" aria-label="Fechar aba" onClick={() => close(path)}>
                    ×
                  </button>
                </span>
              ))}
            </div>
          )}
          {message && <p className={styles.notice}>{message}</p>}
          {current === null ? (
            <>
              <div className={styles.modes} role="group" aria-label="Exibição">
                {(["Grafo", "Lista"] as const).map((label) => {
                  const on = (label === "Grafo") === graph;
                  return (
                    <button
                      key={label}
                      type="button"
                      className={`${styles.chip} ${on ? styles.chipOn : ""}`}
                      aria-pressed={on}
                      onClick={() => {
                        setGraph(label === "Grafo");
                        localStorage.setItem(GRAPH_KEY, label === "Grafo" ? "graph" : "list");
                      }}
                    >
                      {label}
                    </button>
                  );
                })}
              </div>
              <Home
                api={api}
                graph={graph && !query.trim().startsWith("#")}
                query={query}
                version={version}
                onOpen={(path) => show(path)}
              />
            </>
          ) : kind === "note" ? (
            <NotePane
              key={current}
              api={api}
              path={current}
              focus={focus}
              editing={editing.has(current)}
              notes={notes}
              tags={tags}
              version={version}
              bookmarked={bookmarks.includes(current)}
              onEditing={(value) =>
                setEditing((c) => {
                  const next = new Set(c);
                  if (value) next.add(current);
                  else next.delete(current);
                  return next;
                })
              }
              onLink={(target, heading, from, newTab) => void openLink(target, heading, from, newTab)}
              onTag={(tag) => {
                setQuery(`#${tag}`);
                setBrowse(true);
                setGraph(false);
              }}
              onOpenDrawing={openDrawing}
              onOpenAt={(path, line) => show(path, { focus: { line } })}
              onGone={(path) => {
                close(path);
                setMessage(`${path} foi apagada ou movida fora do Wisp.`);
                void refresh();
              }}
              onRename={() => requestRename(current, false)}
              onDelete={() => onAction({ kind: "delete", path: current, isFolder: false })}
              onBookmark={() => void toggleBookmark(current)}
              onAsk={ask}
            />
          ) : kind === "drawing" ? (
            <DrawingPane key={current} api={api} path={current} onOpenNote={openFromDrawing} />
          ) : kind === "image" ? (
            <ImagePane api={api} path={current} />
          ) : (
            <p className={styles.notice}>O Wisp não abre {current} aqui.</p>
          )}
        </div>
      </div>
      {overlay?.kind === "switcher" && (
        <Switcher
          notes={notes}
          onClose={() => setOverlay(null)}
          onPick={(path) => {
            setOverlay(null);
            show(path);
          }}
        />
      )}
      {overlay?.kind === "prompt" && (
        <PromptDialog
          title={overlay.title}
          label={overlay.label}
          confirm={overlay.confirm}
          hint={overlay.hint}
          onSubmit={overlay.submit}
          onClose={() => setOverlay(null)}
        />
      )}
      {overlay?.kind === "confirm" && (
        <ConfirmDialog title={overlay.title} message={overlay.message} confirm={overlay.confirm} onConfirm={overlay.run} onClose={() => setOverlay(null)} />
      )}
      {overlay?.kind === "rename" && (
        <RenameDialog
          key={overlay.path}
          path={overlay.path}
          isFolder={overlay.isFolder}
          initial={renameState.preview?.to ?? (overlay.isFolder ? overlay.path : stripMd(overlay.path))}
          normalize={normalizeTarget}
          preview={renameState.preview}
          error={renameState.error}
          onPreview={submitRename}
          onApply={(preview) =>
            api
              .applyRename(preview.from, preview.to, preview.id)
              .then(afterMove(preview.from, preview.to))
              .catch((e) =>
                setRenameState({
                  preview: null,
                  error: e instanceof ApiError && e.status === 409 ? "Algo mudou no disco; veja a prévia de novo." : "Não consegui mover.",
                }),
              )
          }
          onClose={() => setOverlay(null)}
        />
      )}
    </TabCard>
  );
}
