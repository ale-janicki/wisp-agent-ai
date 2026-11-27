import { baseUrl } from "./client";
import type { ServerEvent, SidecarInfo } from "./types";

export type EventStreamOptions = {
  info: SidecarInfo;
  onEvent: (event: ServerEvent) => void;
  onOpen?: () => void;
  onDown?: () => void;
  createSource?: (url: string) => EventSource;
  minDelayMs?: number;
  maxDelayMs?: number;
};

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
      try {
        options.onEvent(JSON.parse(message.data) as ServerEvent);
      } catch {
        return;
      }
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
