import { useEffect, useState } from "react";
import { abbreviateDirectory } from "./directory";
import { matchesQuery, tabTitle, type Tab } from "./layout";
import { useWorkspace } from "./hooks";
import type { TerminalSession } from "./session";
import type { TerminalStore } from "./store";
import styles from "./TabsColumn.module.css";

const GLYPH: Record<string, { text: string; className: string; label: string }> = {
  idle: { text: "›", className: styles.idle!, label: "Parado" },
  running: { text: "◐", className: styles.running!, label: "Em execução" },
  succeeded: { text: "✓", className: styles.ok!, label: "Terminou" },
  failed: { text: "✕", className: styles.fail!, label: "Falhou" },
};

function shortcut(index: number, count: number): string | null {
  if (index < 8) return `Ctrl+${index + 1}`;
  return index === count - 1 ? "Ctrl+9" : null;
}

type Props = { store: TerminalStore; collapsed: boolean; onToggle: () => void; onShellChange: () => void };

export function TabsColumn({ store, collapsed, onToggle, onShellChange }: Props) {
  const { workspace } = store;
  useWorkspace(workspace);
  const [query, setQuery] = useState("");
  const [draft, setDraft] = useState("");
  const [menu, setMenu] = useState<{ id: string; x: number; y: number; title: string } | null>(null);
  const renaming = workspace.renamingTabId;
  const tabs = workspace.layout.tabs;

  useEffect(() => {
    if (!menu) return;
    const close = () => setMenu(null);
    window.addEventListener("mousedown", close);
    return () => window.removeEventListener("mousedown", close);
  }, [menu]);

  const info = (tab: Tab) => {
    const session: TerminalSession | undefined = workspace.session(tab.focused);
    const title = tabTitle(tab.customTitle, session?.activity.command ?? null, session?.name ?? "");
    const folder = session ? abbreviateDirectory(session.directory, store.home) : "";
    return { title: title || tab.customTitle || "", folder, state: session?.activity.state ?? "idle", directory: session?.directory ?? "" };
  };

  const startRenaming = (tab: Tab, title: string) => {
    setDraft(tab.customTitle ?? title);
    workspace.startRenaming(tab.id);
  };
  const finishRenaming = (tab: Tab, title: string) => {
    if (tab.customTitle === null && draft === title) workspace.cancelRenaming();
    else workspace.rename(tab.id, draft);
  };

  if (collapsed) {
    return (
      <nav className={`${styles.column} ${styles.collapsed}`} aria-label="Abas do terminal">
        <button type="button" className={styles.iconButton} onClick={onToggle} title="Mostrar abas (Ctrl+Shift+B)" aria-label="Mostrar abas">
          ☰
        </button>
        <button type="button" className={styles.iconButton} onClick={() => workspace.openSession()} title="Nova aba (Ctrl+Shift+T)" aria-label="Nova aba">
          +
        </button>
      </nav>
    );
  }

  const rows = tabs.map((tab, index) => ({ tab, index, ...info(tab) })).filter((r) => matchesQuery(query, [r.title, r.folder]));

  return (
    <nav className={styles.column} aria-label="Abas do terminal">
      <div className={styles.head}>
        <input
          className={styles.search}
          value={query}
          placeholder="Buscar abas…"
          aria-label="Buscar abas"
          onChange={(event) => setQuery(event.target.value)}
        />
        <button type="button" className={styles.iconButton} onClick={onToggle} title="Esconder abas (Ctrl+Shift+B)" aria-label="Esconder abas">
          ☰
        </button>
      </div>
      <button type="button" className={styles.newRow} onClick={() => workspace.openSession()} title="Nova aba (Ctrl+Shift+T)">
        <span className={styles.plus}>+</span>
        <span className={styles.newLabel}>Nova aba</span>
      </button>
      <div className={styles.rows}>
        {rows.map(({ tab, index, title, folder, state, directory }) => {
          const selected = workspace.layout.selectedTabId === tab.id;
          const g = GLYPH[state] ?? GLYPH.idle!;
          const key = shortcut(index, tabs.length);
          return (
            <div
              key={tab.id}
              className={`${styles.row} ${selected ? styles.selected : ""}`}
              onContextMenu={(event) => {
                event.preventDefault();
                setMenu({ id: tab.id, x: event.clientX, y: event.clientY, title });
              }}
            >
              {renaming === tab.id ? (
                <div className={styles.rowMain}>
                  <span className={`${styles.glyph} ${g.className}`}>{g.text}</span>
                  <input
                    className={styles.rename}
                    value={draft}
                    aria-label="Nome da aba"
                    autoFocus
                    onChange={(event) => setDraft(event.target.value)}
                    onBlur={() => finishRenaming(tab, title)}
                    onKeyDown={(event) => {
                      if (event.key === "Enter") finishRenaming(tab, title);
                      if (event.key === "Escape") workspace.cancelRenaming();
                    }}
                  />
                </div>
              ) : (
                <button
                  type="button"
                  className={styles.rowMain}
                  aria-current={selected}
                  title={key ? `${title} — ${key}${directory ? `\n${directory}` : ""}` : directory}
                  onClick={() => workspace.selectTab(tab.id)}
                  onDoubleClick={() => startRenaming(tab, title)}
                >
                  <span className={`${styles.glyph} ${g.className}`} title={g.label} aria-label={g.label}>
                    {g.text}
                  </span>
                  <span className={styles.text}>
                    <span className={styles.title}>{title}</span>
                    <span className={styles.folder}>{folder}</span>
                  </span>
                </button>
              )}
              <button type="button" className={styles.close} onClick={() => workspace.closeTab(tab.id)} title="Fechar aba" aria-label="Fechar aba">
                ✕
              </button>
            </div>
          );
        })}
      </div>
      <ShellPicker store={store} onChange={onShellChange} />
      {menu && (
        <div className={styles.menu} role="menu" style={{ left: menu.x, top: menu.y }} onMouseDown={(event) => event.stopPropagation()}>
          <button
            type="button"
            role="menuitem"
            onClick={() => {
              const tab = tabs.find((t) => t.id === menu.id);
              setMenu(null);
              if (tab) startRenaming(tab, menu.title);
            }}
          >
            Renomear
          </button>
          <button
            type="button"
            role="menuitem"
            onClick={() => {
              setMenu(null);
              workspace.closeTab(menu.id);
            }}
          >
            Fechar aba
          </button>
        </div>
      )}
    </nav>
  );
}

function ShellPicker({ store, onChange }: { store: TerminalStore; onChange: () => void }) {
  if (store.shells.length < 2) return null;
  return (
    <label className={styles.shell}>
      <span>Shell</span>
      <select
        value={store.shellId()}
        onChange={(event) => {
          store.setShell(event.target.value as ReturnType<TerminalStore["shellId"]>);
          onChange();
        }}
      >
        {store.shells.map((s) => (
          <option key={s.id} value={s.id}>
            {s.label}
          </option>
        ))}
      </select>
    </label>
  );
}
