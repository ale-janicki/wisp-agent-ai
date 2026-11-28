import { useMemo, useState } from "react";
import { displayName, parentOf, treeRows } from "./treeRows";
import type { TreeEntry } from "./types";
import styles from "./Tree.module.css";

type Create = { kind: "new-note"; folder: string } | { kind: "new-folder"; folder: string } | { kind: "new-drawing"; folder: string } | { kind: "new-canvas"; folder: string };
type Item = { kind: "rename"; path: string; isFolder: boolean } | { kind: "delete"; path: string; isFolder: boolean } | { kind: "bookmark"; path: string; isFolder: boolean };
export type TreeAction = Create | Item;

type Props = {
  entries: TreeEntry[];
  expanded: ReadonlySet<string>;
  active: string | null;
  bookmarks: string[];
  onToggle: (folder: string) => void;
  onCollapseAll: () => void;
  onOpen: (path: string, newTab: boolean) => void;
  onAction: (action: TreeAction) => void;
  onMove: (from: string, to: string) => void;
};

export function Tree({ entries, expanded, active, bookmarks, onToggle, onCollapseAll, onOpen, onAction, onMove }: Props) {
  const rows = useMemo(() => treeRows(entries, expanded), [entries, expanded]);
  const [menu, setMenu] = useState<{ path: string; isFolder: boolean; x: number; y: number } | null>(null);
  const [over, setOver] = useState<string | null>(null);
  const stars = new Set(bookmarks);

  const folderFor = (path: string, isFolder: boolean) => (isFolder ? path : parentOf(path));
  const choose = (action: TreeAction) => {
    setMenu(null);
    onAction(action);
  };

  return (
    <nav className={styles.tree} aria-label="Pastas e notas" onClick={() => setMenu(null)}>
      <div className={styles.head}>
        <span>Pastas e notas</span>
        <span className={styles.tools}>
          <button type="button" title="Nova nota" aria-label="Nova nota" onClick={() => onAction({ kind: "new-note", folder: "" })}>
            +
          </button>
          <button type="button" title="Recolher tudo" aria-label="Recolher tudo" onClick={onCollapseAll}>
            ⊟
          </button>
        </span>
      </div>
      <div className={styles.rows} role="tree">
        {bookmarks.length > 0 && (
          <div className={styles.group}>
            <span className={styles.caption}>Favoritos</span>
            {bookmarks.map((path) => (
              <button key={path} type="button" className={`${styles.row} ${path === active ? styles.active : ""}`} onClick={(e) => onOpen(path, e.ctrlKey || e.metaKey)}>
                ★ {displayName(path, false)}
              </button>
            ))}
          </div>
        )}
        {rows.length === 0 && <p className={styles.empty}>Nenhuma nota</p>}
        {rows.map((row) => (
          <button
            key={row.path}
            type="button"
            role="treeitem"
            aria-expanded={row.isFolder ? row.expanded : undefined}
            draggable
            className={`${styles.row} ${row.path === active ? styles.active : ""} ${over === row.path ? styles.over : ""}`}
            style={{ paddingLeft: 8 + row.depth * 14 }}
            onClick={(e) => (row.isFolder ? onToggle(row.path) : onOpen(row.path, e.ctrlKey || e.metaKey))}
            onContextMenu={(e) => {
              e.preventDefault();
              setMenu({ path: row.path, isFolder: row.isFolder, x: e.clientX, y: e.clientY });
            }}
            onDragStart={(e) => e.dataTransfer.setData("text/wisp-path", row.path)}
            onDragOver={(e) => {
              if (row.isFolder) {
                e.preventDefault();
                setOver(row.path);
              }
            }}
            onDragLeave={() => setOver(null)}
            onDrop={(e) => {
              e.preventDefault();
              setOver(null);
              const from = e.dataTransfer.getData("text/wisp-path");
              if (from && row.isFolder && from !== row.path && !row.path.startsWith(from + "/")) onMove(from, `${row.path}/${from.split("/").pop()}`);
            }}
          >
            <span className={styles.glyph}>{row.isFolder ? (row.expanded ? "▾" : "▸") : "·"}</span>
            <span className={styles.name}>{row.name}</span>
            {row.isFolder && <span className={styles.count}>{row.childCount}</span>}
            {stars.has(row.path) && <span className={styles.star}>★</span>}
          </button>
        ))}
      </div>
      {menu && (
        <ul className={styles.menu} style={{ left: menu.x, top: menu.y }} role="menu">
          {[
            ["Nova nota aqui", () => choose({ kind: "new-note", folder: folderFor(menu.path, menu.isFolder) })],
            [menu.isFolder ? "Nova subpasta" : "Nova pasta", () => choose({ kind: "new-folder", folder: folderFor(menu.path, menu.isFolder) })],
            ["Novo desenho aqui", () => choose({ kind: "new-drawing", folder: folderFor(menu.path, menu.isFolder) })],
            ["Novo canvas aqui", () => choose({ kind: "new-canvas", folder: folderFor(menu.path, menu.isFolder) })],
            ["Renomear ou mover…", () => choose({ kind: "rename", path: menu.path, isFolder: menu.isFolder })],
            ...(menu.isFolder ? [] : [[stars.has(menu.path) ? "Remover dos favoritos" : "Favoritar", () => choose({ kind: "bookmark", path: menu.path, isFolder: false })] as const]),
            ["Mover para o Lixo", () => choose({ kind: "delete", path: menu.path, isFolder: menu.isFolder })],
          ].map(([label, run]) => (
            <li key={String(label)} role="none">
              <button type="button" role="menuitem" onClick={run as () => void}>
                {String(label)}
              </button>
            </li>
          ))}
        </ul>
      )}
    </nav>
  );
}
