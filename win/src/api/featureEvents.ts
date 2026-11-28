import type { FeatureEvent } from "./types";

export type FeatureBus = {
  emit: (event: FeatureEvent) => void;
  subscribe: (feature: string, handler: (event: FeatureEvent) => void) => () => void;
};

export function createFeatureBus(): FeatureBus {
  const handlers = new Map<string, Set<(event: FeatureEvent) => void>>();
  return {
    emit: (event) => handlers.get(event.feature)?.forEach((h) => h(event)),
    subscribe: (feature, handler) => {
      const set = handlers.get(feature) ?? new Set();
      set.add(handler);
      handlers.set(feature, set);
      return () => void set.delete(handler);
    },
  };
}
