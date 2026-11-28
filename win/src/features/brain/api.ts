import type { FeatureApi } from "../../api/feature";
import type {
  Backlink,
  DrawingDoc,
  Doc,
  GraphData,
  Hit,
  NoteSummary,
  Outgoing,
  Property,
  RenamePreview,
  TreeEntry,
} from "./types";

export type BrainApi = ReturnType<typeof brainApi>;

export function brainApi(api: FeatureApi) {
  return {
    state: () => api.get<{ configured: boolean; name?: string }>("/state"),
    tree: async () => (await api.get<{ entries: TreeEntry[] }>("/tree")).entries,
    notes: async () => (await api.get<{ items: NoteSummary[] }>("/notes")).items,
    note: (path: string) => api.get<Doc>("/note", { path }),
    save: (path: string, text: string, base?: string, force?: boolean) =>
      api.put<{ mtime: number }>("/note", { path, text, base, force }),
    create: (path: string, text?: string) => api.post<{ path: string }>("/note", { path, text }),
    folder: (path: string) => api.post<{ path: string }>("/folder", { path }),
    trash: (path: string) => api.post<{ ok: boolean }>("/trash", { path }),
    previewRename: (from: string, to: string) => api.post<RenamePreview>("/rename/preview", { from, to }),
    applyRename: (from: string, to: string, id: string) => api.post<{ ok: boolean; path: string }>("/rename/apply", { from, to, id }),
    search: async (q: string) => (await api.get<{ items: Hit[] }>("/search", { q })).items,
    recent: async () => (await api.get<{ items: { path: string; title: string; modified: number }[] }>("/recent")).items,
    backlinks: async (path: string) => (await api.get<{ items: Backlink[] }>("/backlinks", { path })).items,
    outgoing: async (path: string) => (await api.get<{ items: Outgoing[] }>("/outgoing", { path })).items,
    resolve: async (name: string, from?: string) => (await api.get<{ path: string | null }>("/resolve", { name, from })).path,
    graph: () => api.get<GraphData>("/graph"),
    tags: async () => (await api.get<{ tags: Record<string, number> }>("/tags")).tags,
    toggleTask: (path: string, line: number, expected: string) =>
      api.post<{ text: string; mtime: number }>("/task", { path, line, expected }),
    properties: async (path: string) => (await api.get<{ has_frontmatter: boolean; items: Property[] }>("/properties", { path })).items,
    setProperty: (path: string, key: string, value: string | string[]) => api.post<{ text: string }>("/property", { path, key, value }),
    removeProperty: (path: string, key: string) => api.post<{ text: string }>("/property", { path, key, remove: true }),
    merge: (base: string, mine: string, theirs: string) => api.post<{ kind: string; text: string }>("/merge", { base, mine, theirs }),
    recover: (path: string, text: string) => api.post<{ saved: string }>("/recover", { path, text }),
    daily: () => api.get<{ path: string; exists: boolean }>("/daily"),
    openDaily: () => api.post<{ path: string }>("/daily"),
    bookmarks: async () => (await api.get<{ paths: string[] }>("/bookmarks")).paths,
    saveBookmarks: (paths: string[]) => api.put<{ paths: string[] }>("/bookmarks", { paths }),
    attachment: (name: string, from?: string) => api.get<{ path: string; mime: string; data: string }>("/attachment", { name, from }),
    drawing: (path: string) => api.get<DrawingDoc>("/drawing", { path }),
    saveDrawing: (path: string, scene: string, hash: string, force?: boolean) =>
      api.put<{ hash: string }>("/drawing", { path, scene, hash, force }),
    newDrawing: (kind: "excalidraw" | "canvas", folder: string) => api.post<{ path: string }>("/drawing/new", { kind, folder }),
  };
}
