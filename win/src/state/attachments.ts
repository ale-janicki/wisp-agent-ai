export type AttachmentItem =
  | { kind: "file"; path: string; name: string; bytes: number }
  | { kind: "failed"; label: string };

export type ParsedAttachments = { origin: string; items: AttachmentItem[]; caption: string | null };

export const NO_CAPTION = "(sem texto — veja o que é e me diga)";
export const DEFAULT_USER = "usuario";
const HEAD_PREFIX = "[o ";
const HEAD_ENVIOU = " enviou ";
const HEAD_MIDDLE = " arquivo(s) pelo ";
const HEAD_SUFFIX = ", ja salvos nesta maquina:";
const FAILED_MARKER = ": nao consegui baixar";
const IMAGE_EXTENSIONS = new Set(["jpg", "jpeg", "png", "heic", "gif", "webp"]);
const ABSOLUTE = /^(?:\/|[A-Za-z]:[\\/]|\\\\)/;
const SEPARATORS = /[\\/]/;

const lastComponent = (path: string) => path.split(SEPARATORS).pop() ?? path;

export function isImage(name: string): boolean {
  const dot = name.lastIndexOf(".");
  return dot >= 0 && IMAGE_EXTENSIONS.has(name.slice(dot + 1).toLowerCase());
}

export function composeAttachments(
  files: { path: string; name: string; bytes: number }[],
  caption: string,
  origin = "Wisp",
  user = DEFAULT_USER,
): string {
  const lines = files.map((f) => `- ${f.path} (${f.name}, ${f.bytes} bytes)`);
  return (
    `${HEAD_PREFIX}${user}${HEAD_ENVIOU}${files.length}${HEAD_MIDDLE}${origin}${HEAD_SUFFIX}\n` +
    `${lines.join("\n")}]\n\n${caption.trim() || NO_CAPTION}`
  );
}

const isPlaceholder = (caption: string) =>
  caption === NO_CAPTION || (caption.startsWith("(sem texto") && caption.endsWith(")") && !caption.includes("\n"));

function fileLabel(line: string): string {
  const head = line.split(" (", 1)[0] ?? line;
  return lastComponent(head);
}

function parseItem(body: string): AttachmentItem {
  if (!ABSOLUTE.test(body) || !body.endsWith(" bytes)")) {
    const label = body.includes(FAILED_MARKER) ? body.split(FAILED_MARKER, 1)[0]! : body;
    return { kind: "failed", label: fileLabel(label) };
  }
  const inner = body.slice(0, -" bytes)".length);
  const comma = inner.lastIndexOf(", ");
  const count = comma >= 0 ? inner.slice(comma + 2) : "";
  if (comma < 0 || !/^\d+$/.test(count)) return { kind: "failed", label: fileLabel(body) };
  const both = inner.slice(0, comma);
  const cuts: number[] = [];
  for (let at = both.indexOf(" ("); at >= 0; at = both.indexOf(" (", at + 1)) cuts.push(at);
  const chosen = cuts.find((c) => lastComponent(both.slice(0, c)).endsWith(both.slice(c + 2))) ?? cuts[cuts.length - 1];
  if (chosen === undefined) return { kind: "failed", label: fileLabel(body) };
  return { kind: "file", path: both.slice(0, chosen), name: both.slice(chosen + 2), bytes: Number(count) };
}

export function parseAttachments(text: string): ParsedAttachments | null {
  const lines = text.split("\n");
  const head = lines[0] ?? "";
  if (!head.startsWith(HEAD_PREFIX) || !head.endsWith(HEAD_SUFFIX)) return null;
  const afterPrefix = head.slice(HEAD_PREFIX.length);
  const who = afterPrefix.indexOf(HEAD_ENVIOU);
  if (who < 0) return null;
  const middle = afterPrefix.slice(who + HEAD_ENVIOU.length, afterPrefix.length - HEAD_SUFFIX.length);
  const split = middle.indexOf(HEAD_MIDDLE);
  const declared = split >= 0 ? middle.slice(0, split) : "";
  if (!/^\d+$/.test(declared) || Number(declared) <= 0) return null;
  const items: AttachmentItem[] = [];
  let index = 1;
  let closed = false;
  while (index < lines.length && !closed) {
    let line = lines[index]!;
    if (!line.startsWith("- ")) return null;
    if (line.endsWith("]")) {
      line = line.slice(0, -1);
      closed = true;
    }
    items.push(parseItem(line.slice(2)));
    index += 1;
  }
  if (!closed || items.length !== Number(declared)) return null;
  const rest = lines.slice(index).join("\n").trim();
  return { origin: middle.slice(split + HEAD_MIDDLE.length), items, caption: !rest || isPlaceholder(rest) ? null : rest };
}

function isBlockHead(text: string): boolean {
  if (!text.startsWith(HEAD_PREFIX)) return false;
  const head = text.split("\n", 1)[0]!.slice(HEAD_PREFIX.length);
  for (let at = head.indexOf(HEAD_ENVIOU); at >= 0; at = head.indexOf(HEAD_ENVIOU, at + 1)) {
    const rest = head.slice(at + HEAD_ENVIOU.length);
    const digits = /^\d+/.exec(rest)?.[0] ?? "";
    const after = rest.slice(digits.length);
    if (digits && after.startsWith(HEAD_MIDDLE) && ["Telegram", "Wisp"].some((o) => after.slice(HEAD_MIDDLE.length).startsWith(o))) {
      return true;
    }
  }
  return false;
}

export function unparsedAttachments(text: string): ParsedAttachments | null {
  if (!isBlockHead(text) || parseAttachments(text)) return null;
  const at = text.indexOf("]\n\n");
  const rest = at >= 0 ? text.slice(at + 3).trim() : "";
  return { origin: "", items: [], caption: !rest || isPlaceholder(rest) ? null : rest };
}

export function attachmentsOf(text: string): ParsedAttachments | null {
  return parseAttachments(text) ?? unparsedAttachments(text);
}

export function summarize(found: ParsedAttachments): string {
  const files = found.items.filter((i) => i.kind === "file");
  const photos = files.filter((i) => isImage(i.name)).length;
  const others = found.items.length - photos;
  const parts: string[] = found.items.length === 0 ? ["anexos"] : [];
  if (photos > 0) parts.push(photos === 1 ? "1 foto" : `${photos} fotos`);
  if (others > 0) parts.push(others === 1 ? "1 arquivo" : `${others} arquivos`);
  if (found.caption) parts.push(found.caption);
  return parts.join(" · ");
}

export function displayName(name: string): string {
  const match = /^wisp-[0-9a-fA-F]{8}-(.+)$/.exec(name);
  return match ? match[1]! : name;
}

export function formatBytes(bytes: number): string {
  if (bytes < 1000) return bytes === 1 ? "1 byte" : `${bytes} bytes`;
  const units = ["KB", "MB", "GB"];
  let value = bytes / 1000;
  let unit = 0;
  while (value >= 1000 && unit < units.length - 1) {
    value /= 1000;
    unit += 1;
  }
  const text = value >= 100 ? Math.round(value).toString() : (Math.round(value * 10) / 10).toString();
  return `${text.replace(".", ",")} ${units[unit]}`;
}
