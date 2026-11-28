import {
  attachmentsOf,
  composeAttachments,
  displayName,
  formatBytes,
  isImage,
  parseAttachments,
  summarize,
} from "./attachments";

const files = [
  { path: "C:\\Users\\x\\anexos\\wisp-ab12cd34-foto.png", name: "wisp-ab12cd34-foto.png", bytes: 5 },
  { path: "/srv/anexos/wisp-ab12cd34-nota (1).txt", name: "wisp-ab12cd34-nota (1).txt", bytes: 1500 },
];

describe("attachment block", () => {
  it("is composed byte for byte like the Mac and the bot write it, and parses back", () => {
    const text = composeAttachments(files, "olha isso");
    expect(text).toBe(
      "[o usuario enviou 2 arquivo(s) pelo Wisp, ja salvos nesta maquina:\n" +
        "- C:\\Users\\x\\anexos\\wisp-ab12cd34-foto.png (wisp-ab12cd34-foto.png, 5 bytes)\n" +
        "- /srv/anexos/wisp-ab12cd34-nota (1).txt (wisp-ab12cd34-nota (1).txt, 1500 bytes)]\n\nolha isso",
    );
    const found = parseAttachments(text)!;
    expect(found.origin).toBe("Wisp");
    expect(found.caption).toBe("olha isso");
    expect(found.items).toEqual([
      { kind: "file", path: files[0]!.path, name: files[0]!.name, bytes: 5 },
      { kind: "file", path: files[1]!.path, name: files[1]!.name, bytes: 1500 },
    ]);
    expect(summarize(found)).toBe("1 foto · 1 arquivo · olha isso");
  });

  it("uses the Mac's placeholder when there is no caption, and reads it back as none", () => {
    const text = composeAttachments(files.slice(0, 1), "  ");
    expect(text.endsWith("\n\n(sem texto — veja o que é e me diga)")).toBe(true);
    expect(parseAttachments(text)?.caption).toBeNull();
  });

  it("does not take ordinary text or a half-written block for attachments, and never shows a path then", () => {
    expect(parseAttachments("oi, tudo bem?")).toBeNull();
    expect(attachmentsOf("[o fulano disse oi")).toBeNull();
    const broken = "[o usuario enviou 2 arquivo(s) pelo Wisp, ja salvos nesta maquina:\n- /x/a.png (a.png, 5 bytes)]\n\nlegenda";
    expect(parseAttachments(broken)).toBeNull();
    expect(attachmentsOf(broken)).toEqual({ origin: "", items: [], caption: "legenda" });
  });

  it("reads a failed download as a chip with only the file name", () => {
    const text = "[o usuario enviou 1 arquivo(s) pelo Telegram, ja salvos nesta maquina:\n- /x/y/doc.pdf: nao consegui baixar]\n\nver";
    expect(parseAttachments(text)?.items).toEqual([{ kind: "failed", label: "doc.pdf: nao consegui baixar".split(":")[0] }]);
  });
});

describe("attachment helpers", () => {
  it("knows images, strips the staging prefix and formats sizes like the Mac", () => {
    expect(isImage("a.PNG")).toBe(true);
    expect(isImage("a.txt")).toBe(false);
    expect(isImage("png")).toBe(false);
    expect(displayName("wisp-ab12cd34-foto.png")).toBe("foto.png");
    expect(displayName("wisp-xyz-foto.png")).toBe("wisp-xyz-foto.png");
    expect([0, 1, 5, 1500, 12000, 2_500_000, 3_000_000_000].map(formatBytes)).toEqual([
      "0 bytes", "1 byte", "5 bytes", "1,5 KB", "12 KB", "2,5 MB", "3 GB",
    ]);
  });
});
