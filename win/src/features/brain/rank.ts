import type { NoteSummary } from "./types";

export type Ranked = { path: string; title: string; alias: string | null; score: number };

export const fold = (text: string): string =>
  text.normalize("NFKD").replace(/\p{M}/gu, "").toLowerCase();

const withoutMd = (path: string) => path.replace(/\.md$/i, "");
const isSeparator = (c: string | undefined) => c === " " || c === "-" || c === "_" || c === "/" || c === ".";

export function score(needle: string, haystack: string): number | null {
  if (needle.length > haystack.length) return null;
  const at = haystack.indexOf(needle);
  if (at >= 0) {
    const boundary = at === 0 || isSeparator(haystack[at - 1]);
    return 200 - Math.min(at, 60) + (boundary ? 40 : 0) + (needle.length === haystack.length ? 100 : 0);
  }
  let total = 0;
  let next = 0;
  let previous = -2;
  for (const ch of needle) {
    const found = haystack.indexOf(ch, next);
    if (found < 0) return null;
    let gain = 1;
    if (found === 0 || isSeparator(haystack[found - 1])) gain += 12;
    if (found === previous + 1) gain += 8;
    total += gain - Math.min(found - Math.max(previous, -1) - 1, 3);
    previous = found;
    next = found + 1;
  }
  return Math.max(total, 1);
}

export function rank(query: string, notes: NoteSummary[], limit = 30): Ranked[] {
  const needle = fold(query.trim());
  if (!needle) {
    return [...notes]
      .sort((a, b) => b.modified - a.modified || a.path.localeCompare(b.path))
      .slice(0, limit)
      .map((n) => ({ path: n.path, title: n.title, alias: null, score: 0 }));
  }
  const scored: Ranked[] = [];
  for (const note of notes) {
    let best: { score: number; alias: string | null } | null = null;
    const title = score(needle, fold(note.title));
    if (title !== null) best = { score: title + 20, alias: null };
    for (const alias of note.aliases) {
      const s = score(needle, fold(alias));
      if (s !== null && s + 10 > (best?.score ?? 0)) best = { score: s + 10, alias };
    }
    if (!best) {
      const s = score(needle, fold(withoutMd(note.path)));
      if (s !== null) best = { score: Math.floor(s / 2), alias: null };
    }
    if (best) scored.push({ path: note.path, title: note.title, alias: best.alias, score: best.score - Math.floor(note.title.length / 8) });
  }
  scored.sort((a, b) => b.score - a.score || a.title.length - b.title.length || a.path.localeCompare(b.path));
  return scored.slice(0, limit);
}
