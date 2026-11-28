export type Axis = "horizontal" | "vertical";
export type Direction = "left" | "right" | "up" | "down";
export type Rect = { x: number; y: number; w: number; h: number };

export type LayoutNode = { kind: "leaf"; session: string } | { kind: "split"; axis: Axis; ratio: number; first: LayoutNode; second: LayoutNode };

export const RATIO_MIN = 0.15;
export const RATIO_MAX = 0.85;
const UNIT: Rect = { x: 0, y: 0, w: 1, h: 1 };

const leaf = (session: string): LayoutNode => ({ kind: "leaf", session });

export const leaves = (node: LayoutNode): string[] => (node.kind === "leaf" ? [node.session] : [...leaves(node.first), ...leaves(node.second)]);
export const contains = (node: LayoutNode, session: string): boolean => leaves(node).includes(session);

function divide(rect: Rect, axis: Axis, ratio: number): [Rect, Rect] {
  if (axis === "horizontal") {
    const w = rect.w * ratio;
    return [{ ...rect, w }, { ...rect, x: rect.x + w, w: rect.w - w }];
  }
  const h = rect.h * ratio;
  return [{ ...rect, h }, { ...rect, y: rect.y + h, h: rect.h - h }];
}

function framesOf(node: LayoutNode, rect: Rect): Record<string, Rect> {
  if (node.kind === "leaf") return { [node.session]: rect };
  const [a, b] = divide(rect, node.axis, node.ratio);
  return { ...framesOf(node.first, a), ...framesOf(node.second, b) };
}

export type Divider = {
  path: number[];
  axis: Axis;
  ratio: number;
  bounds: Rect;
  ratioAt(point: { x: number; y: number }): number;
};

function dividersOf(node: LayoutNode, rect: Rect, path: number[]): Divider[] {
  if (node.kind === "leaf") return [];
  const [a, b] = divide(rect, node.axis, node.ratio);
  const { axis, ratio } = node;
  const divider: Divider = {
    path,
    axis,
    ratio,
    bounds: rect,
    ratioAt: (p) => (axis === "horizontal" ? (rect.w > 0 ? (p.x - rect.x) / rect.w : ratio) : rect.h > 0 ? (p.y - rect.y) / rect.h : ratio),
  };
  return [divider, ...dividersOf(node.first, a, [...path, 0]), ...dividersOf(node.second, b, [...path, 1])];
}

function replacing(node: LayoutNode, session: string, by: LayoutNode): LayoutNode {
  if (node.kind === "leaf") return node.session === session ? by : node;
  return { ...node, first: replacing(node.first, session, by), second: replacing(node.second, session, by) };
}

function removing(node: LayoutNode, session: string): { node: LayoutNode; heir: string } | null {
  if (node.kind === "leaf") return null;
  if (node.first.kind === "leaf" && node.first.session === session) return { node: node.second, heir: leaves(node.second)[0] ?? session };
  if (node.second.kind === "leaf" && node.second.session === session) return { node: node.first, heir: leaves(node.first).at(-1) ?? session };
  if (contains(node.first, session)) {
    const rest = removing(node.first, session);
    if (rest) return { node: { ...node, first: rest.node }, heir: rest.heir };
  }
  if (contains(node.second, session)) {
    const rest = removing(node.second, session);
    if (rest) return { node: { ...node, second: rest.node }, heir: rest.heir };
  }
  return null;
}

function remap(node: LayoutNode, map: Record<string, string>): LayoutNode {
  if (node.kind === "leaf") return leaf(map[node.session] ?? node.session);
  return { ...node, first: remap(node.first, map), second: remap(node.second, map) };
}

function settingRatio(node: LayoutNode, ratio: number, path: readonly number[]): LayoutNode {
  if (node.kind === "leaf") return node;
  const [step, ...rest] = path;
  if (step === undefined) return { ...node, ratio };
  return step === 0 ? { ...node, first: settingRatio(node.first, ratio, rest) } : { ...node, second: settingRatio(node.second, ratio, rest) };
}

function nearestSplit(node: LayoutNode, axis: Axis, session: string, path: number[]): number[] | null {
  if (node.kind === "leaf" || !contains(node, session)) return null;
  const inside = contains(node.first, session)
    ? nearestSplit(node.first, axis, session, [...path, 0])
    : nearestSplit(node.second, axis, session, [...path, 1]);
  return inside ?? (node.axis === axis ? path : null);
}

export type Tab = {
  id: string;
  customTitle: string | null;
  root: LayoutNode;
  focused: string;
  maximized: boolean;
  readonly sessions: string[];
  readonly frames: Record<string, Rect>;
  readonly dividers: Divider[];
  remapped(map: Record<string, string>): Tab;
};

