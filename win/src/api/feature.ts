import { createRequester } from "./client";
import type { SidecarInfo } from "./types";

export type Query = Record<string, string | number | boolean | undefined>;

export type FeatureApi = ReturnType<typeof createFeatureApi>;

export function createFeatureApi(info: SidecarInfo, feature: string, fetchImpl?: typeof fetch) {
  const call = createRequester(info, fetchImpl);
  const root = `/api/${encodeURIComponent(feature)}`;

  const url = (path: string, query?: Query) => {
    const params = new URLSearchParams();
    for (const [key, value] of Object.entries(query ?? {})) if (value !== undefined) params.set(key, String(value));
    const qs = params.toString();
    return `${root}${path.startsWith("/") ? path : `/${path}`}${qs ? `?${qs}` : ""}`;
  };

  return {
    get: <T>(path: string, query?: Query) => call<T>("GET", url(path, query)),
    post: <T>(path: string, body?: unknown) => call<T>("POST", url(path), body ?? {}),
    put: <T>(path: string, body?: unknown) => call<T>("PUT", url(path), body ?? {}),
    patch: <T>(path: string, body?: unknown) => call<T>("PATCH", url(path), body ?? {}),
    delete: <T>(path: string) => call<T>("DELETE", url(path)),
  };
}
