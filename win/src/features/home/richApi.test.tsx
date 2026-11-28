import { renderHook } from "@testing-library/react";
import type { ReactNode } from "react";
import { createFeatureBus } from "../../api/featureEvents";
import { ShellContext } from "../../shell/context";
import { FeatureError, useRichApi } from "./richApi";
import { failure, info, recordingFetch } from "./testShell";

function setup(handler: Parameters<typeof recordingFetch>[0]) {
  const { impl, seen } = recordingFetch(handler);
  const wrapper = ({ children }: { children: ReactNode }) => (
    <ShellContext.Provider value={{ info, bus: createFeatureBus(), fetchImpl: impl, session: null as never, draft: "", setDraft: () => {}, focusComposer: false, navigate: () => {} }}>
      {children}
    </ShellContext.Provider>
  );
  return { ...renderHook(() => useRichApi("music"), { wrapper }), seen };
}

describe("rich feature api", () => {
  it("calls /api/<feature> with the token and drops undefined query values", async () => {
    const { result, seen } = setup(() => ({ ok: true }));
    await result.current.get("/search", { q: "bossa nova", skip: undefined, n: 2 });
    await result.current.post("/play", { uris: ["a"] });
    await result.current.delete("/x");
    expect(seen.map((c) => [c.method, c.path + c.query, c.body])).toEqual([
      ["GET", "/api/music/search?q=bossa+nova&n=2", undefined],
      ["POST", "/api/music/play", { uris: ["a"] }],
      ["DELETE", "/api/music/x", undefined],
    ]);
  });

  it("raises the sidecar's own sentence on a failure", async () => {
    const { result } = setup(() => failure(403, "Para tocar pelo Wisp a conta precisa de Spotify Premium."));
    await expect(result.current.post("/play", {})).rejects.toMatchObject({ message: "Para tocar pelo Wisp a conta precisa de Spotify Premium.", status: 403 });
    await expect(result.current.post("/play", {})).rejects.toBeInstanceOf(FeatureError);
  });

  it("falls back to the status when the body is not the sidecar's JSON", async () => {
    const { result } = setup(() => new Response("boom", { status: 502 }));
    await expect(result.current.get("/x")).rejects.toMatchObject({ message: "502", status: 502 });
  });
});
