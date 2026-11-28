import { fold } from "./rank";

export type CompletionContext = { kind: "link" | "tag"; query: string; start: number; end: number };

export function completionAt(text: string, cursor: number): CompletionContext | null {
  if (cursor < 0 || cursor > text.length) return null;
  const lineStart = text.lastIndexOf("\n", cursor - 1) + 1;
  const head = text.slice(lineStart, cursor);
  const open = head.lastIndexOf("[[");
  if (open >= 0) {
    const typed = head.slice(open + 2);
    if (!/[\]|#[]/.test(typed)) return { kind: "link", query: typed, start: lineStart + open + 2, end: cursor };
  }
  const match = /(?:^|[ \t])#([\p{L}\p{N}_/-]*)$/u.exec(head);
  if (match) return { kind: "tag", query: match[1]!, start: cursor - match[1]!.length, end: cursor };
  return null;
}

export function matchTags(query: string, counts: Record<string, number>, limit = 12): string[] {
  const needle = fold(query);
  return Object.entries(counts)
    .filter(([tag]) => !needle || fold(tag).includes(needle))
    .sort((a, b) => b[1] - a[1] || a[0].localeCompare(b[0]))
    .slice(0, limit)
    .map(([tag]) => tag);
}

export function applyCompletion(text: string, context: CompletionContext, insert: string): { text: string; cursor: number } {
  const after = text.slice(context.end);
  const closes = context.kind === "link" && !after.startsWith("]]");
  const tail = closes ? "]]" : "";
  const next = text.slice(0, context.start) + insert + tail + after;
  return { text: next, cursor: context.start + insert.length + (closes ? 2 : context.kind === "link" ? 2 : 0) };
}
