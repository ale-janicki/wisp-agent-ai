import { TabCard, TabMessage } from "../shell/TabCard";
import type { Feature } from "./types";

export const COMING_SOON = "Em breve no Windows";

export function comingSoon(feature: Pick<Feature, "label" | "icon">) {
  return function ComingSoon() {
    return (
      <TabCard title={feature.label} icon={feature.icon}>
        <TabMessage text={COMING_SOON} />
      </TabCard>
    );
  };
}
