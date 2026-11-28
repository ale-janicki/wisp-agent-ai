export const SCHEMES = { note: "wisp-note:", embed: "wisp-embed:", file: "wisp-file:", draw: "wisp-draw:", tag: "wisp-tag:" } as const;

export type Href = { kind: keyof typeof SCHEMES; value: string; width?: number } | { kind: "web"; value: string };

export function parseHref(href: string | undefined): Href | null {
  if (!href) return null;
  for (const kind of Object.keys(SCHEMES) as (keyof typeof SCHEMES)[]) {
    const scheme = SCHEMES[kind];
    if (!href.startsWith(scheme)) continue;
    const rest = href.slice(scheme.length);
    const [value = "", query = ""] = kind === "file" ? rest.split("#w=") : [rest];
    const width = kind === "file" && query ? Number(query) : undefined;
    return { kind, value: decodeURIComponent(value), ...(width && Number.isFinite(width) ? { width } : {}) };
  }
  return /^(https?:|mailto:)/i.test(href) ? { kind: "web", value: href } : null;
}

const IMAGE = /\.(png|jpe?g|gif|svg|webp|bmp)$/i;
const DRAWING = /\.(excalidraw(\.md)?|canvas)$/i;
const enc = encodeURIComponent;

export function frontmatterEnd(lines: string[]): number {
  if (lines[0]?.trim() !== "---") return 0;
  for (let i = 1; i < lines.length; i++) {
    const t = lines[i]?.trim();
    if (t === "---" || t === "...") return i + 1;
  }
  return 0;
}

function inline(segment: string): string {
  return segment
    .replace(/!\[\[([^\]\n]+?)\]\]/g, (_m, inner: string) => {
      const [target = "", size] = inner.split("|");
      const name = target.trim();
      if (IMAGE.test(name)) return `![${name}](${SCHEMES.file}${enc(name)}${size && /^\d+$/.test(size.trim()) ? `#w=${size.trim()}` : ""})`;
      if (DRAWING.test(name)) return `[${name}](${SCHEMES.draw}${enc(name)})`;
      return `[${name}](${SCHEMES.embed}${enc(name)})`;
    })
    .replace(/\[\[([^\]\n|]*?)(?:\|([^\]\n]*))?\]\]/g, (_m, target: string, alias?: string) => {
      const name = target.trim();
      const shown = (alias ?? name).replace(/[[\]]/g, "") || name;
      return `[${shown}](${SCHEMES.note}${enc(name)})`;
    })
    .replace(/(^|[\s(])#([\w/-]*[\p{L}][\w/\p{L}-]*)/gu, (_m, lead: string, tag: string) => `${lead}[#${tag}](${SCHEMES.tag}${enc(tag)})`);
}

export function prepare(text: string): string {
  const uncommented = text.replace(/%%[\s\S]*?%%/g, (m) => m.replace(/[^\n]/g, ""));
  const lines = uncommented.split("\n");
  const start = frontmatterEnd(lines);
  let fence: string | null = null;
  const out = lines.map((line, index) => {
    if (index < start) return "";
    const marker = /^\s{0,3}(`{3,}|~{3,})/.exec(line)?.[1];
    if (marker) {
      if (fence === null) fence = marker[0]!;
      else if (marker[0] === fence) fence = null;
      return line;
    }
    if (fence !== null) return line;
    const converted = line
      .split(/(`+[^`]*`+)/)
      .map((part, i) => (i % 2 === 1 ? part : inline(part)))
      .join("");
    const next = lines[index + 1];
    const softBreak = converted.trim() !== "" && next !== undefined && next.trim() !== "" && !/^\s{0,3}(`{3,}|~{3,})/.test(next);
    return softBreak && !converted.endsWith("  ") ? `${converted}  ` : converted;
  });
  return out.join("\n");
}

export function headingSection(text: string, heading: string): string {
  const lines = text.split("\n");
  const wanted = heading.trim().toLowerCase();
  const start = lines.findIndex((l) => {
    const m = /^(#{1,6})\s+(.*?)\s*#*\s*$/.exec(l);
    return m !== null && m[2]!.trim().toLowerCase() === wanted;
  });
  if (start < 0) return "";
  const level = /^#+/.exec(lines[start]!)![0].length;
  let end = lines.length;
  for (let i = start + 1; i < lines.length; i++) {
    const m = /^(#{1,6})\s/.exec(lines[i]!);
    if (m && m[1]!.length <= level) {
      end = i;
      break;
    }
  }
  return lines.slice(start, end).join("\n");
}