export function makeTab(fields: { id: string; customTitle: string | null; root: LayoutNode; focused: string; maximized: boolean }): Tab {
  return {
    ...fields,
    get sessions() {
      return leaves(this.root);
    },
    get frames() {
      return this.maximized ? { [this.focused]: UNIT } : framesOf(this.root, UNIT);
    },
    get dividers() {
      return this.maximized ? [] : dividersOf(this.root, UNIT, []);
    },
    remapped(map) {
      return makeTab({ ...fields, root: remap(this.root, map), focused: map[this.focused] ?? this.focused, maximized: this.maximized, customTitle: this.customTitle });
    },
  };
}

export function neighbour(session: string, direction: Direction, frames: Record<string, Rect>): string | null {
  const from = frames[session];
  if (!from) return null;
  const epsilon = 1e-6;
  let best: { id: string; distance: number; centred: boolean; along: number } | null = null;
  for (const [id, rect] of Object.entries(frames)) {
    if (id === session) continue;
    let distance: number;
    let overlap: number;
    let centred: boolean;
    let along: number;
    if (direction === "left" || direction === "right") {
      distance = direction === "right" ? rect.x - (from.x + from.w) : from.x - (rect.x + rect.w);
      overlap = Math.min(rect.y + rect.h, from.y + from.h) - Math.max(rect.y, from.y);
      centred = rect.y <= from.y + from.h / 2 && from.y + from.h / 2 < rect.y + rect.h;
      along = rect.y;
    } else {
      distance = direction === "down" ? rect.y - (from.y + from.h) : from.y - (rect.y + rect.h);
      overlap = Math.min(rect.x + rect.w, from.x + from.w) - Math.max(rect.x, from.x);
      centred = rect.x <= from.x + from.w / 2 && from.x + from.w / 2 < rect.x + rect.w;
      along = rect.x;
    }
    if (!(distance > -epsilon) || !(overlap > epsilon)) continue;
    if (best) {
      if (distance > best.distance + epsilon) continue;
      if (Math.abs(distance - best.distance) <= epsilon) {
        if (best.centred && !centred) continue;
        if (best.centred === centred && along >= best.along) continue;
      }
    }
    best = { id, distance, centred, along };
  }
  return best?.id ?? null;
}

export class TerminalLayout {
  tabs: Tab[] = [];
  selectedTabId: string | null = null;

  get selectedTab(): Tab | undefined {
    return this.tabs.find((t) => t.id === this.selectedTabId);
  }
  get selectedIndex(): number {
    return this.tabs.findIndex((t) => t.id === this.selectedTabId);
  }
  get focusedSession(): string | null {
    return this.selectedTab?.focused ?? null;
  }
  tabIndexContaining(session: string): number {
    return this.tabs.findIndex((t) => contains(t.root, session));
  }

  private update(index: number, change: Partial<Pick<Tab, "root" | "focused" | "maximized" | "customTitle">>): void {
    const tab = this.tabs[index]!;
    this.tabs[index] = makeTab({ id: tab.id, customTitle: tab.customTitle, root: tab.root, focused: tab.focused, maximized: tab.maximized, ...change });
  }

  addTab(session: string, id: string = crypto.randomUUID()): void {
    this.tabs.push(makeTab({ id, customTitle: null, root: leaf(session), focused: session, maximized: false }));
    this.selectedTabId = id;
  }

  selectTab(id: string): boolean {
    if (!this.tabs.some((t) => t.id === id)) return false;
    this.selectedTabId = id;
    return true;
  }
  selectTabAt(index: number): boolean {
    const tab = this.tabs[index];
    if (!tab) return false;
    this.selectedTabId = tab.id;
    return true;
  }
  selectLastTab(): boolean {
    const last = this.tabs.at(-1);
    if (!last) return false;
    this.selectedTabId = last.id;
    return true;
  }
  selectAdjacentTab(offset: number): boolean {
    const index = this.selectedIndex;
    if (index < 0 || this.tabs.length < 2) return false;
    const count = this.tabs.length;
    this.selectedTabId = this.tabs[(((index + offset) % count) + count) % count]!.id;
    return true;
  }
  moveTab(source: number, destination: number): void {
    if (source === destination || !this.tabs[source] || !this.tabs[destination]) return;
    const [tab] = this.tabs.splice(source, 1);
    this.tabs.splice(destination, 0, tab!);
  }
  moveSelectedTab(offset: number): boolean {
    const index = this.selectedIndex;
    if (index < 0 || offset === 0 || !this.tabs[index + offset]) return false;
    this.moveTab(index, index + offset);
    return true;
  }
  insertTab(tab: Tab, at: number): void {
    if (this.tabs.some((t) => t.id === tab.id)) return;
    this.tabs.splice(Math.min(Math.max(at, 0), this.tabs.length), 0, tab);
    this.selectedTabId = tab.id;
  }
  rename(id: string, title: string | null): void {
    const index = this.tabs.findIndex((t) => t.id === id);
    if (index < 0) return;
    const trimmed = title?.trim() ?? "";
    this.update(index, { customTitle: trimmed === "" ? null : trimmed });
  }
  closeTab(id: string): string[] {
    const index = this.tabs.findIndex((t) => t.id === id);
    if (index < 0) return [];
    const [removed] = this.tabs.splice(index, 1);
    if (this.selectedTabId === id) this.selectedTabId = this.tabs.length === 0 ? null : this.tabs[Math.min(index, this.tabs.length - 1)]!.id;
    return removed!.sessions;
  }
  removeAll(): void {
    this.tabs = [];
    this.selectedTabId = null;
  }

