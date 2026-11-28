import { fakeFetch, FakeEventSource } from "../test/fakes";
import { ApiError } from "./client";
import { connectEvents } from "./events";
import { createFeatureApi } from "./feature";
import { createFeatureBus } from "./featureEvents";
import type { FeatureEvent, ServerEvent } from "./types";

const info = { port: 4242, token: "tok" };

describe("createFeatureApi", () => {
  it("calls /api/<feature>/… with the token, the query and the JSON body", async () => {
    const { impl, calls } = fakeFetch({
      "GET /api/tasks/items": () => ({ items: [] }),
      "POST /api/tasks/items": (b) => ({ got: b }),
      "DELETE /api/tasks/items/a%20b": () => undefined,
    });
    const api = createFeatureApi(info, "tasks", impl);
    expect(await api.get("items", { q: "x y", skip: undefined, n: 2 })).toEqual({ items: [] });
    expect(await api.post("/items", { title: "t" })).toEqual({ got: { title: "t" } });
    await api.delete("/items/a%20b");
    expect(calls.map((c) => [c.method, c.path, c.auth])).toEqual([
      ["GET", "/api/tasks/items", "Bearer tok"],
      ["POST", "/api/tasks/items", "Bearer tok"],
      ["DELETE", "/api/tasks/items/a%20b", "Bearer tok"],
    ]);
  });

  it("throws ApiError with the status on a non-2xx", async () => {
    const { impl } = fakeFetch({});
    await expect(createFeatureApi(info, "x", impl).get("/nope")).rejects.toMatchObject({ status: 404 });
    await expect(createFeatureApi(info, "x", impl).get("/nope")).rejects.toBeInstanceOf(ApiError);
  });
});

describe("feature events", () => {
  beforeEach(() => FakeEventSource.reset());

  it("a frame with a feature key goes only to onFeatureEvent, a chat frame only to onEvent", () => {
    const chat: ServerEvent[] = [];
    const feature: FeatureEvent[] = [];
    connectEvents({
      info,
      onEvent: (e) => chat.push(e),
      onFeatureEvent: (e) => feature.push(e),
      createSource: (u) => new FakeEventSource(u) as unknown as EventSource,
    });
    const es = FakeEventSource.last();
    es.emit({ conversation_id: "c", type: "status", state: "idle" });
    es.onmessage?.({ data: JSON.stringify({ feature: "tasks", type: "changed", n: 1 }) });
    expect(chat).toEqual([{ conversation_id: "c", type: "status", state: "idle" }]);
    expect(feature).toEqual([{ feature: "tasks", type: "changed", n: 1 }]);
  });

  it("without onFeatureEvent a feature frame is dropped, never handed to the chat", () => {
    const chat: ServerEvent[] = [];
    connectEvents({ info, onEvent: (e) => chat.push(e), createSource: (u) => new FakeEventSource(u) as unknown as EventSource });
    FakeEventSource.last().onmessage?.({ data: JSON.stringify({ feature: "tasks", type: "status" }) });
    expect(chat).toEqual([]);
  });

  it("the bus delivers by feature and unsubscribes", () => {
    const bus = createFeatureBus();
    const a = vi.fn();
    const b = vi.fn();
    const offA = bus.subscribe("a", a);
    bus.subscribe("b", b);
    bus.emit({ feature: "a", type: "t" });
    offA();
    bus.emit({ feature: "a", type: "t" });
    expect(a).toHaveBeenCalledTimes(1);
    expect(b).not.toHaveBeenCalled();
  });
});
