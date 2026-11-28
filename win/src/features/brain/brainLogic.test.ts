import { describe, expect, it } from "vitest";
import { applyCompletion, completionAt, matchTags } from "./completion";
import { initLayout, settle } from "./layout";
import { headingSection, parseHref, prepare } from "./markdown";
import { rank } from "./rank";
import { ancestorsOf, kindOf, treeRows, uniquePath } from "./treeRows";
import type { NoteSummary, TreeEntry } from "./types";

const note = (path: string, title: string, aliases: string[] = [], modified = 0): NoteSummary => ({ path, title, aliases, modified, link: title });

describe("prepare (Obsidian text to Markdown)", () => {
  it("turns wikilinks, aliases, embeds and tags into links with wisp schemes", () => {
    const out = prepare("Veja [[Ana]] e [[plano#Metas|o plano]] ![[foto.png|300]] ![[Outra nota#Parte]] ![[d.excalidraw.md]] #projeto/x");
    expect(out).toContain("[Ana](wisp-note:Ana)");
    expect(out).toContain("[o plano](wisp-note:plano%23Metas)");
    expect(out).toContain("![foto.png](wisp-file:foto.png#w=300)");
    expect(out).toContain("[Outra nota#Parte](wisp-embed:Outra%20nota%23Parte)");
    expect(out).toContain("[d.excalidraw.md](wisp-draw:d.excalidraw.md)");
    expect(out).toContain("[#projeto/x](wisp-tag:projeto%2Fx)");
  });

  it("keeps the line count, hides frontmatter and %%comments%%, leaves code alone", () => {
    const text = "---\ntitulo: x\n---\n# T\n%%oculto\nmais%% fica\n```\n[[nao]] #nao\n```\n`[[nem]]` e [[sim]]\n";
    const out = prepare(text);
    expect(out.split("\n")).toHaveLength(text.split("\n").length);
    expect(out).not.toContain("titulo");
    expect(out).not.toContain("oculto");
    expect(out).toContain("[[nao]] #nao");
    expect(out).toContain("`[[nem]]` e [sim](wisp-note:sim)");
    expect(out).toContain("# T");
  });

  it("makes single newlines inside a paragraph hard breaks and never tags a heading", () => {
    expect(prepare("linha um\nlinha dois\n\n# Titulo")).toBe("linha um  \nlinha dois\n\n# Titulo");
  });

  it("round-trips hrefs", () => {
    expect(parseHref("wisp-note:plano%23Metas")).toEqual({ kind: "note", value: "plano#Metas" });
    expect(parseHref("wisp-file:foto.png#w=300")).toEqual({ kind: "file", value: "foto.png", width: 300 });
    expect(parseHref("https://example.org")).toEqual({ kind: "web", value: "https://example.org" });
    expect(parseHref("javascript:alert(1)")).toBeNull();
  });

  it("extracts a heading section up to the next heading of the same level", () => {
    const text = "# A\n## Metas\n- x\n### Sub\ny\n## Outra\nz";
    expect(headingSection(text, "metas")).toBe("## Metas\n- x\n### Sub\ny");
    expect(headingSection(text, "nada")).toBe("");
  });
});

describe("switcher ranking", () => {
  const notes = [note("a/Plano de voo.md", "Plano de voo", ["Roteiro"], 5), note("Inicio.md", "Início", [], 9), note("x/leia.md", "Leia", [], 1)];
  it("lists the most recent first for an empty query", () => {
    expect(rank("", notes).map((r) => r.path)).toEqual(["Inicio.md", "a/Plano de voo.md", "x/leia.md"]);
  });
  it("folds accents, prefers title boundaries, reports the alias that matched", () => {
    expect(rank("inicio", notes)[0]?.path).toBe("Inicio.md");
    expect(rank("pdv", notes)[0]?.path).toBe("a/Plano de voo.md");
    expect(rank("rotei", notes)[0]).toMatchObject({ path: "a/Plano de voo.md", alias: "Roteiro" });
    expect(rank("zzz", notes)).toEqual([]);
  });
});

describe("tree rows", () => {
  const entries: TreeEntry[] = [
    { path: "b.md", is_folder: false, modified: 0, size: 1 },
    { path: "Pasta", is_folder: true, modified: 0, size: 0 },
    { path: "Pasta/z.md", is_folder: false, modified: 0, size: 1 },
    { path: "Pasta/10.md", is_folder: false, modified: 0, size: 1 },
    { path: "Pasta/2.md", is_folder: false, modified: 0, size: 1 },
    { path: "a.md", is_folder: false, modified: 0, size: 1 },
  ];
  it("puts folders first, sorts numerically, shows only expanded children", () => {
    expect(treeRows(entries, new Set()).map((r) => r.name)).toEqual(["Pasta", "a", "b"]);
    const open = treeRows(entries, new Set(["Pasta"]));
    expect(open.map((r) => [r.name, r.depth])).toEqual([["Pasta", 0], ["2", 1], ["10", 1], ["z", 1], ["a", 0], ["b", 0]]);
    expect(open[0]).toMatchObject({ isFolder: true, expanded: true, childCount: 3 });
  });
  it("finds ancestors, unique names and kinds", () => {
    expect(ancestorsOf("a/b/c.md")).toEqual(["a/b", "a"]);
    expect(uniquePath("Nova.md", ["nova.md", "Nova 2.md"])).toBe("Nova 3.md");
    expect(kindOf("d.excalidraw.md")).toBe("drawing");
    expect(kindOf("c.canvas")).toBe("drawing");
    expect(kindOf("n.md")).toBe("note");
    expect(kindOf("f.PNG")).toBe("image");
  });
});

describe("graph layout", () => {
  it("is deterministic, finite, and pulls linked nodes closer than unlinked ones", () => {
    const run = () => {
      const nodes = initLayout(["a", "b", "c", "d"], { a: 1, b: 1 });
      settle(nodes, [[0, 1]], 300);
      return nodes;
    };
    const one = run();
    expect(one.every((n) => Number.isFinite(n.x) && Number.isFinite(n.y))).toBe(true);
    expect(run().map((n) => [n.x, n.y])).toEqual(one.map((n) => [n.x, n.y]));
    const d = (a: number, b: number) => Math.hypot(one[a]!.x - one[b]!.x, one[a]!.y - one[b]!.y);
    expect(d(0, 1)).toBeGreaterThan(30);
    expect(d(0, 1)).toBeLessThan(60);
    expect(d(0, 1)).toBeLessThan(d(2, 3));
  });
});

describe("completion", () => {
  it("detects an open [[ link or a #tag at the cursor and nothing inside a closed link", () => {
    expect(completionAt("veja [[Pl", 9)).toEqual({ kind: "link", query: "Pl", start: 7, end: 9 });
    expect(completionAt("veja [[Plano]] e", 16)).toBeNull();
    expect(completionAt("veja [[Plano|al", 15)).toBeNull();
    expect(completionAt("texto #proj", 11)).toEqual({ kind: "tag", query: "proj", start: 7, end: 11 });
    expect(completionAt("a#b", 3)).toBeNull();
  });
  it("closes the link and puts the cursor after it, and ranks tags by use", () => {
    const context = completionAt("veja [[Pl", 9)!;
    expect(applyCompletion("veja [[Pl", context, "Plano")).toEqual({ text: "veja [[Plano]]", cursor: 14 });
    expect(matchTags("p", { projeto: 3, pessoa: 5, zeta: 9 })).toEqual(["pessoa", "projeto"]);
  });
});
