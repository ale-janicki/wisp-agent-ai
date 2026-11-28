import { fakeFetch } from "../test/fakes";
import { ApiError, createClient } from "./client";

const info = { port: 4242, token: "tok" };

describe("client", () => {
  it("sends the bearer token and unwraps list items", async () => {
    const { impl, calls } = fakeFetch({
      "GET /conversations": () => ({ items: [{ id: "a", title: "T", updated_at: "x", engine: "claude" }] }),
    });
    const items = await createClient(info, impl).listConversations();
    expect(items.map((i) => i.id)).toEqual(["a"]);
    expect(calls[0]?.auth).toBe("Bearer tok");
  });

  it("posts messages with an empty attachment list and answers permissions", async () => {
    const { impl, calls } = fakeFetch({
      "POST /conversations/c1/messages": () => undefined,
      "POST /permissions/r1": () => undefined,
    });
    const client = createClient(info, impl);
    await client.sendMessage("c1", "oi");
    await client.answerPermission("r1", false, "não");
    expect(calls[0]?.body).toEqual({ text: "oi", attachments: [] });
    expect(calls[1]?.body).toEqual({ allow: false, message: "não" });
  });

  it("throws ApiError on a non-2xx answer", async () => {
    const { impl } = fakeFetch({});
    await expect(createClient(info, impl).health()).rejects.toBeInstanceOf(ApiError);
  });
});

describe("client: chat parity routes", () => {
  it("sends attachment paths and always-allow, renames, deletes and reopens", async () => {
    const { impl, calls } = fakeFetch({
      "POST /conversations/c1/messages": () => undefined,
      "POST /permissions/r1": () => undefined,
      "PATCH /conversations/c1": () => ({ id: "c1", title: "N" }),
      "DELETE /conversations/c1": () => ({ ok: true }),
      "POST /conversations/c1/reopen": () => ({ ok: true }),
      "POST /attachments": () => ({ files: [], refused: [], notice: null }),
      "DELETE /attachments": () => ({ ok: true }),
      "PUT /engines/active": () => ({ active: "codex" }),
      "GET /engines": () => ({ active: "codex", engines: [] }),
      "GET /usage": () => ({ five_hour: null, seven_day: null }),
    });
    const client = createClient(info, impl);
    await client.sendMessage("c1", "oi", ["/a/b.png"]);
    await client.answerPermission("r1", true, undefined, true);
    await client.renameConversation("c1", "N");
    await client.deleteConversation("c1");
    await client.reopenConversation("c1");
    await client.stageAttachments(["/x"]);
    await client.discardAttachment("C:\\a b\\c.png");
    await client.setEngine("codex");
    await client.engines();
    await client.usage();
    expect(calls.map((c) => `${c.method} ${c.path}`)).toEqual([
      "POST /conversations/c1/messages", "POST /permissions/r1", "PATCH /conversations/c1", "DELETE /conversations/c1",
      "POST /conversations/c1/reopen", "POST /attachments", "DELETE /attachments", "PUT /engines/active", "GET /engines", "GET /usage",
    ]);
    expect(calls[0]?.body).toEqual({ text: "oi", attachments: ["/a/b.png"] });
    expect(calls[1]?.body).toEqual({ allow: true, always: true });
  });

  it("uploads raw bytes with the token and fetches an image as a blob", async () => {
    const seen: { url: string; method?: string; auth: string | null; body: unknown }[] = [];
    const impl = (async (input: RequestInfo | URL, init?: RequestInit) => {
      seen.push({ url: String(input), method: init?.method, auth: new Headers(init?.headers).get("Authorization"), body: init?.body });
      return String(input).includes("/attachments/file")
        ? new Response("PNG", { status: 200 })
        : new Response(JSON.stringify({ files: [{ path: "p", name: "n", bytes: 1, image: true }], refused: [], notice: null }), { status: 200 });
    }) as typeof fetch;
    const client = createClient(info, impl);
    const blob = new Blob(["x"]);
    const staged = await client.uploadAttachment(blob, "a b.png");
    expect(staged.files[0]?.name).toBe("n");
    expect(seen[0]).toMatchObject({ url: "http://127.0.0.1:4242/attachments?name=a%20b.png", method: "PUT", auth: "Bearer tok" });
    expect(seen[0]?.body).toBe(blob);
    expect(await (await client.attachmentImage("C:\\a\\b.png")).text()).toBe("PNG");
    expect(seen[1]?.url).toBe("http://127.0.0.1:4242/attachments/file?path=C%3A%5Ca%5Cb.png");
    const failing = createClient(info, (async () => new Response("no", { status: 404 })) as typeof fetch);
    await expect(failing.attachmentImage("x")).rejects.toBeInstanceOf(ApiError);
    await expect(failing.uploadAttachment(blob, "a")).rejects.toBeInstanceOf(ApiError);
  });
});
