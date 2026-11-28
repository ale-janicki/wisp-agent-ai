import type { TreeEntry } from "./types";

export type Row = { path: string; name: string; depth: number; isFolder: boolean; expanded: boolean; childCount: number };

export const parentOf = (path: string): string => {
  const at = path.lastIndexOf("/");
  return at < 0 ? "" : path.slice(0, at);
};

export const displayName = (path: string, isFolder: boolean): string => {
  const name = path.slice(path.lastIndexOf("/") + 1);
  return isFolder ? name : name.replace(/\.md$/i, "");
};

export function treeRows(entries: TreeEntry[], expanded: ReadonlySet<string>): Row[] {
  const children = new Map<string, TreeEntry[]>();
  for (const entry of entries) {
    const key = parentOf(entry.path);
    const list = children.get(key) ?? [];
    list.push(entry);
    children.set(key, list);
  }
  const collator = new Intl.Collator(undefined, { sensitivity: "base", numeric: true });
  for (const list of children.values()) {
    list.sort((a, b) => {
      if (a.is_folder !== b.is_folder) return a.is_folder ? -1 : 1;
      const order = collator.compare(displayName(a.path, a.is_folder), displayName(b.path, b.is_folder));
      return order || (a.path < b.path ? -1 : 1);
    });
  }
  const rows: Row[] = [];
  const walk = (parent: string, depth: number) => {
    for (const entry of children.get(parent) ?? []) {
      const open = entry.is_folder && expanded.has(entry.path);
      rows.push({
        path: entry.path,
        name: displayName(entry.path, entry.is_folder),
        depth,
        isFolder: entry.is_folder,
        expanded: open,
        childCount: children.get(entry.path)?.length ?? 0,
      });
      if (open) walk(entry.path, depth + 1);
    }
  };
  walk("", 0);
  return rows;
}

export const ancestorsOf = (path: string): string[] => {
  const out: string[] = [];
  for (let current = parentOf(path); current; current = parentOf(current)) out.push(current);
  return out;
}

export function uniquePath(wanted: string, existing: Iterable<string>): string {
  const lowered = new Set([...existing].map((p) => p.toLowerCase()));
  if (!lowered.has(wanted.toLowerCase())) return wanted;
  const dot = wanted.lastIndexOf(".");
  const slash = wanted.lastIndexOf("/");
  const hasExt = dot > slash + 1;
  const base = hasExt ? wanted.slice(0, dot) : wanted;
  const ext = hasExt ? wanted.slice(dot) : "";
  for (let n = 2; ; n++) {
    const candidate = `${base} ${n}${ext}`;
    if (!lowered.has(candidate.toLowerCase())) return candidate;
  }
}

export const kindOf = (path: string): "note" | "drawing" | "image" | "other" => {
  const lowered = path.toLowerCase();
  if (/\.(excalidraw\.md|excalidraw|canvas)$/.test(lowered)) return "drawing";
  if (lowered.endsWith(".md")) return "note";
  return /\.(png|jpe?g|gif|svg|webp|bmp)$/.test(lowered) ? "image" : "other";
};
