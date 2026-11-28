import type { ApiEvent, ViewMode } from "./types";

export type CalEvent = Omit<ApiEvent, "start" | "end"> & { start: Date; end: Date };
export type Segment = { id: string; startMinute: number; endMinute: number };
export type Placement = Segment & { column: number; columns: number; span: number };

const MINUTES_PER_DAY = 1440;
const MINIMUM_VISIBLE = 20;
const DAY_MS = 86_400_000;

export const startOfDay = (d: Date) => new Date(d.getFullYear(), d.getMonth(), d.getDate());
export const addDays = (d: Date, n: number) => new Date(d.getFullYear(), d.getMonth(), d.getDate() + n, d.getHours(), d.getMinutes());
export const sameDay = (a: Date, b: Date) => a.getFullYear() === b.getFullYear() && a.getMonth() === b.getMonth() && a.getDate() === b.getDate();
export const weekStart = (d: Date) => addDays(startOfDay(d), -d.getDay());
export const dayKey = (d: Date) => `${d.getFullYear()}-${String(d.getMonth() + 1).padStart(2, "0")}-${String(d.getDate()).padStart(2, "0")}`;

const localDay = (iso: string) => {
  const [y, m, d] = iso.slice(0, 10).split("-").map(Number);
  return new Date(y!, m! - 1, d!);
};

export function parseEvent(e: ApiEvent): CalEvent {
  if (e.all_day) return { ...e, start: localDay(e.start), end: addDays(localDay(e.end), 1) };
  return { ...e, start: new Date(e.start), end: new Date(e.end) };
}

export const lastDay = (e: CalEvent) => startOfDay(e.end > e.start ? new Date(e.end.getTime() - 1) : e.start);

export function eventsOnDay(events: CalEvent[], day: Date): CalEvent[] {
  const from = startOfDay(day);
  const to = addDays(from, 1);
  return events
    .filter((e) => e.start < to && (e.end > from || (e.start.getTime() === e.end.getTime() && e.start >= from)))
    .sort((a, b) => Number(b.all_day) - Number(a.all_day) || a.start.getTime() - b.start.getTime() || b.end.getTime() - a.end.getTime() || a.id.localeCompare(b.id));
}

const minuteOfDay = (d: Date, roundUp = false) => d.getHours() * 60 + d.getMinutes() + (roundUp && (d.getSeconds() > 0 || d.getMilliseconds() > 0) ? 1 : 0);

export function segmentOn(e: CalEvent, day: Date): Segment | null {
  if (e.all_day) return null;
  const from = startOfDay(day);
  const to = addDays(from, 1);
  if (!(e.start < to && (e.end > from || (e.start.getTime() === e.end.getTime() && e.start >= from)))) return null;
  const lower = e.start > from ? e.start : from;
  const upper = e.end < to ? e.end : to;
  const startMinute = lower <= from ? 0 : minuteOfDay(lower);
  const rawEnd = upper >= to ? MINUTES_PER_DAY : minuteOfDay(upper, true);
  return { id: e.id, startMinute: Math.min(startMinute, MINUTES_PER_DAY - 1), endMinute: Math.min(MINUTES_PER_DAY, Math.max(rawEnd, startMinute + MINIMUM_VISIBLE)) };
}

function placeCluster(cluster: Segment[]): Placement[] {
  const ends: number[] = [];
  const assigned: [Segment, number][] = [];
  for (const segment of cluster) {
    const free = ends.findIndex((end) => end <= segment.startMinute);
    if (free >= 0) {
      ends[free] = segment.endMinute;
      assigned.push([segment, free]);
    } else {
      ends.push(segment.endMinute);
      assigned.push([segment, ends.length - 1]);
    }
  }
  return assigned.map(([segment, column]) => {
    let span = 1;
    for (let next = column + 1; next < ends.length; next++) {
      const blocked = assigned.some(([o, c]) => c === next && o.startMinute < segment.endMinute && o.endMinute > segment.startMinute);
      if (blocked) break;
      span += 1;
    }
    return { ...segment, column, columns: ends.length, span };
  });
}

export function place(segments: Segment[]): Placement[] {
  const ordered = [...segments].sort((a, b) => a.startMinute - b.startMinute || b.endMinute - a.endMinute || a.id.localeCompare(b.id));
  const placements: Placement[] = [];
  let cluster: Segment[] = [];
  let clusterEnd = Number.NEGATIVE_INFINITY;
  for (const segment of ordered) {
    if (segment.startMinute >= clusterEnd && cluster.length > 0) {
      placements.push(...placeCluster(cluster));
      cluster = [];
      clusterEnd = Number.NEGATIVE_INFINITY;
    }
    cluster.push(segment);
    clusterEnd = Math.max(clusterEnd, segment.endMinute);
  }
  if (cluster.length > 0) placements.push(...placeCluster(cluster));
  return placements;
}

export function monthWeeks(anchor: Date): Date[][] {
  const first = new Date(anchor.getFullYear(), anchor.getMonth(), 1);
  const last = new Date(anchor.getFullYear(), anchor.getMonth() + 1, 0);
  const weeks: Date[][] = [];
  for (let start = weekStart(first); start <= last; start = addDays(start, 7)) {
    weeks.push(Array.from({ length: 7 }, (_, i) => addDays(start, i)));
  }
  return weeks;
}

export function rangeFor(mode: ViewMode, anchor: Date): { start: Date; end: Date } {
  if (mode === "day") return { start: startOfDay(anchor), end: addDays(startOfDay(anchor), 1) };
  if (mode === "week") return { start: weekStart(anchor), end: addDays(weekStart(anchor), 7) };
  const weeks = monthWeeks(anchor);
  return { start: weeks[0]![0]!, end: addDays(weeks.at(-1)!.at(-1)!, 1) };
}

export const sentenceCase = (text: string) => (text ? text[0]!.toUpperCase() + text.slice(1) : text);

export function titleFor(mode: ViewMode, anchor: Date): string {
  if (mode === "day") return sentenceCase(new Intl.DateTimeFormat("pt-BR", { weekday: "long", day: "numeric", month: "long" }).format(anchor));
  return sentenceCase(new Intl.DateTimeFormat("pt-BR", { month: "long", year: "numeric" }).format(anchor));
}

export function step(mode: ViewMode, anchor: Date, direction: 1 | -1): Date {
  if (mode === "day") return addDays(anchor, direction);
  if (mode === "week") return addDays(anchor, 7 * direction);
  return new Date(anchor.getFullYear(), anchor.getMonth() + direction, 1);
}

export const clockLabel = (d: Date) => new Intl.DateTimeFormat("pt-BR", { hour: "2-digit", minute: "2-digit", hour12: false }).format(d);

export function whenLabel(e: CalEvent): string {
  if (e.all_day) {
    const last = lastDay(e);
    const fmt = new Intl.DateTimeFormat("pt-BR", { weekday: "short", day: "numeric", month: "short" });
    return sameDay(e.start, last) ? `Dia todo · ${fmt.format(e.start)}` : `Dia todo · ${fmt.format(e.start)} – ${fmt.format(last)}`;
  }
  const day = new Intl.DateTimeFormat("pt-BR", { weekday: "short", day: "numeric", month: "short" }).format(e.start);
  return `${day} · ${clockLabel(e.start)}–${clockLabel(e.end)}`;
}

export const msUntil = (a: Date, b: Date) => (b.getTime() - a.getTime()) / DAY_MS;
