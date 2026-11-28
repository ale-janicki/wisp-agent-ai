import { describe, expect, it } from "vitest";
import { commonPrefix, complete, type CompletionContext } from "./completion";

const tree: Record<string, { name: string; isDir: boolean }[]> = {
  "C:\\work": [
    { name: "src", isDir: true },
    { name: "Notes dir", isDir: true },
    { name: "readme.md", isDir: false },
    { name: ".env", isDir: false },
  ],
  "C:\\work\\src": [{ name: "main.ts", isDir: false }],
  "C:\\Users\\dev": [{ name: "docs", isDir: true }],
};
const context: CompletionContext = {
  cwd: "C:\\work",
  home: "C:\\Users\\dev",
  list: (dir) => tree[dir] ?? [],
  executables: () => ["git", "node", "npm", "python"],
};
const texts = (line: string, cursor = line.length) => complete(line, cursor, context).map((c) => c.display);

describe("complete commands", () => {
  it("matches the first word against PATH programs and built-ins, ignoring case", () => {
    expect(texts("no")).toEqual(["node"]);
    expect(texts("PY")).toEqual(["python"]);
    expect(texts("Get-Chi")).toEqual(["Get-ChildItem"]);
    expect(texts("cd")).toEqual(["cd"]);
  });

  it("offers nothing for an empty first word", () => {
    expect(texts("")).toEqual([]);
  });

  it("a word after a pipe is a command again", () => {
    expect(texts("dir | no")).toEqual(["node"]);
  });
});

describe("complete paths", () => {
  it("lists the working folder, folders first, hiding dotfiles", () => {
    expect(texts("type ")).toEqual(["Notes dir\\", "src\\", "readme.md"]);
  });

  it("shows dotfiles when the prefix starts with a dot", () => {
    expect(texts("type .")).toEqual(["..\\", ".env"]);
  });

  it("goes into a folder typed with either slash and keeps what was typed", () => {
    expect(texts("type src\\")).toEqual(["main.ts"]);
    expect(complete("type src/", 9, context)[0]!.insertText).toBe("src/main.ts ");
  });

  it("expands ~ to the home folder", () => {
    expect(texts("cd ~/")).toEqual(["docs\\"]);
    expect(complete("cd ~", 4, context)[0]!.insertText).toBe("~\\");
  });

  it("cd only takes folders", () => {
    expect(texts("cd ")).toEqual(["Notes dir\\", "src\\"]);
  });

  it("quotes a name with spaces for PowerShell and leaves a folder's quote open to go on", () => {
    const [first] = complete("cd No", 5, context);
    expect(first!.insertText).toBe("'Notes dir\\");
    expect(first!.replaceRange).toEqual([3, 5]);
  });

  it("completes inside an open quote and closes it for a file", () => {
    const [folder] = complete('cd "No', 6, context);
    expect(folder!.insertText).toBe('"Notes dir\\');
    const [file] = complete("type 'read", 10, context);
    expect(file!.insertText).toBe("'readme.md' ");
  });

  it("completes the word the cursor is in the middle of", () => {
    const [found] = complete("cd sr foo", 5, context);
    expect(found!.replaceRange).toEqual([3, 5]);
  });
});

describe("commonPrefix", () => {
  it("is the longest shared start of what would be inserted, without the closing space", () => {
    const many: CompletionContext = { ...context, executables: () => ["node", "nodemon", "npm"] };
    expect(commonPrefix(complete("no", 2, many))).toBe("node");
    expect(commonPrefix(complete("py", 2, context))).toBe("python ");
    expect(commonPrefix([])).toBe("");
  });
});
