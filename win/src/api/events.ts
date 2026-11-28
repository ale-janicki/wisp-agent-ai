import { baseUrl } from "./client";
import type { FeatureEvent, ServerEvent, SidecarInfo } from "./types";

export type EventStreamOptions = {
  info: SidecarInfo;
  onEvent: (event: ServerEvent) => void;
  onFeatureEvent?: (event: FeatureEvent) => void;
  onOpen?: () => void;
  onDown?: () => void;
  createSource?: (url: string) => EventSource;
  minDelayMs?: number;
  maxDelayMs?: number;
};

const isFeatureEvent = (value: unknown): value is FeatureEvent =>
  typeof value === "object" && value !== null && typeof (value as FeatureEvent).feature === "string";

export function connectEvents(options: EventStreamOptions): () => void {
  const create = options.createSource ?? ((url: string) => new EventSource(url));
  const min = options.minDelayMs ?? 500;
  const max = options.maxDelayMs ?? 8000;
  const url = `${baseUrl(options.info)}/events?token=${encodeURIComponent(options.info.token)}`;

  let source: EventSource | null = null;
  let timer: ReturnType<typeof setTimeout> | null = null;
  let delay = min;
  let closed = false;

  const open = () => {
    if (closed) return;
    const es = create(url);
    source = es;
    es.onopen = () => {
      delay = min;
      options.onOpen?.();
    };
    es.onmessage = (message) => {
      let parsed: unknown;
      try {
        parsed = JSON.parse(message.data);
      } catch {
        return;
      }
      if (isFeatureEvent(parsed)) options.onFeatureEvent?.(parsed);
      else options.onEvent(parsed as ServerEvent);
    };
    es.onerror = () => {
      es.close();
      if (source === es) source = null;
      options.onDown?.();
      if (closed) return;
      timer = setTimeout(open, delay);
      delay = Math.min(delay * 2, max);
    };
  };

  open();
  return () => {
    closed = true;
    if (timer) clearTimeout(timer);
    source?.close();
    source = null;
  };
}
