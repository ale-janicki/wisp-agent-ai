import { useCallback, useState, type KeyboardEvent } from "react";
import { PaneArea } from "./PaneArea";
import { blockText } from "./BlockRow";
import { shortcutFor, type Shortcut } from "./shortcuts";
import { preferences, type TerminalStore } from "./store";
import { TabsColumn } from "./TabsColumn";
import { useWorkspace } from "./hooks";
import styles from "./TerminalTab.module.css";

export function runShortcut(store: TerminalStore, shortcut: Shortcut, ui: { toggleTabs: () => void; toggleFind: () => void }): boolean {
  const { workspace } = store;
  switch (shortcut.type) {
    case "newTab": workspace.openSession(); return true;
    case "closePane": return workspace.closeSelected();
    case "reopenTab": return workspace.reopenClosedTab();
    case "split": return workspace.split(shortcut.axis);
    case "maximize": return workspace.toggleMaximize();
    case "rename": return workspace.renameSelectedTab();
    case "selectTab": return workspace.selectTabAt(shortcut.index);
    case "lastTab": return workspace.selectLastTab();
    case "adjacentTab": return workspace.selectAdjacentTab(shortcut.offset);
    case "adjacentPane": return workspace.focusAdjacentPane(shortcut.offset);
    case "moveTab": return workspace.moveSelectedTab(shortcut.offset);
    case "moveFocus": return workspace.moveFocus(shortcut.direction);
    case "resizePane": return workspace.resizeFocused(shortcut.direction);
    case "toggleTabs": ui.toggleTabs(); return true;
    case "find": ui.toggleFind(); return true;
    case "toggleGrid": workspace.selected?.toggleGrid(); return workspace.selected !== undefined;
    case "copy": return copySelection(store, shortcut.what);
  }
}

function copySelection(store: TerminalStore, what: "command" | "output"): boolean {
  const session = store.workspace.selected;
  if (!session) return false;
  const text = (window.getSelection()?.toString() ?? "") || session.engine.selection?.() || "";
  if (text !== "") {
    void navigator.clipboard.writeText(text);
    return true;
  }
  const block = session.blocks.block(session.selectedBlockId);
  if (!block) return false;
  void navigator.clipboard.writeText(blockText(block, what));
  return true;
}

export function TerminalView({ store }: { store: TerminalStore }) {
  const { workspace } = store;
  useWorkspace(workspace);
  const [collapsed, setCollapsed] = useState(preferences.tabsCollapsed());
  const [finding, setFinding] = useState<string | null>(null);
  const [, redraw] = useState(0);
  const tab = workspace.layout.selectedTab;

  const toggleTabs = useCallback(() => {
    setCollapsed((was) => {
      preferences.setTabsCollapsed(!was);
      return !was;
    });
  }, []);
  const toggleFind = useCallback(() => setFinding((was) => (was === null ? (workspace.selectedId ?? null) : null)), [workspace]);

  const onKeyDown = (event: KeyboardEvent<HTMLDivElement>) => {
    const shortcut = shortcutFor(event.nativeEvent);
    if (!shortcut) return;
    if (runShortcut(store, shortcut, { toggleTabs, toggleFind })) {
      event.preventDefault();
      event.stopPropagation();
    }
  };

  return (
    <div className={styles.terminal} onKeyDownCapture={onKeyDown}>
      <TabsColumn store={store} collapsed={collapsed} onToggle={toggleTabs} onShellChange={() => redraw((n) => n + 1)} />
      <section className={styles.content} aria-label="Terminal">
        {tab ? (
          <PaneArea key={tab.id} store={store} tab={tab} findFor={finding} onCloseFind={() => setFinding(null)} />
        ) : (
          <div className={styles.empty}>
            <p>Nenhuma sessão aberta</p>
            <button type="button" onClick={() => workspace.openSession()}>
              Nova sessão
            </button>
          </div>
        )}
      </section>
    </div>
  );
}
