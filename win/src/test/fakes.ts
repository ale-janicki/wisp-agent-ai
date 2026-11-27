import type { ServerEvent } from "../api/types";

export class FakeEventSource {
  static instances: FakeEventSource[] = [];
  onopen: (() => void) | null = null;
  onmessage: ((e: { data: string }) => void) | null = null;
  onerror: (() => void) | null = null;
  closed = false;

  constructor(readonly url: string) {
    FakeEventSource.instances.push(this);
  }

  close() {
    this.closed = true;
  }
  open() {
    this.onopen?.();
  }
  emit(event: ServerEvent) {
    this.onmessage?.({ data: JSON.stringify(event) });
  }
  fail() {
    this.onerror?.();
  }
  static last(): FakeEventSource {
    return FakeEventSource.instances[FakeEventSource.instances.length - 1]!;
  }
  static reset() {
    FakeEventSource.instances = [];
  }
}

export type Call = { method: string; path: string; body: unknown; auth: string | null };

export function fakeFetch(routes: Record<string, (body: unknown) => unknown>) {
  const calls: Call[] = [];
  const impl = (async (input: RequestInfo | URL, init?: RequestInit) => {
    const path = new URL(String(input)).pathname;
    const method = init?.method ?? "GET";
    const headers = new Headers(init?.headers);
    const body = init?.body ? JSON.parse(String(init.body)) : undefined;
    calls.push({ method, path, body, auth: headers.get("Authorization") });
    const route = routes[`${method} ${path}`];
    if (!route) return new Response("not found", { status: 404 });
    const out = route(body);
    return new Response(out === undefined ? "" : JSON.stringify(out), { status: out === undefined ? 202 : 200 });
  }) as typeof fetch;
  return { impl, calls };
}
