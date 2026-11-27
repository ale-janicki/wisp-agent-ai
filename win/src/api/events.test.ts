import { FakeEventSource } from "../test/fakes";
import { connectEvents } from "./events";
import type { ServerEvent } from "./types";

const info = { port: 4242, token: "a b" };

beforeEach(() => {
  vi.useFakeTimers();
  FakeEventSource.reset();
});
afterEach(() => vi.useRealTimers());

const create = (url: string) => new FakeEventSource(url) as unknown as EventSource;

describe("connectEvents", () => {
  it("puts the token in the query and parses frames", () => {
    const seen: ServerEvent[] = [];
    connectEvents({ info, onEvent: (e) => seen.push(e), createSource: create });
    const es = FakeEventSource.last();
    expect(es.url).toBe("http://127.0.0.1:4242/events?token=a%20b");
    es.emit({ conversation_id: "c", type: "text_delta", text: "oi" });
    es.onmessage?.({ data: "not json" });
    expect(seen).toEqual([{ conversation_id: "c", type: "text_delta", text: "oi" }]);
  });

  it("reopens with backoff after an error and reports open", () => {
    const onOpen = vi.fn();
    connectEvents({ info, onEvent: () => {}, onOpen, createSource: create, minDelayMs: 100, maxDelayMs: 400 });
    FakeEventSource.last().fail();
    expect(FakeEventSource.instances).toHaveLength(1);
    vi.advanceTimersByTime(100);
    expect(FakeEventSource.instances).toHaveLength(2);
    FakeEventSource.last().fail();
    vi.advanceTimersByTime(100);
    expect(FakeEventSource.instances).toHaveLength(2);
    vi.advanceTimersByTime(100);
    expect(FakeEventSource.instances).toHaveLength(3);
    FakeEventSource.last().open();
    expect(onOpen).toHaveBeenCalledTimes(1);
  });

  it("stops reconnecting once closed", () => {
    const close = connectEvents({ info, onEvent: () => {}, createSource: create, minDelayMs: 100 });
    FakeEventSource.last().fail();
    close();
    vi.advanceTimersByTime(5000);
    expect(FakeEventSource.instances).toHaveLength(1);
  });
});
