import { TerminalLayout, type Axis, type Direction, type Tab } from "./layout";

export type SessionLike = {
  readonly id: string;
  directory: string;
  onDirectory: ((path: string) => void) | null;
  start(size: { cols: number; rows: number }): void;
  close(): void;
  dispose(): void;
};

export type DirectoryMemory = { load(): string | null; save(path: string): void };

export type WorkspaceOptions<S extends SessionLike> = {
  home: string;
  memory: DirectoryMemory;
  makeSession: (directory: string) => S;
};

type ClosedTab = { tab: Tab; index: number; directories: Record<string, string> };

const CLOSED_TAB_LIMIT = 10;
const START_SIZE = { cols: 120, rows: 30 };

export class TerminalWorkspace<S extends SessionLike> {
  readonly layout = new TerminalLayout();
  sessions: S[] = [];
  renamingTabId: string | null = null;

  private closedTabs: ClosedTab[] = [];
  private openedFirst = false;
  private version = 0;
  private readonly listeners = new Set<() => void>();

  constructor(private readonly opts: WorkspaceOptions<S>) {}

  subscribe = (listener: () => void): (() => void) => {
    this.listeners.add(listener);
    return () => this.listeners.delete(listener);
  };
  getVersion = (): number => this.version;
  changed(): void {
    this.version += 1;
    for (const listener of this.listeners) listener();
  }

  get selectedId(): string | null {
    return this.layout.focusedSession;
  }
  get selected(): S | undefined {
    return this.selectedId ? this.session(this.selectedId) : undefined;
  }
  session(id: string): S | undefined {
    return this.sessions.find((s) => s.id === id);
  }

  private startDirectory(): string {
    return this.opts.memory.load() ?? this.opts.home;
  }

  private launch(directory: string): S {
    this.openedFirst = true;
    const session = this.opts.makeSession(directory);
    session.onDirectory = (path) => {
      this.opts.memory.save(path);
      this.changed();
    };
    this.sessions.push(session);
    session.start(START_SIZE);
    return session;
  }

  openFirstIfNeeded(): void {
    if (this.openedFirst) return;
    this.openedFirst = true;
    if (this.sessions.length === 0) this.openSession();
  }

  openSession(): S {
    const session = this.launch(this.selected?.directory ?? this.startDirectory());
    this.layout.addTab(session.id);
    this.changed();
    return session;
  }

  split(axis: Axis): boolean {
    const focused = this.selected;
    if (!focused) return false;
    const session = this.launch(focused.directory);
    this.layout.split(axis, session.id);
    this.changed();
    return true;
  }

  private act(done: boolean): boolean {
    if (done) this.changed();
    return done;
  }

  select(id: string): void {
    this.layout.focus(id);
    this.changed();
  }
  selectTab(id: string): void {
    this.layout.selectTab(id);
    this.changed();
  }
  selectTabAt(index: number): boolean {
    return this.act(this.layout.selectTabAt(index));
  }
  selectLastTab(): boolean {
    return this.act(this.layout.selectLastTab());
  }
  selectAdjacentTab(offset: number): boolean {
    return this.act(this.layout.selectAdjacentTab(offset));
  }
  moveSelectedTab(offset: number): boolean {
    return this.act(this.layout.moveSelectedTab(offset));
  }
  moveFocus(direction: Direction): boolean {
    return this.act(this.layout.moveFocus(direction));
  }
  focusAdjacentPane(offset: number): boolean {
    return this.act(this.layout.focusAdjacentPane(offset));
  }
  resizeFocused(direction: Direction): boolean {
    return this.act(this.layout.resizeFocused(direction));
  }
  toggleMaximize(): boolean {
    return this.act(this.layout.toggleMaximize());
  }
  resize(path: number[], ratio: number): void {
    this.layout.resize(path, ratio);
    this.changed();
  }
  renameSelectedTab(): boolean {
    const id = this.layout.selectedTabId;
    if (!id) return false;
    this.renamingTabId = id;
    this.changed();
    return true;
  }
  startRenaming(id: string): void {
    this.renamingTabId = id;
    this.changed();
  }
  rename(id: string, title: string | null): void {
    this.layout.rename(id, title);
    if (this.renamingTabId === id) this.renamingTabId = null;
    this.changed();
  }
  cancelRenaming(): void {
    this.renamingTabId = null;
    this.changed();
  }

  close(id: string): void {
    const index = this.layout.tabIndexContaining(id);
    if (index >= 0 && this.layout.tabs[index]!.sessions.length === 1 && this.layout.tabs[index]!.sessions[0] === id) this.rememberClosed(index);
    this.end(id);
    this.changed();
  }

  closeTab(id: string): void {
    const index = this.layout.tabs.findIndex((t) => t.id === id);
    if (index < 0) return;
    this.rememberClosed(index);
    for (const session of this.layout.tabs[index]!.sessions) this.end(session);
    this.changed();
  }

  closeSelected(): boolean {
    const id = this.selectedId;
    if (!id) return false;
    this.close(id);
    return true;
  }

  reopenClosedTab(): boolean {
    const closed = this.closedTabs.pop();
    if (!closed) return false;
    const map: Record<string, string> = {};
    for (const old of closed.tab.sessions) map[old] = this.launch(closed.directories[old] ?? this.startDirectory()).id;
    this.layout.insertTab(closed.tab.remapped(map), closed.index);
    this.changed();
    return true;
  }

  private rememberClosed(index: number): void {
    const tab = this.layout.tabs[index]!;
    const directories: Record<string, string> = {};
    for (const id of tab.sessions) {
      const session = this.session(id);
      if (session) directories[id] = session.directory;
    }
    this.closedTabs.push({ tab, index, directories });
    if (this.closedTabs.length > CLOSED_TAB_LIMIT) this.closedTabs.splice(0, this.closedTabs.length - CLOSED_TAB_LIMIT);
  }

  private end(id: string): void {
    const index = this.sessions.findIndex((s) => s.id === id);
    if (index < 0) return;
    const [session] = this.sessions.splice(index, 1);
    session!.close();
    this.opts.memory.save(session!.directory);
    session!.dispose();
    this.layout.close(id);
    if (this.renamingTabId && !this.layout.tabs.some((t) => t.id === this.renamingTabId)) this.renamingTabId = null;
  }

  closeAll(): void {
    const selected = this.selected;
    if (selected) this.opts.memory.save(selected.directory);
    for (const session of this.sessions) {
      session.close();
      session.dispose();
    }
    this.sessions = [];
    this.layout.removeAll();
    this.closedTabs = [];
    this.renamingTabId = null;
    this.changed();
  }
}
