import { render } from "@testing-library/react";
import { useState, type ReactNode } from "react";
import { createFeatureBus, type FeatureBus } from "../../api/featureEvents";
import { ShellContext, type ShellValue } from "../../shell/context";

export const info = { port: 4242, token: "tok" };

function Shell({ value, children }: { value: ShellValue; children: ReactNode }) {
  const [draft, setDraft] = useState(value.draft);
  return (
    <ShellContext.Provider
      value={{
        ...value,
        draft,
        setDraft: (next) => {
          setDraft(next);
          value.setDraft(next);
        },
      }}
    >
      {children}
    </ShellContext.Provider>
  );
}

export function mountInShell(ui: ReactNode, value: Partial<ShellValue> = {}) {
  const bus: FeatureBus = value.bus ?? createFeatureBus();
  const shell: ShellValue = {
    info,
    bus,
    session: null as never,
    draft: "",
    setDraft: () => {},
    focusComposer: false,
    navigate: () => {},
    ...value,
  };
  return { bus, ...render(<Shell value={shell}>{ui}</Shell>) };
}

export type Seen = { method: string; path: string; query: string; body: unknown };

export function recordingFetch(handler: (call: Seen) => unknown) {
  const seen: Seen[] = [];
  const impl = (async (input: RequestInfo | URL, init?: RequestInit) => {
    const url = new URL(String(input));
    const call: Seen = {
      method: init?.method ?? "GET",
      path: url.pathname,
      query: url.search,
      body: init?.body ? JSON.parse(String(init.body)) : undefined,
    };
    seen.push(call);
    const out = handler(call);
    if (out instanceof Response) return out;
    if (out === undefined) return new Response("not found", { status: 404 });
    return new Response(JSON.stringify(out), { status: 200 });
  }) as typeof fetch;
  return { impl, seen };
}

export const failure = (status: number, error: string) => new Response(JSON.stringify({ error }), { status });
