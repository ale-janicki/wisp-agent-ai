import { useMemo } from "react";
import { baseUrl } from "../../api/client";
import { useShell } from "../../shell/context";

export class FeatureError extends Error {
  constructor(
    message: string,
    readonly status: number,
  ) {
    super(message);
  }
}

type Query = Record<string, string | number | boolean | undefined>;

export function useRichApi(feature: string) {
  const { info, fetchImpl } = useShell();
  return useMemo(() => {
    const send = async <T>(method: string, path: string, query?: Query, body?: unknown): Promise<T> => {
      const params = new URLSearchParams();
      for (const [key, value] of Object.entries(query ?? {})) if (value !== undefined) params.set(key, String(value));
      const qs = params.toString();
      const headers: Record<string, string> = { Authorization: `Bearer ${info.token}` };
      if (body !== undefined) headers["Content-Type"] = "application/json";
      const run = fetchImpl ?? ((...a: Parameters<typeof fetch>) => fetch(...a));
      const res = await run(`${baseUrl(info)}/api/${encodeURIComponent(feature)}${path}${qs ? `?${qs}` : ""}`, {
        method,
        headers,
        body: body === undefined ? undefined : JSON.stringify(body),
      });
      const text = await res.text();
      let parsed: unknown;
      try {
        parsed = text ? JSON.parse(text) : undefined;
      } catch {
        parsed = undefined;
      }
      if (!res.ok) {
        const error = (parsed as { error?: unknown } | undefined)?.error;
        throw new FeatureError(typeof error === "string" ? error : String(res.status), res.status);
      }
      return parsed as T;
    };
    return {
      get: <T,>(path: string, query?: Query) => send<T>("GET", path, query),
      post: <T,>(path: string, body?: unknown) => send<T>("POST", path, undefined, body ?? {}),
      put: <T,>(path: string, body?: unknown) => send<T>("PUT", path, undefined, body ?? {}),
      delete: <T,>(path: string) => send<T>("DELETE", path),
    };
  }, [info, feature, fetchImpl]);
}
