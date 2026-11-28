import { describe, expect, it } from "vitest";
import { CompletionSource } from "./completionSource";

const backendOf = (dirs: Record<string, { name: string; isDir: boolean }[]>, programs: string[]) => {
  const calls = { list: [] as string[], executables: 0 };
  return {
    calls,
    listDirectory: async (path: string) => {
      calls.list.push(path);
      return dirs[path] ?? [];
    },
    executables: async () => {
      calls.executables += 1;
      return programs;
    },
  };
};

describe("CompletionSource", () => {
  it("answers empty the first time, fetches in the background and says when the answer is in", async () => {
    const backend = backendOf({ "C:\\w": [{ name: "a.txt", isDir: false }] }, ["git"]);
    let loaded = 0;
    const source = new CompletionSource(backend, () => (loaded += 1));
    const context = source.context("C:\\w", "C:\\Users\\dev");
    expect(context.list("C:\\w")).toEqual([]);
    expect(context.executables()).toEqual([]);
    await new Promise((r) => setTimeout(r, 0));
    expect(loaded).toBe(2);
    expect(context.list("C:\\w")).toEqual([{ name: "a.txt", isDir: false }]);
    expect(context.executables()).toEqual(["git"]);
  });

  it("asks once for a folder while it is fresh, and once for the programs", async () => {
    const backend = backendOf({}, []);
    const source = new CompletionSource(backend, () => {});
    const context = source.context("C:\\w", "C:\\h");
    for (let i = 0; i < 3; i++) {
      context.list("C:\\w");
      context.executables();
    }
    await new Promise((r) => setTimeout(r, 0));
    context.list("C:\\w");
    expect(backend.calls.list).toEqual(["C:\\w"]);
    expect(backend.calls.executables).toBe(1);
  });

  it("treats the folder's name without regard to case", async () => {
    const backend = backendOf({ "C:\\W": [{ name: "x", isDir: true }] }, []);
    const source = new CompletionSource(backend, () => {});
    const context = source.context("c:\\w", "C:\\h");
    context.list("C:\\W");
    await new Promise((r) => setTimeout(r, 0));
    expect(context.list("c:\\w")).toEqual([{ name: "x", isDir: true }]);
  });
});
