export type CompletionKind = "dir" | "file" | "exec" | "builtin";

export type Completion = {
  insertText: string;
  display: string;
  kind: CompletionKind;
  replaceRange: [number, number];
};

export type DirEntry = { name: string; isDir: boolean };

export type CompletionContext = {
  cwd: string;
  home: string;
  list: (directory: string) => DirEntry[];
  executables: () => string[];
};

export const BUILTINS: readonly string[] = [
  "cd", "ls", "dir", "cat", "cp", "mv", "rm", "mkdir", "md", "rd", "rmdir", "cls", "clear", "pwd", "echo", "type", "copy", "move",
  "del", "erase", "ren", "history", "exit", "sleep", "sort", "where", "select", "measure", "man", "kill", "ps", "gc", "gci", "gcm",
  "gi", "sl", "sls", "iex", "irm", "iwr", "pushd", "popd", "set", "start", "which",
  "Get-ChildItem", "Set-Location", "Get-Location", "Get-Content", "Set-Content", "Add-Content", "Get-Process", "Stop-Process",
  "Select-String", "Remove-Item", "New-Item", "Copy-Item", "Move-Item", "Rename-Item", "Write-Host", "Write-Output", "Get-Command",
  "Get-Help", "Get-Item", "Get-Date", "Get-Service", "Test-Path", "Invoke-WebRequest", "Invoke-RestMethod", "Invoke-Expression",
  "Start-Process", "Out-File", "Format-Table", "ForEach-Object", "Where-Object", "Select-Object", "Sort-Object", "Measure-Object",
  "Import-Module", "Get-Module", "Set-ExecutionPolicy", "Clear-Host", "Push-Location", "Pop-Location", "Resolve-Path",
  "if", "else", "elseif", "foreach", "for", "while", "do", "switch", "function", "return", "try", "catch", "finally",
];

const DIRECTORY_ONLY = new Set(["cd", "pushd", "rmdir", "rd", "sl", "set-location", "push-location"]);
const SPECIALS = /[\s`'"(){}[\],;$&|<>@#%^=!]/;

type Token = {
  range: [number, number];
  value: string;
  openQuote: string | null;
  isCommand: boolean;
  command: string | null;
  pendingEscape: boolean;
  literalStart: boolean;
};

function tokenAt(line: string, cursor: number): Token {
  let start = 0;
  let value = "";
  let inWord = false;
  let quote: string | null = null;
  let escaped = false;
  let literalStart = false;
  let words: string[] = [];
  const begin = (at: number) => {
    if (!inWord) {
      inWord = true;
      start = at;
      literalStart = false;
    }
  };
  let offset = 0;
  for (const char of line) {
    if (offset >= cursor) break;
    if (escaped) {
      value += char;
      escaped = false;
    } else if (quote !== null) {
      if (char === quote) quote = null;
      else if (char === "`" && quote === '"') escaped = true;
      else value += char;
    } else if (char === "`") {
      begin(offset);
      if (value === "") literalStart = true;
      escaped = true;
    } else if (char === "'" || char === '"') {
      begin(offset);
      if (value === "") literalStart = true;
      quote = char;
    } else if (char === " " || char === "\t" || char === "\n") {
      if (inWord) {
        words.push(value);
        value = "";
        inWord = false;
      }
    } else if (char === "|" || char === ";" || char === "&") {
      inWord = false;
      value = "";
      words = [];
    } else {
      begin(offset);
      value += char;
    }
    offset += char.length;
  }
  const end = Math.min(offset, cursor);
  return {
    range: [inWord ? start : end, end],
    value: inWord ? value : "",
    openQuote: quote,
    isCommand: words.length === 0,
    command: words[0] ?? null,
    pendingEscape: escaped,
    literalStart: inWord && literalStart,
  };
}

function wordEnd(line: string, cursor: number, token: Token): number {
  let offset = 0;
  let quote = token.openQuote;
  let escaped = token.pendingEscape;
  for (const char of line) {
    const next = offset + char.length;
    const at = offset;
    offset = next;
    if (next <= cursor) continue;
    if (escaped) escaped = false;
    else if (quote !== null) {
      if (char === quote) quote = null;
      else if (char === "`" && quote === '"') escaped = true;
    } else if (char === "`") escaped = true;
    else if (char === "'" || char === '"') quote = char;
    else if (" \t\n|;&()<>".includes(char)) return at;
  }
  return Math.max(offset, cursor);
}

export function complete(line: string, cursor: number, context: CompletionContext): Completion[] {
  const atCursor = tokenAt(line, cursor);
  const token = tokenAt(line, wordEnd(line, cursor, atCursor));
  const looksLikePath =
    /[\\/]/.test(token.value) || (token.value.startsWith("~") && !token.literalStart) || token.value.startsWith(".") || /^[A-Za-z]:/.test(token.value);
  if (token.isCommand && !looksLikePath) return commands(token, context);
  return paths(token, context, token.command !== null && DIRECTORY_ONLY.has(token.command.toLowerCase()));
}

