export type TaskItem = {
  line: string;
  occurrence: number;
  index: number;
  owner: string | null;
  front: string | null;
  title: string;
  detail: string;
  urgent: boolean;
  alert_id: string | null;
};
export type TaskGroup = { title: string | null; items: TaskItem[] };

const fold = (text: string) => text.normalize("NFD").replace(/\p{M}/gu, "").toLowerCase();

export function filterGroups(groups: TaskGroup[], query: string): TaskGroup[] {
  const words = query.split(/\s+/).filter(Boolean).map(fold);
  if (words.length === 0) return groups;
  return groups.flatMap((group) => {
    const items = group.items.filter((item) => {
      const shown = fold([item.owner, item.front, item.title, item.detail].filter((p): p is string => !!p).join(" "));
      return words.every((w) => shown.includes(w));
    });
    return items.length ? [{ title: group.title, items }] : [];
  });
}

export const urgentFirst = (groups: TaskGroup[]): TaskGroup[] =>
  groups.map((g) => ({ title: g.title, items: [...g.items.filter((i) => i.urgent), ...g.items.filter((i) => !i.urgent)] }));

export const itemKey = (item: TaskItem) => `${item.occurrence}|${item.line}`;
