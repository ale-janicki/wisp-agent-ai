import type {
  Conversation,
  ConversationSummary,
  EngineId,
  EngineOverview,
  SidecarInfo,
  StageResult,
  UsageWindows,
} from "./types";

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

export function createClient(info: SidecarInfo, fetchImpl: typeof fetch = (...a) => fetch(...a)) {
  const call = createRequester(info, fetchImpl);
  const enc = encodeURIComponent;
  const auth = { Authorization: `Bearer ${info.token}` };

  async function upload(file: Blob, name: string): Promise<StageResult> {
    const res = await fetchImpl(`${baseUrl(info)}/attachments?name=${enc(name)}`, {
      method: "PUT",
      headers: { ...auth, "Content-Type": "application/octet-stream" },
      body: file,
    });
    if (!res.ok) throw new ApiError(res.status, `PUT /attachments -> ${res.status}`);
    return (await res.json()) as StageResult;
  }

  async function attachmentImage(path: string): Promise<Blob> {
    const res = await fetchImpl(`${baseUrl(info)}/attachments/file?path=${enc(path)}`, { headers: auth });
    if (!res.ok) throw new ApiError(res.status, `GET /attachments/file -> ${res.status}`);
    return res.blob();
  }

  return {
    health: () => call<unknown>("GET", "/health"),
    listConversations: async () =>
      (await call<{ items: ConversationSummary[] }>("GET", "/conversations")).items,
    createConversation: async (title?: string) =>
      (await call<{ id: string }>("POST", "/conversations", title ? { title } : {})).id,
    getConversation: (id: string) => call<Conversation>("GET", `/conversations/${enc(id)}`),
    sendMessage: (id: string, text: string, attachments: string[] = []) =>
      call<void>("POST", `/conversations/${enc(id)}/messages`, { text, attachments }),
    stop: (id: string) => call<void>("POST", `/conversations/${enc(id)}/stop`),
    answerPermission: (requestId: string, allow: boolean, message?: string, always?: boolean) =>
      call<void>("POST", `/permissions/${enc(requestId)}`, {
        allow,
        ...(message ? { message } : {}),
        ...(always ? { always: true } : {}),
      }),
    renameConversation: (id: string, title: string) =>
      call<{ id: string; title: string }>("PATCH", `/conversations/${enc(id)}`, { title }),
    deleteConversation: (id: string) => call<void>("DELETE", `/conversations/${enc(id)}`),
    reopenConversation: (id: string) => call<void>("POST", `/conversations/${enc(id)}/reopen`),
    stageAttachments: (paths: string[]) => call<StageResult>("POST", "/attachments", { paths }),
    uploadAttachment: upload,
    discardAttachment: (path: string) => call<void>("DELETE", `/attachments?path=${enc(path)}`),
    attachmentImage,
    engines: () => call<EngineOverview>("GET", "/engines"),
    setEngine: (engine: EngineId) => call<{ active: EngineId }>("PUT", "/engines/active", { engine }),
    usage: () => call<UsageWindows>("GET", "/usage"),
  };
}