export function commonPrefix(completions: readonly Completion[]): string {
  const first = completions[0];
  if (!first) return "";
  let prefix = first.insertText;
  for (const item of completions.slice(1)) {
    let n = 0;
    while (n < prefix.length && n < item.insertText.length && prefix[n] === item.insertText[n]) n += 1;
    prefix = prefix.slice(0, n);
  }
  if (prefix.endsWith(" ") && !completions.every((c) => c.insertText === prefix)) prefix = prefix.slice(0, -1);
  return prefix;
}

const byName = (a: string, b: string): number => {
  const order = a.localeCompare(b, undefined, { sensitivity: "accent" });
  return order !== 0 ? order : a < b ? -1 : a > b ? 1 : 0;
};

function match(names: string[], prefix: string, kinds?: Map<string, boolean>): string[] {
  const lowered = prefix.toLowerCase();
  const found = names.filter((n) => n.toLowerCase().startsWith(lowered));
  return found.sort((a, b) => {
    if (kinds && kinds.get(a) !== kinds.get(b)) return kinds.get(a) === true ? -1 : 1;
    return byName(a, b);
  });
}

function commands(token: Token, context: CompletionContext): Completion[] {
  if (token.value === "") return [];
  const builtins = new Set(BUILTINS);
  const names = Array.from(new Set([...BUILTINS, ...context.executables()]));
  return match(names, token.value).map((name) => ({
    insertText: wrap(name, token, " ", SPECIALS.test(name)),
    display: name,
    kind: builtins.has(name) ? ("builtin" as const) : ("exec" as const),
    replaceRange: token.range,
  }));
}

function paths(token: Token, context: CompletionContext, directoriesOnly: boolean): Completion[] {
  const value = token.value;
  if (value === "~" && token.openQuote === null && !token.literalStart) {
    return [{ insertText: "~\\", display: "~\\", kind: "dir", replaceRange: token.range }];
  }
  const split = Math.max(value.lastIndexOf("\\"), value.lastIndexOf("/")) + 1;
  const typedDirectory = value.slice(0, split);
  const prefix = value.slice(split);
  const entries = context.list(resolve(typedDirectory, context)).slice();
  if (prefix.startsWith(".")) entries.push({ name: "..", isDir: true });
  const visible = entries.filter((e) => prefix.startsWith(".") || !e.name.startsWith("."));
  const isDir = new Map<string, boolean>();
  for (const entry of visible) if (!isDir.has(entry.name)) isDir.set(entry.name, entry.isDir);
  const out: Completion[] = [];
  for (const name of match(Array.from(isDir.keys()), prefix, isDir)) {
    const dir = isDir.get(name) ?? false;
    if (directoriesOnly && !dir) continue;
    const full = typedDirectory + name + (dir ? "\\" : "");
    const quoted = token.openQuote !== null || SPECIALS.test(typedDirectory + name);
    out.push({
      insertText: quoted ? wrap(full, token, dir ? "" : " ", true) : full + (dir ? "" : " "),
      display: name + (dir ? "\\" : ""),
      kind: dir ? "dir" : "file",
      replaceRange: token.range,
    });
  }
  return out;
}

function resolve(typed: string, context: CompletionContext): string {
  if (typed === "") return context.cwd;
  const expanded = typed.startsWith("~/") || typed.startsWith("~\\") ? context.home + typed.slice(1) : typed;
  const normal = expanded.replace(/\//g, "\\");
  const absolute = /^[A-Za-z]:/.test(normal) || normal.startsWith("\\\\") ? normal : normal.startsWith("\\") ? `${context.cwd.slice(0, 2)}${normal}` : `${context.cwd}\\${normal}`;
  const unc = absolute.startsWith("\\\\");
  const parts: string[] = [];
  for (const part of absolute.split("\\")) {
    if (part === "" || part === ".") continue;
    if (part === "..") {
      if (parts.length > (unc ? 2 : 1)) parts.pop();
    } else parts.push(part);
  }
  const joined = parts.join("\\");
  if (unc) return `\\\\${joined}`;
  return parts.length === 1 && /^[A-Za-z]:$/.test(parts[0]!) ? `${joined}\\` : joined;
}

function wrap(text: string, token: Token, ending: string, quoteIfNeeded: boolean): string {
  const quote = token.openQuote ?? (quoteIfNeeded ? "'" : null);
  if (quote === null) return text + ending;
  const inside = quote === "'" ? text.replace(/'/g, "''") : text.replace(/(["$`])/g, "`$1");
  return quote + inside + (ending === "" ? "" : quote + ending);
}
