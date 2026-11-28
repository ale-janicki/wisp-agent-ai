const EXTENDED = /^: \d+:\d+;/;

function continues(entry: string, marker: "`" | "\\"): boolean {
  let count = 0;
  for (let i = entry.length - 1; i >= 0 && entry[i] === marker; i--) count += 1;
  return count % 2 === 1;
}

export function parseHistory(text: string): string[] {
  const lines = text.replace(/\r\n/g, "\n").split("\n");
  const entries: string[] = [];
  const add = (entry: string) => {
    if (entry.trim() === "" || entries[entries.length - 1] === entry) return;
    entries.push(entry);
  };
  let index = 0;
  while (index < lines.length) {
    let line = lines[index]!;
    index += 1;
    const extended = EXTENDED.exec(line);
    if (extended) line = line.slice(extended[0].length);
    let entry = line;
    while (continues(entry, extended ? "\\" : "`") && index < lines.length) {
      entry = `${entry.slice(0, -1)}\n${lines[index]!}`;
      index += 1;
    }
    add(entry);
  }
  return entries;
}

const isSubsequence = (needle: string, haystack: string): boolean => {
  let at = 0;
  for (const char of haystack) {
    if (at >= needle.length) return true;
    if (char === needle[at]) at += 1;
  }
  return at >= needle.length;
};

export class CommandHistory {
  private storage: string[] = [];
  private seeded = false;

  constructor(private readonly capacity = 10_000) {}

  get entries(): readonly string[] {
    return this.storage;
  }

  get isSeeded(): boolean {
    return this.seeded;
  }

  seed(loaded: readonly string[]): void {
    if (this.seeded) return;
    this.seeded = true;
    const merged: string[] = [];
    for (const entry of [...loaded, ...this.storage]) if (merged[merged.length - 1] !== entry) merged.push(entry);
    this.storage = merged.length > this.capacity ? merged.slice(merged.length - this.capacity) : merged;
  }

  append(command: string): void {
    const text = command.replace(/^\n+|\n+$/g, "");
    if (text.trim() === "" || this.storage[this.storage.length - 1] === text) return;
    this.storage.push(text);
    if (this.storage.length > this.capacity) this.storage.splice(0, this.storage.length - this.capacity);
  }

  search(query: string, limit = 200): string[] {
    const words = query.toLowerCase().split(/\s+/).filter((w) => w !== "");
    const seen = new Set<string>();
    const contained: string[] = [];
    const scattered: string[] = [];
    for (let i = this.storage.length - 1; i >= 0; i--) {
      const entry = this.storage[i]!;
      if (seen.has(entry)) continue;
      seen.add(entry);
      if (words.length === 0) {
        contained.push(entry);
      } else {
        const lowered = entry.toLowerCase();
        if (words.every((w) => lowered.includes(w))) contained.push(entry);
        else if (words.every((w) => isSubsequence(w, lowered))) scattered.push(entry);
      }
      if (contained.length >= limit) break;
    }
    return [...contained, ...scattered].slice(0, limit);
  }
}

export class HistoryNavigator {
  private position: number | null = null;
  private draft = "";
  private prefix = "";

  get isNavigating(): boolean {
    return this.position !== null;
  }

  reset(): void {
    this.position = null;
    this.draft = "";
    this.prefix = "";
  }

  back(entries: readonly string[], current: string): string | null {
    if (this.position === null) {
      this.draft = current;
      this.prefix = current;
    }
    for (let index = (this.position ?? entries.length) - 1; index >= 0; index--) {
      const candidate = entries[index]!;
      if (candidate.startsWith(this.prefix) && candidate !== current) {
        this.position = index;
        return candidate;
      }
    }
    return null;
  }

  forward(entries: readonly string[], current: string): string | null {
    if (this.position === null) return null;
    for (let index = this.position + 1; index < entries.length; index++) {
      const candidate = entries[index]!;
      if (candidate.startsWith(this.prefix) && candidate !== current) {
        this.position = index;
        return candidate;
      }
    }
    const restored = this.draft;
    this.reset();
    return restored;
  }
}
