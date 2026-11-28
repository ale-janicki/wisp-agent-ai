import { baseUrl } from "../../api/client";
import type { SidecarInfo } from "../../api/types";

export class MeetingsError extends Error {
  constructor(
    readonly status: number,
    message: string,
  ) {
    super(message);
  }
}

export type Call = <T>(method: string, path: string, body?: unknown) => Promise<T>;

function refusalReason(text: string, fallback: string): string {
  try {
    const parsed = JSON.parse(text) as { error?: string };
    return parsed.error || fallback;
  } catch {
    return fallback;
  }
}

export function createCall(info: SidecarInfo, fetchImpl: typeof fetch = (...a) => fetch(...a)): Call {
  return async function call<T>(method: string, path: string, body?: unknown): Promise<T> {
    const headers: Record<string, string> = { Authorization: `Bearer ${info.token}` };
    if (body !== undefined) headers["Content-Type"] = "application/json";
    const res = await fetchImpl(`${baseUrl(info)}/api/meetings${path}`, {
      method,
      headers,
      body: body === undefined ? undefined : JSON.stringify(body),
    });
    const text = await res.text();
    if (!res.ok) {
      throw new MeetingsError(res.status, refusalReason(text, `${method} ${path} -> ${res.status}`));
    }
    return (text ? JSON.parse(text) : undefined) as T;
  };
}

export async function fetchAudioUrl(info: SidecarInfo, id: string, fetchImpl: typeof fetch = (...a) => fetch(...a)): Promise<string> {
  const res = await fetchImpl(`${baseUrl(info)}/api/meetings/meetings/${encodeURIComponent(id)}/audio`, {
    headers: { Authorization: `Bearer ${info.token}` },
  });
  if (!res.ok) throw new MeetingsError(res.status, "não consegui carregar o áudio");
  return URL.createObjectURL(await res.blob());
}