  focus(session: string): boolean {
    const index = this.tabIndexContaining(session);
    if (index < 0) return false;
    this.selectedTabId = this.tabs[index]!.id;
    if (this.tabs[index]!.focused !== session) this.update(index, { focused: session, maximized: false });
    return true;
  }
  split(axis: Axis, session: string): boolean {
    const index = this.selectedIndex;
    if (index < 0 || this.tabIndexContaining(session) >= 0) return false;
    const tab = this.tabs[index]!;
    const node: LayoutNode = { kind: "split", axis, ratio: 0.5, first: leaf(tab.focused), second: leaf(session) };
    this.update(index, { root: replacing(tab.root, tab.focused, node), focused: session, maximized: false });
    return true;
  }
  close(session: string): "pane" | "tab" | null {
    const index = this.tabIndexContaining(session);
    if (index < 0) return null;
    const tab = this.tabs[index]!;
    const rest = removing(tab.root, session);
    if (!rest) {
      this.closeTab(tab.id);
      return "tab";
    }
    this.update(index, { root: rest.node, maximized: false, focused: tab.focused === session ? rest.heir : tab.focused });
    return "pane";
  }
  moveFocus(direction: Direction): boolean {
    const index = this.selectedIndex;
    if (index < 0 || this.tabs[index]!.maximized) return false;
    const tab = this.tabs[index]!;
    const next = neighbour(tab.focused, direction, tab.frames);
    if (!next) return false;
    this.update(index, { focused: next });
    return true;
  }
  focusAdjacentPane(offset: number): boolean {
    const index = this.selectedIndex;
    if (index < 0 || this.tabs[index]!.maximized) return false;
    const tab = this.tabs[index]!;
    const panes = tab.sessions;
    const at = panes.indexOf(tab.focused);
    if (panes.length < 2 || at < 0) return false;
    this.update(index, { focused: panes[(((at + offset) % panes.length) + panes.length) % panes.length]! });
    return true;
  }
  resizeFocused(direction: Direction, step = 0.05): boolean {
    const index = this.selectedIndex;
    if (index < 0 || this.tabs[index]!.maximized) return false;
    const tab = this.tabs[index]!;
    const axis: Axis = direction === "left" || direction === "right" ? "horizontal" : "vertical";
    const path = nearestSplit(tab.root, axis, tab.focused, []);
    const divider = path && tab.dividers.find((d) => d.path.join() === path.join());
    if (!path || !divider) return false;
    this.resize(path, divider.ratio + (direction === "right" || direction === "down" ? step : -step));
    return true;
  }
  toggleMaximize(): boolean {
    const index = this.selectedIndex;
    if (index < 0) return false;
    const tab = this.tabs[index]!;
    if (!tab.maximized && tab.sessions.length < 2) return false;
    this.update(index, { maximized: !tab.maximized });
    return true;
  }
  resize(path: number[], ratio: number): void {
    const index = this.selectedIndex;
    if (index < 0 || !Number.isFinite(ratio)) return;
    this.update(index, { root: settingRatio(this.tabs[index]!.root, Math.min(Math.max(ratio, RATIO_MIN), RATIO_MAX), path) });
  }
}

const SKIPPED = new Set(["sudo", "env", "exec", "command", "builtin", "nohup", "time", "noglob"]);

export function commandName(command: string): string | null {
  const word = command.split(/\s+/).find((w) => w !== "" && !w.includes("=") && !SKIPPED.has(w));
  if (!word) return null;
  return word.split(/[\\/]/).pop() || null;
}

export function tabTitle(custom: string | null, command: string | null, fallback: string): string {
  if (custom) return custom;
  const name = command ? commandName(command) : null;
  return name ?? fallback;
}

const fold = (text: string): string => text.normalize("NFD").replace(/\p{M}/gu, "").toLowerCase();

export function matchesQuery(query: string, fields: readonly string[]): boolean {
  const words = query.split(/\s+/).filter((w) => w !== "");
  if (words.length === 0) return true;
  const folded = fields.map(fold);
  return words.every((w) => folded.some((f) => f.includes(fold(w))));
}
