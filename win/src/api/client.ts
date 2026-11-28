import type { Conversation, ConversationSummary, SidecarInfo } from "./types";

export class ApiError extends Error {
  constructor(
    readonly status: number,
    message: string,
  ) {
    super(message);
  }
}

export type WispClient = ReturnType<typeof createClient>;

export function baseUrl(info: SidecarInfo): string {
  return `http://127.0.0.1:${info.port}`;
}

export type Requester = <T>(method: string, path: string, body?: unknown) => Promise<T>;

export function createRequester(info: SidecarInfo, fetchImpl: typeof fetch = (...a) => fetch(...a)): Requester {
  const base = baseUrl(info);

  return async function call<T>(method: string, path: string, body?: unknown): Promise<T> {
    const headers: Record<string, string> = { Authorization: `Bearer ${info.token}` };
    if (body !== undefined) headers["Content-Type"] = "application/json";
    const res = await fetchImpl(`${base}${path}`, {
      method,
      headers,
      body: body === undefined ? undefined : JSON.stringify(body),
    });
    if (!res.ok) throw new ApiError(res.status, `${method} ${path} -> ${res.status}`);
    const text = await res.text();
    return (text ? JSON.parse(text) : undefined) as T;
  };
}

export function createClient(info: SidecarInfo, fetchImpl?: typeof fetch) {
  const call = createRequester(info, fetchImpl);
  const enc = encodeURIComponent;
  return {
    health: () => call<unknown>("GET", "/health"),
    listConversations: async () =>
      (await call<{ items: ConversationSummary[] }>("GET", "/conversations")).items,
    createConversation: async (title?: string) =>
      (await call<{ id: string }>("POST", "/conversations", title ? { title } : {})).id,
    getConversation: (id: string) => call<Conversation>("GET", `/conversations/${enc(id)}`),
    sendMessage: (id: string, text: string) =>
      call<void>("POST", `/conversations/${enc(id)}/messages`, { text, attachments: [] }),
    stop: (id: string) => call<void>("POST", `/conversations/${enc(id)}/stop`),
    answerPermission: (requestId: string, allow: boolean, message?: string) =>
      call<void>("POST", `/permissions/${enc(requestId)}`, message ? { allow, message } : { allow }),
  };
}
