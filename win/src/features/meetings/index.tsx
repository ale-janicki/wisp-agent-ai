import { WaveformIcon } from "../../shell/icons";
import { comingSoon } from "../ComingSoon";
import type { Feature } from "../types";

const base = { id: "meetings", label: "Reuniões", icon: WaveformIcon };

export const meetings: Feature = {
  ...base,
  Component: comingSoon(base),
  hasListColumn: true,
};
