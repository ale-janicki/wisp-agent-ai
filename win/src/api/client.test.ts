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
