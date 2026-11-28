import { createContext, useContext, useEffect, useMemo, useRef } from "react";
import { createFeatureApi, type FeatureApi } from "../api/feature";
import type { FeatureBus } from "../api/featureEvents";
import type { FeatureEvent, SidecarInfo } from "../api/types";
import type { useChat } from "../state/useChat";

export type ChatSession = ReturnType<typeof useChat>;
export type ShellValue = {
  info: SidecarInfo;
  bus: FeatureBus;
  fetchImpl?: typeof fetch;
  session: ChatSession;
  draft: string;
  setDraft: (value: string) => void;
  focusComposer: boolean;
  navigate: (id: string) => void;
};

export const ShellContext = createContext<ShellValue | null>(null);

export function useShell(): ShellValue {
  const value = useContext(ShellContext);
  if (!value) throw new Error("useShell outside the panel");
  return value;
}
export function useFeatureApi(feature: string): FeatureApi {
  const { info, fetchImpl } = useShell();
  return useMemo(() => createFeatureApi(info, feature, fetchImpl), [info, feature, fetchImpl]);
}
export function useFeatureEvents(feature: string, handler: (event: FeatureEvent) => void): void {
  const { bus } = useShell();
  const latest = useRef(handler);
  latest.current = handler;
  useEffect(() => bus.subscribe(feature, (event) => latest.current(event)), [bus, feature]);
}
